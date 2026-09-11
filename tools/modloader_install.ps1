# KR1ModLoader -- installs the mod loader into Kingdom Rush without any compiled program.
#
# Same as tools/modloader.py install, in plain PowerShell 5.1 (ships with Windows
# 10/11): finds Kingdom Rush.exe, rewrites the zip part of the exe -- main.lua
# becomes modloader/game_main.lua and the files from bootstrap/ are added -- and
# creates the Mods folder. -Uninstall reverses that inside the exe. The PE part
# (executable code) is not changed by a single byte; compressed archive data is
# copied as is, without recompression. No backup copy of the exe is made.
#
#   install.bat / uninstall.bat in the release zip call this script; from source:
#   powershell -ExecutionPolicy Bypass -File tools/modloader_install.ps1 [-GameExe "...\Kingdom Rush.exe"] [-Uninstall]
param(
    [string]$GameExe = "",
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$bootstrap = Join-Path $root "bootstrap"
if (-not (Test-Path -LiteralPath $bootstrap)) { $bootstrap = Join-Path $here "bootstrap" }
$ExeName = "Kingdom Rush.exe"
$LoaderMark = "modloader/loader.lua"
$GameMain = "modloader/game_main.lua"

# ------------------------------------------------------------------ locate the game
function Find-GameExe {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\Kingdom Rush",
        "$env:ProgramFiles\Steam\steamapps\common\Kingdom Rush"
    )
    $steamPath = $null
    try { $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath } catch {}
    if ($steamPath) {
        $candidates += (Join-Path $steamPath "steamapps\common\Kingdom Rush")
        $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $candidates += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps\common\Kingdom Rush")
            }
        }
    }
    foreach ($dir in $candidates) {
        $exe = Join-Path $dir $ExeName
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

# ------------------------------------------------------------------ zip inside the exe
$LocalSig = 0x04034B50
$CentralSig = 0x02014B50
$EocdSig = 0x06054B50

function Read-FusedExe([string]$path) {
    $data = [IO.File]::ReadAllBytes($path)
    $tail = [Math]::Max(0, $data.Length - 22 - 65535)
    $eocd = -1
    for ($i = $data.Length - 22; $i -ge $tail; $i--) {
        if ($data[$i] -eq 0x50 -and $data[$i+1] -eq 0x4B -and $data[$i+2] -eq 0x05 -and $data[$i+3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw "$path : not a fused LOVE executable (no zip archive)" }
    $total = [BitConverter]::ToUInt16($data, $eocd + 10)
    $cdSize = [BitConverter]::ToUInt32($data, $eocd + 12)
    $cdOffset = [BitConverter]::ToUInt32($data, $eocd + 16)
    $start = $eocd - $cdSize - $cdOffset
    if ($start -lt 0 -or [BitConverter]::ToUInt32($data, $start) -ne $LocalSig) { throw "could not locate the archive start" }

    $entries = New-Object System.Collections.Generic.List[object]
    $p = $start + $cdOffset
    for ($n = 0; $n -lt $total; $n++) {
        if ([BitConverter]::ToUInt32($data, $p) -ne $CentralSig) { throw "corrupt central directory" }
        $nlen = [BitConverter]::ToUInt16($data, $p + 28)
        $elen = [BitConverter]::ToUInt16($data, $p + 30)
        $clen = [BitConverter]::ToUInt16($data, $p + 32)
        $lho = [BitConverter]::ToUInt32($data, $p + 42)
        $name = [Text.Encoding]::UTF8.GetString($data, $p + 46, $nlen)
        $lh = $start + $lho
        $lnlen = [BitConverter]::ToUInt16($data, $lh + 26)
        $lelen = [BitConverter]::ToUInt16($data, $lh + 28)
        $entries.Add([pscustomobject]@{
            Name    = $name
            Method  = [BitConverter]::ToUInt16($data, $p + 10)
            Time    = [BitConverter]::ToUInt16($data, $p + 12)
            Date    = [BitConverter]::ToUInt16($data, $p + 14)
            Crc     = [BitConverter]::ToUInt32($data, $p + 16)
            CSize   = [BitConverter]::ToUInt32($data, $p + 20)
            USize   = [BitConverter]::ToUInt32($data, $p + 24)
            ExtAttr = [BitConverter]::ToUInt32($data, $p + 38)
            DataOff = $lh + 30 + $lnlen + $lelen
            Raw     = $null   # $null = the data lives in $data at DataOff
        })
        $p += 46 + $nlen + $elen + $clen
    }
    return [pscustomobject]@{ Data = $data; Start = $start; Entries = $entries }
}

# CRC32 on int64: in PowerShell 5.1 hex literals above int32 wrap to negative
# numbers, so [uint32]0xFFFFFFFF does not parse.
$crcTable = New-Object long[] 256
for ($i = 0; $i -lt 256; $i++) {
    [long]$c = $i
    for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = 0xEDB88320L -bxor ($c -shr 1) } else { $c = $c -shr 1 } }
    $crcTable[$i] = $c
}
function Get-Crc32([byte[]]$bytes) {
    [long]$c = 0xFFFFFFFFL
    foreach ($b in $bytes) { $c = $crcTable[($c -bxor $b) -band 0xFF] -bxor ($c -shr 8) }
    return [uint32]($c -bxor 0xFFFFFFFFL)
}

function New-DeflatedEntry([string]$name, [byte[]]$content) {
    $ms = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Compress, $true)
    $ds.Write($content, 0, $content.Length); $ds.Close()
    $raw = $ms.ToArray()
    return [pscustomobject]@{
        Name = $name; Method = 8; Time = 0; Date = 0x21; Crc = (Get-Crc32 $content)
        CSize = [uint32]$raw.Length; USize = [uint32]$content.Length; ExtAttr = 0; DataOff = 0; Raw = $raw
    }
}

function Write-FusedExe($exe, [string]$outPath) {
    $fs = [IO.File]::Open($outPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    $bw = New-Object IO.BinaryWriter($fs)
    $bw.Write($exe.Data, 0, $exe.Start)
    $central = New-Object IO.MemoryStream
    $cw = New-Object IO.BinaryWriter($central)
    [uint16]$flags = 0x800
    foreach ($e in $exe.Entries) {
        $nameBytes = [Text.Encoding]::UTF8.GetBytes($e.Name)
        [uint32]$offset = $fs.Position - $exe.Start
        $bw.Write([uint32]$LocalSig); $bw.Write([uint16]20); $bw.Write($flags); $bw.Write([uint16]$e.Method)
        $bw.Write([uint16]$e.Time); $bw.Write([uint16]$e.Date); $bw.Write([uint32]$e.Crc)
        $bw.Write([uint32]$e.CSize); $bw.Write([uint32]$e.USize); $bw.Write([uint16]$nameBytes.Length); $bw.Write([uint16]0)
        $bw.Write($nameBytes)
        if ($null -ne $e.Raw) { $bw.Write($e.Raw) } else { $bw.Write($exe.Data, $e.DataOff, [int]$e.CSize) }
        $cw.Write([uint32]$CentralSig); $cw.Write([uint16]20); $cw.Write([uint16]20); $cw.Write($flags); $cw.Write([uint16]$e.Method)
        $cw.Write([uint16]$e.Time); $cw.Write([uint16]$e.Date); $cw.Write([uint32]$e.Crc)
        $cw.Write([uint32]$e.CSize); $cw.Write([uint32]$e.USize); $cw.Write([uint16]$nameBytes.Length)
        $cw.Write([uint16]0); $cw.Write([uint16]0); $cw.Write([uint16]0); $cw.Write([uint16]0); $cw.Write([uint32]$e.ExtAttr); $cw.Write($offset)
        $cw.Write($nameBytes)
    }
    [uint32]$cdOffset = $fs.Position - $exe.Start
    $cdBytes = $central.ToArray()
    $bw.Write($cdBytes)
    [uint16]$count = $exe.Entries.Count
    $bw.Write([uint32]$EocdSig); $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write($count); $bw.Write($count)
    $bw.Write([uint32]$cdBytes.Length); $bw.Write($cdOffset); $bw.Write([uint16]0)
    $bw.Flush(); $fs.Close()
}

function Test-Entry($exe, [string]$name) {
    foreach ($e in $exe.Entries) { if ($e.Name -eq $name) { return $true } }
    return $false
}

function Remove-Loader($exe) {
    $kept = New-Object System.Collections.Generic.List[object]
    $origMain = $null
    foreach ($e in $exe.Entries) {
        if ($e.Name -eq $GameMain) { $origMain = $e }
        elseif ($e.Name -eq "main.lua" -or $e.Name.StartsWith("modloader/")) { }
        else { $kept.Add($e) }
    }
    if (-not $origMain) { throw "the loader is not installed in this exe" }
    $origMain.Name = "main.lua"
    $kept.Add($origMain)
    $exe.Entries = $kept
}

function Add-Loader($exe) {
    $names = @{}
    foreach ($e in $exe.Entries) { $names[$e.Name] = $e }
    if (-not $names.ContainsKey($LoaderMark)) {
        if (-not $names.ContainsKey("main.lua")) { throw "no main.lua in the archive" }
        $names["main.lua"].Name = $GameMain
    }
    $files = Get-ChildItem -LiteralPath $bootstrap -Recurse -File -Filter *.lua | Sort-Object FullName
    if ($files.Count -eq 0) { throw "bootstrap folder is empty: $bootstrap" }
    $prefix = ([IO.Path]::GetFullPath($bootstrap)).TrimEnd('\') + '\'
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($prefix.Length).Replace('\', '/')
        $new = New-DeflatedEntry $rel ([IO.File]::ReadAllBytes($f.FullName))
        $idx = -1
        for ($i = 0; $i -lt $exe.Entries.Count; $i++) { if ($exe.Entries[$i].Name -eq $rel) { $idx = $i; break } }
        if ($idx -ge 0) { $exe.Entries[$idx] = $new } else { $exe.Entries.Add($new) }
    }
}

# ------------------------------------------------------------------ run
if (-not $GameExe) { $GameExe = Find-GameExe }
if (-not $GameExe -or -not (Test-Path -LiteralPath $GameExe)) {
    throw "Kingdom Rush.exe not found. Drag it onto install.bat or pass the path as an argument."
}
$GameExe = [IO.Path]::GetFullPath($GameExe)
$gameDir = Split-Path -Parent $GameExe
Write-Host "Game folder: $gameDir"
Write-Host "Reading $ExeName ..."
$exe = Read-FusedExe $GameExe
$forked = Test-Entry $exe $LoaderMark
$tmp = "$GameExe.tmp"

if ($Uninstall) {
    Remove-Loader $exe
    Write-FusedExe $exe $tmp
    Move-Item -LiteralPath $tmp -Destination $GameExe -Force
    Write-Host "Loader removed. The Mods folder is left in place."
    exit 0
}

Write-Host ("  loader: {0}" -f $(if ($forked) { "already installed, updating it" } else { "not installed" }))
Add-Loader $exe
Write-FusedExe $exe $tmp
Move-Item -LiteralPath $tmp -Destination $GameExe -Force
$mods = Join-Path $gameDir "Mods"
if (-not (Test-Path -LiteralPath $mods)) { New-Item -ItemType Directory -Path $mods | Out-Null }
Write-Host "Done: $GameExe"
Write-Host "Put mods into: $mods"
Write-Host "Loader log after launch: $(Join-Path $gameDir 'modloader.log')"
