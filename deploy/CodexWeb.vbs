' Double-click entry point for the codex-web stack.
'
' Runs windowless: starts codex-web (:8214), then nginx (:8443), waits for the
' stack to answer, and finally opens the UI in the default browser. Kept in VBS
' so no console window is created at all (a .cmd would flash one).
Option Explicit

Dim fso, sh, here, pwsh
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
pwsh = "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "

' Waiting (True) means the browser only opens once the stack is actually up.
sh.Run pwsh & Chr(34) & here & "\CodexWeb.ps1" & Chr(34) & " start", 0, True
sh.Run pwsh & Chr(34) & here & "\CodexWeb.ps1" & Chr(34) & " open", 0, False
