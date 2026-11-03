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
  [string]$Out        = (Join-Path $PSScriptRoot '..\library.json')
)

$video = '.mkv', '.mp4', '.m4v', '.avi', '.mov', '.wmv', '.ts', '.m2ts', '.iso'

function Split-Name([string]$name) {
  # "Title (2015)" -> Title, 2015 ; strips trailing tags like [tmdbid-123]
  $name = [IO.Path]::GetFileNameWithoutExtension($name) -replace '\[[^\]]*\]', ''
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

@{ movies = $movies; tv = $tv } | ConvertTo-Json -Depth 5 | Set-Content -Path $Out -Encoding UTF8
Write-Host "Wrote $($movies.Count) movies and $($tv.Count) shows to $((Resolve-Path $Out).Path)"
