<#
.SYNOPSIS
  Moves the newest media-tracker-shared*.json from your Downloads folder to shared\library.json in the repo.
  Then commit and push it with GitHub Desktop to update what family and friends see.
#>
param([string]$Downloads = (Join-Path $env:USERPROFILE 'Downloads'))

$src = Get-ChildItem -Path $Downloads -Filter 'media-tracker-shared*.json' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $src) { Write-Error "No media-tracker-shared*.json in $Downloads. In the app: Settings -> Export shared snapshot."; exit 1 }

$destDir = Join-Path $PSScriptRoot '..\shared'
New-Item -ItemType Directory -Force $destDir | Out-Null
Move-Item -Force $src.FullName (Join-Path $destDir 'library.json')
Write-Host "Updated $((Resolve-Path (Join-Path $destDir 'library.json')).Path)"
Write-Host 'Now open GitHub Desktop, commit, and push.'
