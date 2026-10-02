param([string]$OutPath, [int]$WaitForWindowSec = 90, [int]$SettleSec = 7)
# Waits for a Roblox Studio window to appear, lets it settle, maximizes it, then captures the
# window's own content with PrintWindow (PW_RENDERFULLCONTENT). A screen copy would grab any
# other app on top of Studio; this never can.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public static class Win32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
$deadline = (Get-Date).AddSeconds($WaitForWindowSec)
$proc = $null
while ((Get-Date) -lt $deadline) {
  $proc = Get-Process RobloxStudioBeta -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*run-in-roblox*" } | Select-Object -First 1
  if ($proc) { break }
  Start-Sleep -Milliseconds 500
}
if (-not $proc) { Write-Output "NO_WINDOW"; exit 2 }
Write-Output ("WINDOW " + $proc.MainWindowTitle)
Start-Sleep -Seconds $SettleSec
$h = $proc.MainWindowHandle
# Onto the primary monitor first: Studio reopens where it last was (a portrait side monitor
# gives a tall window whose layout hides the 3D view). Once there, later captures leave it be.
$r = New-Object RECT
[Win32]::GetWindowRect($h, [ref]$r) | Out-Null
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($r.Left -lt $primary.Left - 16 -or $r.Top -lt $primary.Top - 16 -or ($r.Right - $r.Left) -lt $primary.Width) {
  [Win32]::ShowWindow($h, 9) | Out-Null   # restore
  [Win32]::SetWindowPos($h, [IntPtr]::Zero, 40, 40, 1600, 1000, 0x0004) | Out-Null   # SWP_NOZORDER
  Start-Sleep -Milliseconds 300
  [Win32]::ShowWindow($h, 3) | Out-Null   # maximize
  Start-Sleep -Seconds 3   # the panels lay themselves out again
}
# To the front: Studio stops drawing its 3D view while in the background, and PrintWindow would
# capture stale panels. (A tap of Alt lets a background process take the foreground.)
[Win32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[Win32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[Win32]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 1500
$r = New-Object RECT
[Win32]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Win32]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
if (-not $ok) { Write-Output "PRINTWINDOW_FAILED"; exit 3 }
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("SAVED " + $OutPath + " " + $w + "x" + $hgt)
