param(
    [Parameter(Mandatory = $true)]
    [string]$ServerHost,

    [string]$ServerUser = "deploy",
    [int]$ServerPort = 22,
    [string]$SshKeyPath = "",
    [string]$SourceDir = ""
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Command not found: $cmd"
    }
}

function Compress-WithRetry {
    param(
        [string]$Path,
        [string]$Destination,
        [int]$MaxAttempts = 5,
        [int]$DelayMs = 800
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Compress-Archive -Path $Path -DestinationPath $Destination -Force
            return
        } catch {
            if ($i -eq $MaxAttempts) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Compress-NormalizedZip {
    param(
        [string]$SourceRoot,
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path $Destination) {
        Remove-Item $Destination -Force
    }

    $zip = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = Get-ChildItem -Path $SourceRoot -Recurse -File
        $root = [System.IO.Path]::GetFullPath($SourceRoot)
        if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $root += [System.IO.Path]::DirectorySeparatorChar
        }
        foreach ($f in $files) {
            $full = [System.IO.Path]::GetFullPath($f.FullName)
            if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $full.Substring($root.Length)
            }
            else {
                $rel = $f.Name
            }
            $entryName = $rel -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }
}

Require-Command "ssh"
Require-Command "scp"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
} else {
    $SourceDir = (Resolve-Path $SourceDir).Path
}

$required = @(
    "RCOS_API_DOC.html",
    "RCOS_API_DOC.assets",
    "5gos_liuyd.html",
    "5gos_liuyd.assets"
)

foreach ($p in $required) {
    $full = Join-Path $SourceDir $p
    if (-not (Test-Path $full)) {
        throw "Missing required path: $full"
    }
}

$stamp = Get-Date -Format "yyyyMMddHHmmss"
$tmpRoot = Join-Path $env:TEMP "intra-docs-$stamp"
$bundle = Join-Path $env:TEMP "intra-docs-$stamp.zip"
$remoteTmp = "/tmp/intra-docs-$stamp.zip"
$sshTarget = "$ServerUser@$ServerHost"

$scpArgs = @("-P", "$ServerPort")
$sshArgs = @("-p", "$ServerPort")
if (-not [string]::IsNullOrWhiteSpace($SshKeyPath)) {
    $scpArgs += @("-i", $SshKeyPath)
    $sshArgs += @("-i", $SshKeyPath)
}

$null = New-Item -ItemType Directory -Path $tmpRoot -Force
try {
    foreach ($p in $required) {
        Copy-Item -Path (Join-Path $SourceDir $p) -Destination $tmpRoot -Recurse -Force
    }

    if (Test-Path $bundle) {
        Remove-Item $bundle -Force
    }

    Compress-NormalizedZip -SourceRoot $tmpRoot -Destination $bundle

    Write-Host "Uploading bundle to $sshTarget ..."
    & scp @scpArgs $bundle "$sshTarget`:$remoteTmp"
    if ($LASTEXITCODE -ne 0) {
        throw "scp failed with exit code $LASTEXITCODE"
    }

    Write-Host "Running remote deploy script ..."
    $remoteCmd = "if command -v sudo >/dev/null 2>&1; then sudo /usr/local/bin/deploy-intra-docs.sh `"$remoteTmp`"; else /usr/local/bin/deploy-intra-docs.sh `"$remoteTmp`"; fi; rc=`$?; rm -f `"$remoteTmp`"; exit `$rc"
    & ssh @sshArgs $sshTarget $remoteCmd
    if ($LASTEXITCODE -ne 0) {
        throw "remote deploy failed with exit code $LASTEXITCODE"
    }
}
finally {
    if (Test-Path $tmpRoot) {
        Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $bundle) {
        Remove-Item -Path $bundle -Force -ErrorAction SilentlyContinue
    }
}

function Write-UrlLine {
    param(
        [string]$Url,
        [string]$Label
    )

    $supportsAnsi = $false
    try {
        if ($PSStyle.OutputRendering -ne 'PlainText') {
            $supportsAnsi = $true
        }
    } catch {
        $supportsAnsi = $false
    }

    if ($supportsAnsi) {
        $esc = [char]27
        Write-Host ("  {0}]8;;{1}{0}\{2}{0}]8;;{0}\" -f $esc, $Url, $Label)
        Write-Host "    $Url"
    } else {
        Write-Host "  $Url"
    }
}

Write-Host "Deploy complete."
Write-Host "URLs:"
$url1 = "http://$ServerHost`:9776/RCOS_API_DOC.html"
$url2 = "http://$ServerHost`:9776/5gos_liuyd.html"
Write-UrlLine -Url $url1 -Label "RCOS_API_DOC.html"
Write-UrlLine -Url $url2 -Label "5gos_liuyd.html"




