<#
Packages the plugin into dist\ as a zip that can be unpacked straight into
KOReader's "plugins" folder.

    dist\focusline.koplugin.v<version>.zip   the release, named after its version
    dist\focusline.koplugin.zip              the same file under a fixed name;
                                             this is the one attached to a GitHub
                                             release, so that the README's
                                             "Download" button always fetches the
                                             newest one

The version is read from _meta.lua. Everything in the zip sits inside a single
"focusline.koplugin" folder. Only the files the plugin needs at run time are
packed: screenshots, build scripts, and icons imported on this machine are
left out.

Run it through build.bat in the plugin folder, or directly:

    pwsh -File scripts\build-dist.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$pluginName = 'focusline.koplugin'
$root = Split-Path -Parent $PSScriptRoot
$distDir = Join-Path $root 'dist'

$meta = Get-Content -LiteralPath (Join-Path $root '_meta.lua') -Raw
if ($meta -notmatch 'version\s*=\s*"([^"]+)"') {
    throw 'Could not find version = "..." in _meta.lua'
}
$version = $Matches[1]

# Paths relative to the plugin folder.
$files = New-Object System.Collections.Generic.List[string]

foreach ($name in '_meta.lua', 'main.lua', 'README.md', 'CHANGES.md', 'LICENSE') {
    if (-not (Test-Path -LiteralPath (Join-Path $root $name))) {
        throw "Missing file: $name"
    }
    $files.Add($name)
}

foreach ($dir in 'lib', 'ui') {
    $base = Join-Path $root $dir
    Get-ChildItem -LiteralPath $base -Recurse -File -Filter '*.lua' | ForEach-Object {
        $files.Add($_.FullName.Substring($root.Length + 1))
    }
}

# The bundled edge images, but not the ones imported on this machine.
Get-ChildItem -LiteralPath (Join-Path $root 'icons') -File | ForEach-Object {
    $files.Add($_.FullName.Substring($root.Length + 1))
}
# Keeps the (empty) folder that imported edge images are copied into.
$files.Add('icons\user_imports\.gitkeep')

$files = $files | Sort-Object -Unique

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$zipPath = Join-Path $distDir "$pluginName.v$version.zip"
$latestPath = Join-Path $distDir "$pluginName.zip"
foreach ($path in $zipPath, $latestPath) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

# Written entry by entry rather than with Compress-Archive: older Windows
# PowerShell versions store paths with backslashes, which unpack as one flat
# list of oddly named files on Linux and Android - where KOReader runs.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in $files) {
            $source = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $source)) {
                throw "Missing file: $rel"
            }
            $entryName = "$pluginName/" + ($rel -replace '\\', '/')
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = (Get-Item -LiteralPath $source).LastWriteTime
            $in = [System.IO.File]::OpenRead($source)
            try {
                $out = $entry.Open()
                try {
                    $in.CopyTo($out)
                } finally {
                    $out.Dispose()
                }
            } finally {
                $in.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
} finally {
    $stream.Dispose()
}

Copy-Item -LiteralPath $zipPath -Destination $latestPath

$sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
Write-Host "Focusline $version - $($files.Count) files, $sizeKb KB"
Write-Host "  $zipPath"
Write-Host "  $latestPath"
