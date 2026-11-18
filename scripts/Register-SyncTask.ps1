<#
.SYNOPSIS
  Creates (or replaces) a Windows scheduled task that runs Sync-Site.ps1 every day.
  Remove it later with:  Unregister-ScheduledTask -TaskName MediaTrackerSync -Confirm:$false

.EXAMPLE
  .\Register-SyncTask.ps1 -Time 03:00
#>
param([string]$Time = '03:00')

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot 'Sync-Site.ps1'

$action   = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Unattended"
$trigger  = New-ScheduledTaskTrigger -Daily -At $Time
# StartWhenAvailable: if the PC was off at $Time, run as soon as it's back on.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName 'MediaTrackerSync' -Action $action -Trigger $trigger -Settings $settings -Force `
  -Description 'Updates the Media Tracker shared library from the Jellyfin folders and pushes it to GitHub.' | Out-Null
Write-Host "Scheduled 'MediaTrackerSync' daily at $Time (runs while you are signed in). Logs: $PSScriptRoot\sync.log"
