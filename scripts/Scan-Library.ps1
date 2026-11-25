<#
.SYNOPSIS
  Scans Jellyfin-style Movies/TV folders and writes library.json for import into Media Tracker.

.EXAMPLE
  .\Scan-Library.ps1 -MoviesPath E:\Jellyfin_Movies -TvPath E:\Jellyfin_TVshows -Out library.json

  Expected layout:
    Movies:  <Movies>\Title (2015)\file.mkv   (or files directly in <Movies>)
    TV:      <TV>\Show (2015)\Season 1\episode.mkv
#>
param(
  [string]$MoviesPath = 'E:\Jellyfin_Movies',
  [string]$TvPath     = 'E:\Jellyfin_TVshows',
  [string]$MusicPath  = 'E:\Jellyfin_Music\LoadedtoServer',
  [string]$Out        = ''
)

# Default output: ..\library.json next to this script. If the code was pasted into a console
# (no script location), fall back to the project folder so it never writes to the wrong place.
if (-not $Out) {
  $base = if ($PSScriptRoot) { Join-Path $PSScriptRoot '..' } else { 'E:\media-tracker' }
  $Out = Join-Path $base 'library.json'
}

$video = '.mkv', '.mp4', '.m4v', '.avi', '.mov', '.wmv', '.ts', '.m2ts', '.iso'
$audio = '.m4a', '.mp3', '.flac', '.aac', '.ogg', '.opus', '.wav', '.wma', '.alac', '.aiff'

function Split-Name([string]$name) {
  # "Title (2015)" -> Title, 2015 ; strips a video extension and trailing tags like [tmdbid-123]
  # (only known extensions: names like "Mr. & Mrs. Smith (2005)" contain dots that aren't extensions)
  $name = $name -replace '\.(mkv|mp4|m4v|avi|mov|wmv|ts|m2ts|iso)$', '' -replace '\[[^\]]*\]', ''
  if ($name -match '^(.*?)\s*\((\d{4})\)') { return @{ title = $Matches[1].Trim(); year = [int]$Matches[2] } }
  return @{ title = $name.Trim(); year = $null }
}

function Has-Video($dir) {
  [bool](Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $video -contains $_.Extension.ToLower() } | Select-Object -First 1)
}

$movies = @()
if (Test-Path $MoviesPath) {
  Get-ChildItem -LiteralPath $MoviesPath | ForEach-Object {
    if ($_.PSIsContainer) { if (-not (Has-Video $_.FullName)) { return } }
    elseif ($video -notcontains $_.Extension.ToLower()) { return }
    $movies += (Split-Name $_.Name)
  }
} else { Write-Warning "Movies path not found: $MoviesPath" }

$tv = @()
if (Test-Path $TvPath) {
  Get-ChildItem -LiteralPath $TvPath -Directory | ForEach-Object {
    $show = Split-Name $_.Name
    $seasons = @(Get-ChildItem -LiteralPath $_.FullName -Directory |
      Where-Object { $_.Name -match '^(Season|Series|S)\s*0*(\d+)$' -and [int]$Matches[2] -gt 0 -and (Has-Video $_.FullName) } |
      ForEach-Object { $null = $_.Name -match '(\d+)'; [int]$Matches[1] } | Sort-Object -Unique)
    # No season folders, just loose episode files: treat as season 1 (adjust in the app if wrong)
    if (-not $seasons) {
      $loose = Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $video -contains $_.Extension.ToLower() }
      if ($loose) { $seasons = @(1) }
    }
    $tv += @{ title = $show.title; year = $show.year; seasons = $seasons }
  }
} else { Write-Warning "TV path not found: $TvPath" }

# Music: <Artist>\<Album (Year)>\tracks. Audio files directly inside an artist folder count as one "Singles" album.
function Count-Audio($dir, [switch]$Recurse) {
  @(Get-ChildItem -LiteralPath $dir -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
    Where-Object { $audio -contains $_.Extension.ToLower() }).Count
}
$music = @()
if (Test-Path $MusicPath) {
  Get-ChildItem -LiteralPath $MusicPath -Directory | ForEach-Object {
    $artist = $_.Name.Trim()
    Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
      $tracks = Count-Audio $_.FullName -Recurse
      if ($tracks -eq 0) { return }
      if ($_.Name -eq 'Unknown Album') {
        # Report each track by name, so Sync-Site can match it to a real album via scripts\music-albums.json.
        Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $audio -contains $_.Extension.ToLower() } | ForEach-Object {
          $music += @{ artist = $artist; album = 'Unknown Album'; year = $null; tracks = 1; track = ($_.BaseName -replace '^\d+[\s.\-]+', '') }
        }
        return
      }
      $alb = Split-Name $_.Name
      $music += @{ artist = $artist; album = $alb.title; year = $alb.year; tracks = $tracks }
    }
    $loose = Count-Audio $_.FullName
    if ($loose -gt 0) { $music += @{ artist = $artist; album = 'Singles & loose tracks'; year = $null; tracks = $loose } }
  }
} else { Write-Warning "Music path not found: $MusicPath" }

@{ movies = $movies; tv = $tv; music = $music } | ConvertTo-Json -Depth 5 | Set-Content -Path $Out -Encoding UTF8
Write-Host "Wrote $($movies.Count) movies, $($tv.Count) shows and $($music.Count) albums to $((Resolve-Path $Out).Path)"
