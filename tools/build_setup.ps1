# Builds setup/KR1ModLoaderSetup.cs into dist/KR1ModLoader-Setup-<version>.exe -- a GUI
# installer with no dependencies. The loader's Lua files are embedded as plain
# resources "bootstrap/<path>", one per file (not as an archive: the exe then
# reads as what it is -- a program with text files inside).
#
#   powershell -File tools/build_setup.ps1 [-Output path] [-CertThumbprint ... | -CertFile ... [-CertPassword ...]]
#
# Signing is optional, but an unknown unsigned exe that rewrites another exe
# will collect antivirus false positives. The script installer (install.bat)
# does not have that problem.
param(
    [string]$Output = "",
    [string]$CertThumbprint = $env:KR1ML_CERT_THUMBPRINT,
    [string]$CertFile = $env:KR1ML_CERT_FILE,
    [string]$CertPassword = $env:KR1ML_CERT_PASSWORD,
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root "VERSION.txt") -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION.txt: expected MAJOR.MINOR.PATCH, got '$version'" }
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$out = if ($Output) { [IO.Path]::GetFullPath($Output) } else { Join-Path $dist "KR1ModLoader-Setup-$version.exe" }

$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v4*\csc.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $csc) {
    $csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework\v4*\csc.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $csc) { throw "csc.exe not found: .NET Framework 4.x is required" }

$bootstrap = Join-Path $root "bootstrap"
$prefix = ([IO.Path]::GetFullPath($bootstrap)).TrimEnd('\') + '\'
$resources = @()
foreach ($f in (Get-ChildItem -LiteralPath $bootstrap -Recurse -File -Filter *.lua | Sort-Object FullName)) {
    if ($f.FullName.Contains(",")) { throw "comma in a resource path: $($f.FullName)" }
    $rel = $f.FullName.Substring($prefix.Length).Replace('\', '/')
    $resources += "/resource:$($f.FullName),bootstrap/$rel"
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("kr1modloader_setup_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $info = Join-Path $stage "AssemblyInfo.cs"
    [IO.File]::WriteAllText($info, @"
using System.Reflection;
[assembly: AssemblyTitle("KR1ModLoader Setup")]
[assembly: AssemblyProduct("KR1ModLoader")]
[assembly: AssemblyDescription("Installs the KR1ModLoader mod loader into an existing Kingdom Rush installation.")]
[assembly: AssemblyFileVersion("$version.0")]
[assembly: AssemblyInformationalVersion("$version")]
"@, [Text.UTF8Encoding]::new($false))

    $args = @("/nologo", "/target:winexe", "/platform:anycpu", "/optimize+", "/codepage:65001", "/out:$out",
        "/reference:System.IO.Compression.dll", "/reference:System.Windows.Forms.dll", "/reference:System.Drawing.dll")
    $args += $resources
    $args += (Join-Path $root "setup\KR1ModLoaderSetup.cs")
    $args += $info
    & $csc $args
    if ($LASTEXITCODE -ne 0) { throw "compilation failed" }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ("built: {0} ({1:N0} bytes)" -f $out, (Get-Item $out).Length)

if ($CertThumbprint -or $CertFile) {
    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $signtool) {
        $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match '\\x64$' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $signtool) { throw "signtool.exe not found" }
    $sign = @("sign", "/fd", "sha256", "/td", "sha256", "/tr", $TimestampUrl, "/d", "KR1ModLoader Setup")
    if ($CertThumbprint) { $sign += @("/sha1", $CertThumbprint) } else { $sign += @("/f", $CertFile); if ($CertPassword) { $sign += @("/p", $CertPassword) } }
    & $signtool ($sign + $out)
    if ($LASTEXITCODE -ne 0) { throw "signing failed" }
    Write-Output "signed"
} else {
    Write-Warning "unsigned exe: expect antivirus false positives. The script installer (install.bat) is free of this."
}
