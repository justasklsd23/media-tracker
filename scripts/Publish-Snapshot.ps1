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
$dest = Join-Path $destDir 'library.json'

# The app's export doesn't contain the music list (the sync script manages it), so carry it over.
$music = $null
if (Test-Path $dest) { try { $music = (Get-Content $dest -Raw | ConvertFrom-Json -AsHashtable).music } catch {} }

Move-Item -Force $src.FullName $dest
if ($music) {
  $new = Get-Content $dest -Raw | ConvertFrom-Json -AsHashtable
  $new.music = $music
  [IO.File]::WriteAllText((Resolve-Path $dest).Path, (ConvertTo-Json $new -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
}
Write-Host "Updated $((Resolve-Path $dest).Path)"
Write-Host 'Now open GitHub Desktop, commit, and push.'
