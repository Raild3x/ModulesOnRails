param([string]$OutPath, [int]$WaitForWindowSec = 90, [int]$SettleSec = 7)
# Waits for the run-in-roblox Studio window, lets it settle, then captures that window's own
# content with PrintWindow (PW_RENDERFULLCONTENT). Unlike a screen copy, nothing on top of Studio
# (another app) can end up in the image, and Studio does not need to be focused.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public static class Win32Capture {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
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
$h = $proc.MainWindowHandle
Start-Sleep -Seconds $SettleSec
$r = New-Object RECT
[Win32Capture]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Win32Capture]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
if (-not $ok) { Write-Output "PRINTWINDOW_FAILED"; exit 3 }
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("SAVED " + $OutPath + " " + $w + "x" + $hgt)
