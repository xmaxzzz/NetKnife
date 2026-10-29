' Hidden launcher for NetKnife. Runs pwsh with stdout/stderr redirected to nul so the app
' process has no console of its own - this is what lets the embedded-terminal child conhost
' create a classic ConsoleWindowClass window (otherwise Win11 hands it to Windows Terminal).
' NetKnife.ps1 is taken from the folder of this file, so the app works from any folder.
' Keep this file ASCII: WSH reads .vbs in the ANSI code page, Cyrillic is built with ChrW.
Option Explicit
Dim sh, fso, appDir, app, pwsh
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

appDir = fso.GetParentFolderName(WScript.ScriptFullName)
app = fso.BuildPath(appDir, "NetKnife.ps1")

pwsh = FindPwsh()
If pwsh = "" Then
    ' "Nuzhen PowerShell 7: ..." - the first word is Cyrillic
    MsgBox ChrW(1053) & ChrW(1091) & ChrW(1078) & ChrW(1077) & ChrW(1085) & " PowerShell 7: winget install --id Microsoft.PowerShell -e", vbExclamation, "NetKnife"
    WScript.Quit 1
End If

' cmd /c "<line>": with more than two quotes cmd strips only the outer pair, the quoted paths inside survive
sh.Run "cmd /c """ & Q(pwsh) & " -NoProfile -STA -ExecutionPolicy Bypass -File " & Q(app) & " > nul 2>&1""", 0, False

Function Q(s)
    Q = """" & s & """"
End Function

' Standard install folder first (64- and 32-bit WSH), then PATH (winget/MSI/Store alias in WindowsApps).
Function FindPwsh()
    Dim c, p
    For Each c In Array("%ProgramW6432%\PowerShell\7\pwsh.exe", "%ProgramFiles%\PowerShell\7\pwsh.exe")
        p = sh.ExpandEnvironmentStrings(c)
        If fso.FileExists(p) Then
            FindPwsh = p
            Exit Function
        End If
    Next
    If sh.Run("cmd /c where /q pwsh.exe", 0, True) = 0 Then
        FindPwsh = "pwsh.exe"
    Else
        FindPwsh = ""
    End If
End Function
