#Requires -RunAsAdministrator
param(
  [ValidateSet('Status', 'Build', 'Live', 'Install', 'Uninstall', 'IdleOn', 'IdleOff')]
  [string]$Action = 'Status'
)
$ErrorActionPreference = 'Stop'

$InputHash = '8C62AFDE3009041BF05BCC5213582F3914C4A0AA3FAB6EC242CCE61665470B45'
$Patches = @(
  @{ Offset = 0x1297F0; Old = 'D503201F'; New = 'B906192B' },
  @{ Offset = 0x12A0B0; Old = 'D503201F'; New = 'F947DAE8' },
  @{ Offset = 0x12A0B4; Old = 'D503201F'; New = '8B140108' },
  @{ Offset = 0x12A0B8; Old = 'D503201F'; New = '91425109' },
  @{ Offset = 0x12A0BC; Old = 'D503201F'; New = '528000C8' },
  @{ Offset = 0x12A0C0; Old = 'D503201F'; New = 'B9079928' }
)
$Firmware = 'qcdxkmsuc8150.mbn', 'qcvss8150.mbn'
$Service = 'HKLM:\SYSTEM\CurrentControlSet\Services\QCDX'
$State = 'HKLM:\SOFTWARE\NabuDisplayFix'
$FixDir = Join-Path $env:SystemRoot 'System32\drivers\NabuDisplayFix'
$FixImagePath = '\SystemRoot\System32\drivers\NabuDisplayFix\qcdxkm8150.sys'
$StageDir = Join-Path $env:ProgramData 'NabuDisplayFix'
$CertSubject = 'CN=NabuDisplayFix Local Test Signing'
$DxKmd = 'HKLM:\SOFTWARE\QCOM\Drivers\DxKMD'
$IdleSections = 'GRAPHICS', 'ROTATOR', 'VIDEO', 'DISPLAY\INTERNAL1', 'DISPLAY\EXTERNAL3', 'DISPLAY\EXTERNAL4'

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class NabuDisplayFixNative {
  public static uint PeChecksum(byte[] b, int checksumOffset) {
    ulong sum = 0;
    for (int i = 0; i + 1 < b.Length; i += 2) {
      if (i == checksumOffset || i == checksumOffset + 2) continue;
      sum += (ulong)(b[i] | (b[i + 1] << 8));
      sum = (sum & 0xFFFF) + (sum >> 16);
    }
    if ((b.Length & 1) != 0) { sum += b[b.Length - 1]; sum = (sum & 0xFFFF) + (sum >> 16); }
    sum = (sum & 0xFFFF) + (sum >> 16);
    return (uint)sum + (uint)b.Length;
  }
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int c, IntPtr b, int l, out int r);
  public static List<string> KernelModules() {
    int len = 1 << 20; IntPtr buf = Marshal.AllocHGlobal(len); int ret; var list = new List<string>();
    try {
      if (NtQuerySystemInformation(11, buf, len, out ret) != 0) return list;
      int n = Marshal.ReadInt32(buf);
      for (int i = 0; i < n; i++) {
        IntPtr e = new IntPtr(buf.ToInt64() + 8 + (long)i * 296);
        byte[] name = new byte[256]; Marshal.Copy(new IntPtr(e.ToInt64() + 40), name, 0, 256);
        int z = Array.IndexOf(name, (byte)0); list.Add(Encoding.ASCII.GetString(name, 0, z < 0 ? 256 : z));
      }
    } finally { Marshal.FreeHGlobal(buf); }
    return list;
  }
}
'@

function Word($Hex) { [Convert]::ToUInt32($Hex, 16) }

function Ensure-Key($Path) { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null } }

function Get-Hash($Path) { if (Test-Path $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash } else { $null } }

function Get-LoadedDisplayDriver {
  ([NabuDisplayFixNative]::KernelModules() | Where-Object { $_ -match 'qcdxkm8150' }) -join ', '
}

function Find-StockDriver {
  $saved = (Get-ItemProperty $State -ErrorAction SilentlyContinue).StockImagePath
  $candidates = @()
  if ($saved) { $candidates += $saved }
  $candidates += (Get-ItemProperty $Service).ImagePath
  foreach ($c in $candidates) {
    $p = $c -replace '^\\SystemRoot', $env:SystemRoot
    if ((Get-Hash $p) -eq $InputHash) { return @{ ImagePath = $c; File = $p } }
  }
  $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
  foreach ($f in Get-ChildItem $repo -Filter qcdxkm8150.sys -Recurse -ErrorAction SilentlyContinue) {
    if ((Get-Hash $f.FullName) -eq $InputHash) {
      return @{ ImagePath = '\SystemRoot' + $f.FullName.Substring($env:SystemRoot.Length); File = $f.FullName }
    }
  }
  return $null
}

function Assert-TestSigning {
  $bcd = (bcdedit /enum '{current}') -join "`n"
  if ($bcd -notmatch 'testsigning\s+Yes') { throw 'Test signing is off. Run "bcdedit /set testsigning on" and restart first.' }
}

function Get-SigningCert {
  $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $CertSubject -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
  if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject -KeyAlgorithm RSA -KeyLength 2048 `
      -HashAlgorithm SHA256 -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(20)
  }
  $cer = Join-Path $StageDir 'NabuDisplayFix.cer'
  Export-Certificate -Cert $cert -FilePath $cer | Out-Null
  foreach ($store in 'Root', 'TrustedPublisher') {
    if (-not (Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object Thumbprint -eq $cert.Thumbprint)) {
      Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    }
  }
  return $cert
}

function Test-Patched($Path) {
  if (-not (Test-Path $Path)) { return $false }
  $b = [IO.File]::ReadAllBytes($Path)
  foreach ($p in $Patches) { if ([BitConverter]::ToUInt32($b, $p.Offset) -ne (Word $p.New)) { return $false } }
  return (Get-AuthenticodeSignature $Path).Status -eq 'Valid'
}

function Build-Patched($Stock) {
  New-Item -ItemType Directory -Force $StageDir | Out-Null
  $out = Join-Path $StageDir 'qcdxkm8150.sys'
  $deployed = Join-Path $FixDir 'qcdxkm8150.sys'
  if ((Test-Patched $deployed) -and ((Get-Hash $out) -ne (Get-Hash $deployed))) { Copy-Item $deployed $out -Force }
  if (Test-Patched $out) { return $out }
  $b = [IO.File]::ReadAllBytes($Stock.File)
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  $opt = $pe + 24
  if ([BitConverter]::ToUInt16($b, $opt) -ne 0x20B) { throw 'Not a PE32+ image.' }
  $secDir = $opt + 112 + 4 * 8
  $certOff = [BitConverter]::ToInt32($b, $secDir)
  if ($certOff -gt 0) {
    $t = New-Object byte[] $certOff
    [Array]::Copy($b, $t, $certOff)
    $b = $t
    for ($i = 0; $i -lt 8; $i++) { $b[$secDir + $i] = 0 }
  }
  foreach ($p in $Patches) {
    $cur = [BitConverter]::ToUInt32($b, $p.Offset)
    if ($cur -ne (Word $p.Old)) { throw ('Unexpected instruction at file offset 0x{0:X}: {1:X8}' -f $p.Offset, $cur) }
    [BitConverter]::GetBytes((Word $p.New)).CopyTo($b, $p.Offset)
  }
  [BitConverter]::GetBytes([NabuDisplayFixNative]::PeChecksum($b, $opt + 64)).CopyTo($b, $opt + 64)
  [IO.File]::WriteAllBytes($out, $b)
  $cert = Get-SigningCert
  $sig = Set-AuthenticodeSignature -FilePath $out -Certificate $cert -HashAlgorithm SHA256
  if ($sig.Status -ne 'Valid') { throw "Signing failed: $($sig.Status) $($sig.StatusMessage)" }
  if (-not (Test-Patched $out)) { throw 'Patched word check failed after signing.' }
  return $out
}

function Deploy($Stock, $Built) {
  New-Item -ItemType Directory -Force $FixDir | Out-Null
  $target = Join-Path $FixDir 'qcdxkm8150.sys'
  if ((Get-Hash $target) -ne (Get-Hash $Built)) { Copy-Item $Built $target -Force }
  $stockDir = Split-Path $Stock.File
  foreach ($f in $Firmware) {
    $src = Join-Path $stockDir $f
    if (-not (Test-Path $src)) { throw "Firmware $f is missing next to the stock driver." }
    if ((Get-Hash (Join-Path $FixDir $f)) -ne (Get-Hash $src)) { Copy-Item $src $FixDir -Force }
  }
  Ensure-Key $State
  Set-ItemProperty $State -Name StockImagePath -Value $Stock.ImagePath
}

function Set-ImagePath($Value) { Set-ItemProperty -Path $Service -Name ImagePath -Value $Value -Type ExpandString }

function Show-Status {
  $ip = (Get-ItemProperty $Service).ImagePath
  $stock = Find-StockDriver
  "Display service ImagePath : $ip"
  "Stock driver (8c62afde)   : " + $(if ($stock) { $stock.File } else { 'not found' })
  "Loaded display driver     : " + (Get-LoadedDisplayDriver)
  "Fix persistent            : " + $(if ($ip -eq $FixImagePath) { 'yes' } else { 'no' })
  foreach ($s in $IdleSections) {
    $v = (Get-ItemProperty "$DxKmd\$s" -Name ForceActive -ErrorAction SilentlyContinue).ForceActive
    '  ForceActive {0,-18} {1}' -f $s, $(if ($null -eq $v) { 'unset (1 from ACPI)' } else { $v })
  }
}

switch ($Action) {
  'Status' { Show-Status }
  'Build' {
    $stock = Find-StockDriver
    if (-not $stock) { throw 'The nabu C-PHY display driver 27.20.2140.0 (8c62afde) was not found.' }
    $out = Build-Patched $stock
    "Built and signed: $out"
    "SHA-256: " + (Get-Hash $out)
  }
  { $_ -in 'Live', 'Install' } {
    Assert-TestSigning
    $stock = Find-StockDriver
    if (-not $stock) { throw 'The nabu C-PHY display driver 27.20.2140.0 (8c62afde) was not found.' }
    $built = Build-Patched $stock
    Deploy $stock $built
    if ($Action -eq 'Install') {
      Set-ImagePath $FixImagePath
      Show-Status
      'Installed. Restart the tablet to load the fixed display driver.'
      break
    }
    $gpu = Get-PnpDevice -PresentOnly | Where-Object { $_.Service -eq 'QCDX' } | Select-Object -First 1
    if (-not $gpu) { throw 'Display adapter not found.' }
    Set-ImagePath $FixImagePath
    try {
      'Restarting the display adapter; the screen blanks for a few seconds.'
      pnputil /restart-device "$($gpu.InstanceId)" | Out-Null
    } finally {
      Set-ImagePath $stock.ImagePath
    }
    Show-Status
    'Loaded for this session only; a restart returns to the stock driver. Touch may need a quick screen off/on.'
  }
  'Uninstall' {
    $stock = Find-StockDriver
    if (-not $stock) { throw 'The stock display driver was not found; ImagePath left unchanged.' }
    Set-ImagePath $stock.ImagePath
    Show-Status
    'Restart the tablet to load the stock display driver.'
  }
  'IdleOn' {
    foreach ($s in $IdleSections) {
      Ensure-Key "$DxKmd\$s"
      New-ItemProperty -Path "$DxKmd\$s" -Name ForceActive -PropertyType DWord -Value 0 -Force | Out-Null
    }
    Show-Status
    'Display power-down enabled. Restart the tablet. Use it only with the fix installed.'
  }
  'IdleOff' {
    foreach ($s in $IdleSections) { Remove-ItemProperty -Path "$DxKmd\$s" -Name ForceActive -ErrorAction SilentlyContinue }
    Show-Status
    'Display power-down disabled (ACPI default). Restart the tablet.'
  }
}
