# 监听 Spotify：程序打开时自动启动歌词，关闭时自动收掉
param([int]$IntervalSeconds = 4)

$srcRoot = $PSScriptRoot
$appRoot = Split-Path -Parent $srcRoot
$app     = Join-Path $srcRoot 'SpotifyLyrics.ps1'
$logDir  = Join-Path $appRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir 'watch.log'

function Write-WatchLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $log -Value ('[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch {}
}

Write-WatchLog 'watcher start'
$wasRunning = $false
$child = $null

while ($true) {
    $spotify = @(Get-Process -Name Spotify -ErrorAction SilentlyContinue)
    $nowRunning = ($spotify.Count -gt 0)
    if ($nowRunning -and -not $wasRunning) {
        try {
            $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $app + '"')) -PassThru
            Write-WatchLog ('spotify up -> lyrics pid ' + $child.Id)
        } catch {
            Write-WatchLog ('start failed: ' + $_.Exception.Message)
        }
    } elseif (-not $nowRunning -and $wasRunning) {
        if ($child -and -not $child.HasExited) { try { Stop-Process -Id $child.Id -Force } catch {} }
        Write-WatchLog 'spotify down -> lyrics stopped'
    }
    $wasRunning = $nowRunning
    Start-Sleep -Seconds $IntervalSeconds
}
