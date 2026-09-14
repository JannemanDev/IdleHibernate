Set objShell = CreateObject("Wscript.Shell")
If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "delay" Then
    WScript.Sleep 1200
  End If
End If
objShell.Run "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\Users\Jan\Scripts\IdleHibernate\IdleHibernateTray.ps1""", 0, False
