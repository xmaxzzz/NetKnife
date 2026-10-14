' Hidden launcher for NetKnife. Runs pwsh with stdout/stderr redirected to nul so the app
' process has no console of its own — this is what lets the embedded-terminal child conhost
' create a classic ConsoleWindowClass window (otherwise Win11 hands it to Windows Terminal).
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File ""D:\SCRIPTS\NetKnife\NetKnife.ps1"" > nul 2>&1", 0, False
