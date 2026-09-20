Set objShell = CreateObject("Wscript.Shell")
Set objFso = CreateObject("Scripting.FileSystemObject")

scriptDir = objFso.GetParentFolderName(WScript.ScriptFullName)
trayPs1 = objFso.BuildPath(scriptDir, "IdleHibernateTray.ps1")
powershellExe = objShell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

If Not objFso.FileExists(trayPs1) Then
  MsgBox "IdleHibernateTray.ps1 not found:" & vbCrLf & trayPs1, vbCritical, "IdleHibernate"
  WScript.Quit 1
End If

If Not objFso.FileExists(powershellExe) Then
  MsgBox "powershell.exe not found:" & vbCrLf & powershellExe, vbCritical, "IdleHibernate"
  WScript.Quit 1
End If

If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "delay" Then
    WScript.Sleep 1200
  End If
End If

objShell.Run """" & powershellExe & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & trayPs1 & """", 0, False
