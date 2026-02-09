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

    Compress-WithRetry -Path (Join-Path $tmpRoot "*") -Destination $bundle

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

Write-Host "Deploy complete."
Write-Host "URLs:"
Write-Host "  http://$ServerHost`:9776/RCOS_API_DOC.html"
Write-Host "  http://$ServerHost`:9776/5gos_liuyd.html"

