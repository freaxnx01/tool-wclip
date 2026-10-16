' Starts a command with no visible window (pwsh -WindowStyle Hidden still flashes a console),
' waits for it and returns its exit code, so a scheduled task sees the real process lifetime
' and its restart-on-failure settings apply.
' Usage: wscript.exe //B //NoLogo run-hidden.vbs "<exe>" <args...>
Dim args, i, cmd
Set args = WScript.Arguments
For i = 0 To args.Count - 1
    If InStr(args(i), " ") > 0 Then
        cmd = cmd & """" & args(i) & """ "
    Else
        cmd = cmd & args(i) & " "
    End If
Next
WScript.Quit CreateObject("WScript.Shell").Run(Trim(cmd), 0, True)
