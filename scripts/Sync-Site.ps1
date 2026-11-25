<#
.SYNOPSIS
  One-step update of the public site: scans your Jellyfin folders, matches new titles on TMDB,
  refreshes TV season data, rewrites shared\library.json, then commits and pushes it.

.DESCRIPTION
  Titles found on disk are kept as "owned". Everything else already in shared\library.json
  (wishlist, vinyl, manual edits) is preserved. Nothing is removed. If nothing changed, nothing is committed.

  TMDB key: set the user environment variable TMDB_API_KEY, or put the key alone in scripts\.tmdb-key
  (git-ignored). The key is never written to the repo.

.EXAMPLE
  .\Sync-Site.ps1 -DryRun     # show what would change, write nothing
  .\Sync-Site.ps1 -NoPush     # update and commit locally, don't push
  .\Sync-Site.ps1             # the full run (this is what the scheduled task runs, with -Unattended)
#>
param(
  [string]$MoviesPath = 'E:\Jellyfin_Movies',
  [string]$TvPath     = 'E:\Jellyfin_TVshows',
  [string]$MusicPath  = 'E:\Jellyfin_Music\LoadedtoServer',
  [string]$RepoPath   = (Join-Path $PSScriptRoot '..'),
  [int]$RefreshDays   = 7,
  [int]$MaxMusicLookups = 200,   # MusicBrainz is ~1 request/second; the rest is picked up on the next run
  [switch]$DryRun,
  [switch]$NoPush,
  [switch]$Unattended
)

$ErrorActionPreference = 'Stop'
$RepoPath = (Resolve-Path $RepoPath).Path
$snapPath = Join-Path $RepoPath 'shared\library.json'
$logPath  = Join-Path $PSScriptRoot 'sync.log'

function Log([string]$m) {
  $line = '{0}  {1}' -f (Get-Date -Format 's'), $m
  Write-Host $line
  Add-Content -Path $logPath -Value $line
}
function Norm([string]$s) { ([regex]::Replace($s.ToLower(), '[^a-z0-9]+', ' ')).Trim() }
function Src($e, [string]$type) { "$type|$(Norm $e.title)|$($e.year)" }
function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# ---- TMDB ----
# Prefer the saved (user-level) value: a PowerShell window opened before `setx` still holds the old one.
$script:TmdbKey = [Environment]::GetEnvironmentVariable('TMDB_API_KEY', 'User')
if (-not $script:TmdbKey) { $script:TmdbKey = $env:TMDB_API_KEY }
if (-not $script:TmdbKey) {
  $kf = Join-Path $PSScriptRoot '.tmdb-key'
  if (Test-Path $kf) { $script:TmdbKey = (Get-Content $kf -Raw).Trim() }
}

function Invoke-Tmdb([string]$Path, [hashtable]$Query = @{}) {
  $uri = "https://api.themoviedb.org/3$Path"
  $headers = @{}
  $q = $Query.Clone()
  if ($script:TmdbKey.Length -gt 40) { $headers.Authorization = "Bearer $($script:TmdbKey)" } else { $q.api_key = $script:TmdbKey }
  $qs = ($q.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }) -join '&'
  if ($qs) { $uri += "?$qs" }
  for ($try = 1; $try -le 3; $try++) {
    try { return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30 }
    catch {
      $code = $_.Exception.Response.StatusCode.value__
      if ($code -eq 401) { throw "TMDB returned 401 for $Path ($($_.ErrorDetails.Message))" }
      if ($try -eq 3) { throw }
      Start-Sleep -Seconds (2 * $try)
    }
  }
}

function Update-Details($item) {
  if ($item.type -eq 'tv') {
    $d = Invoke-Tmdb "/tv/$($item.tmdbId)"
    $item.seasons = @($d.seasons | Where-Object { $_.season_number -gt 0 } | ForEach-Object {
      @{ n = [int]$_.season_number; eps = [int]$_.episode_count; air = [string]$_.air_date } })
    $item.tmdbStatus = [string]$d.status
  } else {
    $d = Invoke-Tmdb "/movie/$($item.tmdbId)"
    $item.collection = if ($d.belongs_to_collection) { @{ id = [int]$d.belongs_to_collection.id; name = [string]$d.belongs_to_collection.name } } else { $null }
  }
  $item.refreshed = NowMs
}

function Merge-Seasons($item, $seasons) {
  $item.ownedSeasons = @(@($item.ownedSeasons) + @($seasons) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
}

# ---- MusicBrainz (no key; asks for ~1 request/second and a descriptive User-Agent) ----
$script:MbAgent = 'MediaTracker/1.0 (https://github.com/justasklsd23/media-tracker)'
function Esc-Lucene([string]$s) { ([regex]::Replace($s, '[+\-&|!(){}\[\]^"~*?:\\/_]', ' ')).Trim() }

function Find-MusicBrainz([string]$artist, [string]$album) {
  # First an exact-phrase query; if that finds nothing (apostrophes, "?" lost in folder names), the same words in any order.
  $words = (@((Norm $album) -split ' ') | Where-Object { $_.Length -gt 3 }) -join ' AND '
  $queries = @('releasegroup:"{0}" AND artist:"{1}"' -f (Esc-Lucene $album), (Esc-Lucene $artist))
  if ($words) { $queries += 'releasegroup:({0}) AND artist:"{1}"' -f $words, (Esc-Lucene $artist) }
  $res = $null
  foreach ($query in $queries) {
    $uri = 'https://musicbrainz.org/ws/2/release-group?fmt=json&limit=8&query=' + [uri]::EscapeDataString($query)
    $res = $null
    for ($try = 1; $try -le 3 -and -not $res; $try++) {
      try { $res = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = $script:MbAgent } -TimeoutSec 30 }
      catch { if ($try -eq 3) { throw }; Start-Sleep -Seconds (3 * $try) }
    }
    Start-Sleep -Milliseconds 1200
    if (@($res.'release-groups').Count -gt 0) { break }
  }
  $na = Norm $album; $nart = Norm $artist
  $cands = @($res.'release-groups' | Where-Object {
    $credit = Norm (($_.'artist-credit' | ForEach-Object { $_.name }) -join ' ')
    $credit -and ($credit -like "*$nart*" -or $nart -like "*$credit*")
  })
  $hit = $cands | Where-Object { (Norm $_.title) -eq $na } | Sort-Object { $_.'primary-type' -ne 'Album' } | Select-Object -First 1
  if (-not $hit) { $hit = $cands | Where-Object { $t = Norm $_.title; $t.StartsWith($na) -or $na.StartsWith($t) } | Select-Object -First 1 }
  return $hit
}

# Fixed key order, so old and new entries serialize identically and "did anything change?" is reliable.
function ConvertTo-MusicEntry($m) {
  [ordered]@{ key = [string]$m.key; src = [string]$m.src; mbid = [string]$m.mbid; artist = [string]$m.artist
              title = [string]$m.title; year = [string]$m.year; tracks = [int]$m.tracks; status = 'owned'
              addedAt = [long]$m.addedAt; mbTried = [long]$m.mbTried }
}
function Sort-Music($list) { @($list | Sort-Object { $_.artist }, { $_.year }, { $_.title }) }

# ---- Git ----
function Get-GitPath {
  $c = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return [string]$c.Source }
  $d = Get-ChildItem "$env:LOCALAPPDATA\GitHubDesktop\app-*\resources\app\git\cmd\git.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if ($d) { return [string]$d.FullName }
  throw 'Git not found. Install Git or GitHub Desktop.'
}
function Git { & $script:GitExe -C $RepoPath @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" } }

try {
  if ($Unattended) { $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never' }
  Log "Sync started$(if ($DryRun) { ' (dry run)' })"
  $script:GitExe = Get-GitPath

  if (-not $DryRun -and -not $NoPush) { Git pull --rebase --autostash --quiet }

  # ---- Load current snapshot ----
  $snap = @{ items = @(); vinyl = @() }
  if (Test-Path $snapPath) { $snap = Get-Content $snapPath -Raw | ConvertFrom-Json -AsHashtable }
  $items = [System.Collections.ArrayList]@($snap.items)
  $vinyl = @($snap.vinyl)
  $oldMusic = @(Sort-Music (@($snap.music) | Where-Object { $_ } | ForEach-Object { ConvertTo-MusicEntry $_ }))
  $before = (ConvertTo-Json @($items) -Depth 20 -Compress) + (ConvertTo-Json @($oldMusic) -Depth 5 -Compress)

  $byKey = @{}
  foreach ($i in $items) { $byKey[$i.key] = $i }

  # ---- Write album tags into tracks that sit in "Unknown Album" folders (matched by artist + song title) ----
  if (-not $DryRun) {
    try { & (Join-Path $PSScriptRoot 'Tag-Music.ps1') -MusicPath $MusicPath | Out-Null }
    catch { Log "Tag-Music failed: $($_.Exception.Message)" }
  }

  # ---- Scan disk ----
  $scanFile = Join-Path ([IO.Path]::GetTempPath()) 'media-tracker-scan.json'
  & (Join-Path $PSScriptRoot 'Scan-Library.ps1') -MoviesPath $MoviesPath -TvPath $TvPath -MusicPath $MusicPath -Out $scanFile | Out-Null
  $scan = Get-Content $scanFile -Raw | ConvertFrom-Json -AsHashtable
  Remove-Item $scanFile -ErrorAction SilentlyContinue
  $entries = @($scan.movies | ForEach-Object { $_.type = 'movie'; $_ }) + @($scan.tv | ForEach-Object { $_.type = 'tv'; $_ })

  $added = 0; $unmatched = 0; $skipped = 0
  foreach ($e in $entries) {
    $type = $e.type
    $src = Src $e $type
    $have = $null
    foreach ($i in $items) {
      if ($i.type -ne $type) { continue }
      if ($i.src -eq $src -or ((Norm $i.title) -eq (Norm $e.title) -and (-not $e.year -or [string]$i.year -eq [string]$e.year))) { $have = $i; break }
    }

    if (-not $have) {
      if (-not $script:TmdbKey) { $skipped++; continue }
      $q = @{ query = $e.title }
      if ($e.year) { $q[$(if ($type -eq 'tv') { 'first_air_date_year' } else { 'year' })] = $e.year }
      $res = @((Invoke-Tmdb "/search/$type" $q).results)
      if (-not $res -and $e.year) { $res = @((Invoke-Tmdb "/search/$type" @{ query = $e.title }).results) }
      $r = $res | Select-Object -First 1

      if ($r) {
        $key = "${type}:$($r.id)"
        $have = $byKey[$key]
        if (-not $have) {
          $date = if ($type -eq 'tv') { $r.first_air_date } else { $r.release_date }
          $have = @{
            key = $key; type = $type; tmdbId = [int]$r.id
            title = [string]$(if ($type -eq 'tv') { $r.name } else { $r.title })
            year = $(if ($date) { ([string]$date).Substring(0, 4) } else { '' })
            poster = [string]$r.poster_path; overview = [string]$r.overview; vote = [double]$r.vote_average
            status = 'owned'; ownedSeasons = @(); watched = $false; addedAt = NowMs
          }
          Update-Details $have
          [void]$items.Add($have); $byKey[$key] = $have
          $added++
          Log "Added: $($have.title) ($($have.year))"
        }
      } else {
        $key = "local:${type}:$(Norm $e.title):$($e.year)"
        $have = $byKey[$key]
        if (-not $have) {
          $have = @{ key = $key; type = $type; tmdbId = $null; title = [string]$e.title; year = [string]$e.year; poster = ''
                     status = 'owned'; ownedSeasons = @(); watched = $false; addedAt = NowMs }
          [void]$items.Add($have); $byKey[$key] = $have
          $unmatched++
          Log "No TMDB match: $($e.title) ($($e.year))"
        }
      }
    }

    $have.src = $src
    $have.status = 'owned'
    if ($type -eq 'tv') { Merge-Seasons $have $e.seasons }
  }

  # ---- Refresh season data for shows (so newly aired seasons show up as missing) ----
  $refreshed = 0
  if ($script:TmdbKey) {
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-$RefreshDays).ToUnixTimeMilliseconds()
    foreach ($i in $items) {
      if ($i.type -ne 'tv' -or -not $i.tmdbId) { continue }
      if ($i.seasons -and $i.refreshed -and $i.refreshed -gt $cutoff) { continue }
      try { Update-Details $i; $refreshed++ } catch { Log "Refresh failed for $($i.title): $($_.Exception.Message)" }
    }
  }
  if ($skipped) { Log "No TMDB key found: skipped $skipped new titles. Set TMDB_API_KEY (see README)." }

  # ---- Music: mirrors the disk. MusicBrainz matches are remembered per album, so each is looked up once. ----
  $music = $oldMusic
  $mbLookups = 0
  if (Test-Path $MusicPath) {
    $oldBySrc = @{}
    foreach ($m in $oldMusic) { $oldBySrc[$m.src] = $m }
    $retryBefore = [DateTimeOffset]::UtcNow.AddDays(-30).ToUnixTimeMilliseconds()   # re-try unmatched albums monthly
    $list = [System.Collections.ArrayList]::new()
    # Tracks in "Unknown Album" folders: use scripts\music-albums.json (artist + song -> album) to file them under their real album.
    $map = @{}
    $mapFile = Join-Path $PSScriptRoot 'music-albums.json'
    if (Test-Path $mapFile) { foreach ($e in (Get-Content $mapFile -Raw | ConvertFrom-Json)) { $map["$(Norm $e.artist)|$(Norm $e.track)"] = $e } }
    $grouped = [ordered]@{}
    foreach ($a in @($scan.music)) {
      if (-not $a) { continue }
      $alb = $a.album; $yr = $a.year; $art = $a.artist
      if ($a.track) {
        $e = $map["$(Norm $a.artist)|$(Norm $a.track)"]
        if ($e) { $alb = $e.album; $yr = $e.year; if ($e.displayArtist) { $art = $e.displayArtist } }
      }
      $k = "$(Norm $art)|$(Norm $alb)"
      if ($grouped.Contains($k)) { $grouped[$k].tracks += [int]$a.tracks }
      else { $grouped[$k] = @{ artist = $art; album = $alb; year = $yr; tracks = [int]$a.tracks } }
    }
    foreach ($a in @($grouped.Values)) {
      if (-not $a) { continue }
      $src = 'music|{0}|{1}' -f (Norm $a.artist), (Norm $a.album)
      $m = @{ key = ''; src = $src; mbid = ''; artist = $a.artist; title = $a.album; year = $a.year; tracks = $a.tracks; addedAt = NowMs; mbTried = 0 }
      $old = $oldBySrc[$src]
      if ($old) { $m.mbid = $old.mbid; $m.addedAt = $old.addedAt; $m.mbTried = $old.mbTried; if (-not $m.year) { $m.year = $old.year } }
      if (-not $m.mbid -and $a.album -notin @('Singles & loose tracks', 'Unknown Album') -and $a.artist -ne 'Unknown Artist' -and $m.mbTried -lt $retryBefore -and $mbLookups -lt $MaxMusicLookups) {
        $mbLookups++
        try {
          $hit = Find-MusicBrainz $a.artist $a.album
          if ($hit) {
            $m.mbid = [string]$hit.id
            $d = [string]$hit.'first-release-date'
            if (-not $m.year -and $d.Length -ge 4) { $m.year = $d.Substring(0, 4) }
          }
          $m.mbTried = NowMs
        } catch { Log "MusicBrainz lookup failed for $($a.artist) - $($a.album): $($_.Exception.Message)" }
      }
      $m.key = if ($m.mbid) { "music:$($m.mbid)" } else { "music:local:$src" }
      [void]$list.Add((ConvertTo-MusicEntry $m))
    }
    if ($list.Count -eq 0 -and $oldMusic.Count -gt 0) { Log 'Music folder has no albums right now: keeping the existing music list.' }
    else { $music = @(Sort-Music $list) }
    Log "Music: $($music.Count) albums ($mbLookups MusicBrainz lookups)"
  } else { Log "Music folder not found ($MusicPath): keeping the existing music list." }

  # ---- Write snapshot if anything changed ----
  $after = (ConvertTo-Json @($items) -Depth 20 -Compress) + (ConvertTo-Json @($music) -Depth 5 -Compress)
  if ($before -eq $after) {
    Log "No changes. ($($items.Count) titles)"
    if (-not $DryRun -and -not $NoPush) {   # push any earlier commit that never made it to GitHub
      $ahead = [int](& $script:GitExe -C $RepoPath rev-list --count '@{u}..HEAD')
      if ($ahead -gt 0) { Git push --quiet; Log "Pushed $ahead earlier commit(s)." }
    }
    return
  }
  Log "Changes: $added added, $unmatched unmatched, $refreshed shows refreshed. ($($items.Count) titles)"
  if ($DryRun) { Log 'Dry run: nothing written.'; return }

  $out = [ordered]@{
    version = 1
    updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    items   = @($items)
    vinyl   = @($vinyl)
    music   = @($music)
  }
  New-Item -ItemType Directory -Force (Split-Path $snapPath) | Out-Null
  [IO.File]::WriteAllText($snapPath, (ConvertTo-Json $out -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))

  Git add shared/library.json
  Git commit --quiet -m 'Update shared library (automatic sync)'
  if (-not $NoPush) { Git push --quiet; Log 'Pushed to GitHub.' } else { Log 'Committed locally (not pushed).' }
}
catch {
  Log "ERROR: $($_.Exception.Message)"
  exit 1
}
