$srcRoot = Split-Path -Parent $PSScriptRoot
$watch = Join-Path $srcRoot 'src\Watch-Spotify.ps1'
if (-not (Test-Path -LiteralPath $watch)) { Write-Host ("找不到 " + $watch); exit 1 }
$startup = [Environment]::GetFolderPath('Startup')
$vbs = Join-Path $startup 'SpotifyLyricsWatcher.vbs'
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $watch + '""'
$content = 'CreateObject("WScript.Shell").Run "' + $cmd + '", 0, False'
Set-Content -LiteralPath $vbs -Value $content -Encoding ASCII
Write-Host ("已安装开机自启：" + $vbs)
Write-Host "下次登录 Windows 后生效；Spotify 一打开就会自动出现歌词条。"
