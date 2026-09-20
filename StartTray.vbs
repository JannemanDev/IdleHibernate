' Starts IdleHibernateTray.ps1 from this folder. Always writes a log and reports the log path.

Option Explicit

Dim objShell, objFso, scriptDir, trayPs1, powershellExe, logDir, logFile, statusFile
Dim showUi, arg, i, missing, line, result, waited, status, procCount

Set objShell = CreateObject("Wscript.Shell")
Set objFso = CreateObject("Scripting.FileSystemObject")

scriptDir = objFso.GetParentFolderName(WScript.ScriptFullName)
trayPs1 = objFso.BuildPath(scriptDir, "IdleHibernateTray.ps1")
powershellExe = objShell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
logDir = objShell.ExpandEnvironmentStrings("%LOCALAPPDATA%\IdleHibernate")
logFile = objFso.BuildPath(logDir, "start-tray.log")
statusFile = objFso.BuildPath(logDir, "start-status.txt")

showUi = True
For i = 0 To WScript.Arguments.Count - 1
  arg = LCase(WScript.Arguments(i))
  If arg = "delay" Or arg = "silent" Then showUi = False
Next

EnsureLogDir
If objFso.FileExists(statusFile) Then objFso.DeleteFile statusFile, True

WriteLog "----"
WriteLog "StartTray.vbs"
WriteLog "Script: " & WScript.ScriptFullName
WriteLog "Folder: " & scriptDir
WriteLog "Log file: " & logFile

If Not objFso.FileExists(powershellExe) Then
  Fail "powershell.exe not found:" & vbCrLf & powershellExe
End If
WriteLog "OK powershell: " & powershellExe

If Not objFso.FileExists(trayPs1) Then
  Fail "IdleHibernateTray.ps1 not found:" & vbCrLf & trayPs1
End If
WriteLog "OK tray script: " & trayPs1

missing = ""
CheckRequired "Common.ps1", missing
CheckRequired "DebugStore.ps1", missing
CheckRequired "DashboardServer.ps1", missing
CheckRequired "lib\Newtonsoft.Json.dll", missing
CheckRequired "lib\sqlite3.dll", missing
If Len(missing) > 0 Then
  Fail "Required files missing:" & vbCrLf & missing
End If

procCount = CountTrayProcesses()
If procCount > 0 Then
  WriteLog "Already running (" & procCount & " process(es))."
  Done "IdleHibernate is already running.", 0
End If

For i = 0 To WScript.Arguments.Count - 1
  If LCase(WScript.Arguments(i)) = "delay" Then
    WriteLog "Delay 1200 ms"
    WScript.Sleep 1200
  End If
Next

WriteLog "Launching tray..."
On Error Resume Next
objShell.Run """" & powershellExe & """ -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & trayPs1 & """", 0, False
If Err.Number <> 0 Then
  line = "Failed to start powershell: " & Err.Description & " (" & Err.Number & ")"
  Err.Clear
  On Error GoTo 0
  Fail line
End If
On Error GoTo 0

waited = 0
status = ""
Do While waited < 15000
  WScript.Sleep 250
  waited = waited + 250
  status = ReadStatus()
  If status = "started" Or status = "already" Or Left(status, 6) = "error:" Then Exit Do
  If waited >= 3000 And CountTrayProcesses() = 0 And status = "" Then Exit Do
Loop

If status = "started" Then
  WriteLog "Started successfully."
  Done "IdleHibernate started successfully.", 0
ElseIf status = "already" Then
  WriteLog "Already running (mutex)."
  Done "IdleHibernate is already running.", 0
ElseIf Left(status, 6) = "error:" Then
  Fail Mid(status, 7)
ElseIf CountTrayProcesses() > 0 Then
  WriteLog "Process is running (no status file yet)."
  Done "IdleHibernate started successfully.", 0
Else
  Fail "Tray process exited immediately. Check the log and crash.txt under %LOCALAPPDATA%\IdleHibernate."
End If

WScript.Quit 0

Sub EnsureLogDir()
  If Not objFso.FolderExists(logDir) Then objFso.CreateFolder logDir
End Sub

Sub WriteLog(msg)
  Dim ts
  EnsureLogDir
  Set ts = objFso.OpenTextFile(logFile, 8, True)
  ts.WriteLine Now & "  " & msg
  ts.Close
End Sub

Sub CheckRequired(relPath, ByRef missingList)
  Dim full
  full = objFso.BuildPath(scriptDir, relPath)
  If objFso.FileExists(full) Then
    WriteLog "OK " & relPath
  Else
    WriteLog "MISSING " & relPath & " -> " & full
    If Len(missingList) > 0 Then missingList = missingList & vbCrLf
    missingList = missingList & full
  End If
End Sub

Function ReadStatus()
  Dim ts, txt
  ReadStatus = ""
  If Not objFso.FileExists(statusFile) Then Exit Function
  On Error Resume Next
  Set ts = objFso.OpenTextFile(statusFile, 1)
  If Err.Number = 0 Then
    txt = Trim(ts.ReadLine)
    ts.Close
    ReadStatus = LCase(txt)
  End If
  On Error GoTo 0
End Function

Function CountTrayProcesses()
  Dim wmi, procs, p, n, cmd
  n = 0
  On Error Resume Next
  Set wmi = GetObject("winmgmts:\\.\root\cimv2")
  Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'")
  For Each p In procs
    cmd = LCase("" & p.CommandLine)
    If InStr(cmd, "idlehibernatetray.ps1") > 0 Then n = n + 1
  Next
  On Error GoTo 0
  CountTrayProcesses = n
End Function

Sub Notify(msg)
  Dim text
  text = msg & vbCrLf & vbCrLf & "Log file:" & vbCrLf & logFile
  WriteLog "UI: " & msg
  If showUi Then
    If InStr(LCase(WScript.FullName), "cscript") > 0 Then
      WScript.Echo text
    Else
      MsgBox text, vbInformation, "IdleHibernate"
    End If
  End If
End Sub

Sub Done(msg, code)
  Notify msg
  WScript.Quit code
End Sub

Sub Fail(msg)
  WriteLog "ERROR: " & msg
  Notify "IdleHibernate failed to start." & vbCrLf & vbCrLf & msg
  WScript.Quit 1
End Sub
