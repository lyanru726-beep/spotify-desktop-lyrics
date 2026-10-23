' Spotify desktop lyrics - silent launcher
Option Explicit
Dim fso, sh, base, script, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
base   = fso.GetParentFolderName(WScript.ScriptFullName)
script = base & "\src\SpotifyLyrics.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
sh.Run cmd, 0, False
