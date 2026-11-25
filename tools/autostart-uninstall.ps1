$startup = [Environment]::GetFolderPath('Startup')
$vbs = Join-Path $startup 'SpotifyLyricsWatcher.vbs'
if (Test-Path -LiteralPath $vbs) { Remove-Item -LiteralPath $vbs -Force; Write-Host ("已取消自启：" + $vbs) }
else { Write-Host "没有找到自启项，可能已经取消过了。" }
