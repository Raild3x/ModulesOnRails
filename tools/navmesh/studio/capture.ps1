param([string]$OutPath, [int]$WaitForWindowSec = 90, [int]$SettleSec = 7)
# Waits for a Roblox Studio window to appear, lets it settle, then captures its rectangle.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public static class Win32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
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
Start-Sleep -Seconds $SettleSec
$h = $proc.MainWindowHandle
[Win32]::ShowWindow($h, 3) | Out-Null   # maximize
[Win32]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800
$r = New-Object RECT
[Win32]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("SAVED " + $OutPath + " " + $w + "x" + $hgt)
