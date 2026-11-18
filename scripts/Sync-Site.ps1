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
  [string]$RepoPath   = (Join-Path $PSScriptRoot '..'),
  [int]$RefreshDays   = 7,
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
  $before = ConvertTo-Json @($items) -Depth 20 -Compress

  $byKey = @{}
  foreach ($i in $items) { $byKey[$i.key] = $i }

  # ---- Scan disk ----
  $scanFile = Join-Path ([IO.Path]::GetTempPath()) 'media-tracker-scan.json'
  & (Join-Path $PSScriptRoot 'Scan-Library.ps1') -MoviesPath $MoviesPath -TvPath $TvPath -Out $scanFile | Out-Null
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

  # ---- Write snapshot if anything changed ----
  $after = ConvertTo-Json @($items) -Depth 20 -Compress
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
