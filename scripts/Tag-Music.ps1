<#
.SYNOPSIS
  Finds tracks in "<Artist>\Unknown Album" folders, works out their real album (scripts\music-albums.json first,
  then a MusicBrainz lookup by artist + song title) and writes the album / year into the file's tags.
  Files are never renamed or moved. Each original is copied to -BackupPath before it is rewritten.
.PARAMETER DryRun
  Only report what would be done.
#>
param(
  [string]$MusicPath  = 'E:\Jellyfin_Music\LoadedtoServer',
  [string]$BackupPath = 'E:\Music-tag-backups',     # keep this OUTSIDE the Jellyfin music library
  [int]$MaxLookups    = 40,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'E:\media-tracker\scripts' }
$logFile = Join-Path $root 'sync.log'
function Log([string]$m) { $l = '{0}  Tag-Music: {1}' -f (Get-Date -Format 's'), $m; Write-Host $l; try { Add-Content -Path $logFile -Value $l } catch {} }
function Norm([string]$s) { ([regex]::Replace($s.ToLower(), '[^a-z0-9]+', ' ')).Trim() }

$ffmpeg = [string](Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $ffmpeg) { $ffmpeg = 'C:\Program Files\Jellyfin\Server\ffmpeg.exe' }
if (-not (Test-Path $ffmpeg)) { Log 'ffmpeg not found; skipping.'; return }
$ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'
if (-not (Test-Path $ffprobe)) { Log 'ffprobe not found; skipping.'; return }
if (-not (Test-Path $MusicPath)) { Log "Music folder not found: $MusicPath"; return }

$mapFile = Join-Path $root 'music-albums.json'
$map = [System.Collections.ArrayList]::new()
if (Test-Path $mapFile) { foreach ($e in (Get-Content $mapFile -Raw | ConvertFrom-Json)) { [void]$map.Add($e) } }
function Find-Entry($artist, $track) { $map | Where-Object { (Norm $_.artist) -eq (Norm $artist) -and (Norm $_.track) -eq (Norm $track) } | Select-Object -First 1 }

$ua = @{ 'User-Agent' = 'MediaTracker/1.0 (https://github.com/justasklsd23/media-tracker)' }
function Lookup-Album([string]$artist, [string]$title) {
  $q = 'recording:"{0}" AND artist:"{1}"' -f ($title -replace '["\\]', ''), ($artist -replace '["\\/]', ' ')
  $r = $null
  for ($i = 1; $i -le 3 -and -not $r; $i++) {
    try { $r = Invoke-RestMethod ('https://musicbrainz.org/ws/2/recording?fmt=json&limit=15&query=' + [uri]::EscapeDataString($q)) -Headers $ua -TimeoutSec 30 }
    catch { if ($i -eq 3) { throw }; Start-Sleep (4 * $i) }
  }
  Start-Sleep -Milliseconds 1300
  $na = Norm $artist
  $c = foreach ($rec in $r.recordings) {
    $credit = Norm (($rec.'artist-credit' | ForEach-Object { $_.name }) -join ' ')
    if (-not ($credit -like "*$na*" -or $na -like "*$credit*")) { continue }
    foreach ($rel in $rec.releases) {
      $rg = $rel.'release-group'
      if ($rel.status -eq 'Official' -and $rg.'primary-type' -eq 'Album' -and -not $rg.'secondary-types') {
        [pscustomobject]@{ album = [string]$rel.title; year = ([string]$rel.date -replace '-.*'); sort = $(if ($rel.date) { [string]$rel.date } else { '9999' }) }
      }
    }
  }
  $c | Sort-Object sort | Select-Object -First 1
}

function Get-Tags([string]$file) {
  $j = & $ffprobe -v error -show_entries format_tags -of json $file | ConvertFrom-Json
  $h = @{}; if ($j.format.tags) { foreach ($p in $j.format.tags.PSObject.Properties) { $h[$p.Name.ToLower()] = [string]$p.Value } }
  $h
}

$lookups = 0; $tagged = 0; $mapChanged = $false
$files = Get-ChildItem -LiteralPath $MusicPath -Recurse -File -Include *.m4a |
  Where-Object { $_.Directory.Name -eq 'Unknown Album' -and $_.Directory.Parent.Name -ne 'Unknown Artist' }
foreach ($f in $files) {
  $folderArtist = $f.Directory.Parent.Name
  $track = $f.BaseName -replace '^\d+[\s.\-]+', ''
  $tags = Get-Tags $f.FullName
  if ($tags['album']) { continue }   # already has an album tag

  $e = Find-Entry $folderArtist $track
  if (-not $e) {
    if ($lookups -ge $MaxLookups) { continue }
    $lookups++
    try { $hit = Lookup-Album $folderArtist $track } catch { Log "Lookup failed for $folderArtist - ${track}: $($_.Exception.Message)"; continue }
    if (-not $hit) { Log "No album found for $folderArtist - $track"; continue }
    $e = [pscustomobject]@{ artist = $folderArtist; track = $track; album = $hit.album; year = $hit.year }
    [void]$map.Add($e); $mapChanged = $true
    Log "Matched $folderArtist - $track -> $($hit.album) ($($hit.year))"
  }
  $artistName = if ($e.displayArtist) { $e.displayArtist } else { $folderArtist }
  if ($DryRun) { Log "Would tag: $($f.Name) -> $($e.album) ($($e.year))"; continue }

  # Rewrite via a temp file (stream copy, no re-encode), check it, keep a backup of the original, then swap it in.
  $tmp = Join-Path $env:TEMP ('tag-' + [guid]::NewGuid().ToString('N') + '.m4a')
  try {
    $meta = @('-metadata', "album=$($e.album)", '-metadata', "album_artist=$artistName")
    if (-not $tags['artist']) { $meta += @('-metadata', "artist=$artistName") }
    if ($e.year) { $meta += @('-metadata', "date=$($e.year)") }
    & $ffmpeg -v error -y -i $f.FullName -map 0 -c copy @meta $tmp
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { throw 'ffmpeg failed' }
    $new = Get-Tags $tmp
    if ($new['album'] -ne $e.album) { throw 'album tag missing after rewrite' }
    $d1 = [double](& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName)
    $d2 = [double](& $ffprobe -v error -show_entries format=duration -of csv=p=0 $tmp)
    if ([math]::Abs($d1 - $d2) -gt 1) { throw "duration changed ($d1 -> $d2)" }
    $bk = Join-Path $BackupPath ($f.FullName.Substring($MusicPath.TrimEnd('\').Length).TrimStart('\'))
    New-Item -ItemType Directory -Force (Split-Path $bk) | Out-Null
    if (-not (Test-Path $bk)) { Copy-Item -LiteralPath $f.FullName -Destination $bk }
    Copy-Item -LiteralPath $tmp -Destination $f.FullName -Force
    $tagged++
    Log "Tagged $($f.Name): album '$($e.album)'"
  } catch { Log "Could not tag $($f.FullName): $($_.Exception.Message)" }
  finally { if (Test-Path $tmp) { [IO.File]::Delete($tmp) } }
}
if ($mapChanged -and -not $DryRun) {
  [IO.File]::WriteAllText($mapFile, (ConvertTo-Json @($map) -Depth 4), [Text.UTF8Encoding]::new($false))
}
Log "Done: $tagged file(s) tagged, $lookups lookup(s)."
