param(
    [Parameter(Mandatory = $true)]
    [string]$ServerHost,

    [string]$ServerUser = "deploy",
    [int]$ServerPort = 22,
    [string]$SshKeyPath = "",
    [string]$SourceDir = "",
    [switch]$BuildHtml,
    [switch]$SkipBuildHtml,
    [ValidateSet('pandoc-github')]
    [string]$HtmlRenderer = 'pandoc-github',
    [string]$HtmlHighlightStyle = 'pygments'
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Command not found: $cmd"
    }
}

function Ensure-PandocPath {
    if (Get-Command 'pandoc' -ErrorAction SilentlyContinue) {
        return
    }

    $localPandocDir = Join-Path $ScriptDir '..\tools\pandoc'
    $localPandocExe = Join-Path $localPandocDir 'pandoc.exe'
    if (Test-Path $localPandocExe) {
        $env:PATH = "$localPandocDir;$env:PATH"
        return
    }

    throw "Pandoc not found. Install pandoc or place pandoc.exe at: $localPandocExe"
}

Require-Command "ssh"
Require-Command "scp"
Require-Command "tar"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
} else {
    $SourceDir = (Resolve-Path $SourceDir).Path
}

if ($BuildHtml -and $SkipBuildHtml) {
    throw "BuildHtml and SkipBuildHtml cannot be used together."
}

$shouldBuildHtml = $BuildHtml -or (-not $SkipBuildHtml)
if ($shouldBuildHtml) {
    Require-Command "python"
    Ensure-PandocPath

    $builder = Join-Path $ScriptDir "..\tools\build_html_with_pandoc_template.py"
    $template = Join-Path $ScriptDir "..\tools\templates\pandoc_github_docs.html"
    if (-not (Test-Path $builder)) {
        throw "Builder script not found: $builder"
    }
    if (-not (Test-Path $template)) {
        throw "Template file not found: $template"
    }

    $jobs = @(
        @{ Md = "RCOS_API_DOC.md"; Html = "RCOS_API_DOC.html"; Title = "RCOS API DOC" },
        @{ Md = "5gos_liuyd.md"; Html = "5gos_liuyd.html"; Title = "5gos liuyd" }
    )

    foreach ($j in $jobs) {
        $mdPath = Join-Path $SourceDir $j.Md
        $htmlPath = Join-Path $SourceDir $j.Html

        if (-not (Test-Path $mdPath)) {
            throw "Markdown file not found: $mdPath"
        }

        Write-Host "Building HTML with Pandoc + GitHub style: $($j.Md) -> $($j.Html)"
        & python $builder --md $mdPath --out $htmlPath --title $j.Title --template $template --toc-depth 3 --highlight-style $HtmlHighlightStyle
        if ($LASTEXITCODE -ne 0) {
            throw "build html failed: $mdPath"
        }
    }
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
$bundle = Join-Path $env:TEMP "intra-docs-$stamp.tar.gz"
$remoteTmp = "/tmp/intra-docs-$stamp.tar.gz"
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

    # Use tar.gz to preserve UTF-8 filenames across Windows -> Linux deploy.
    & tar -C $tmpRoot -czf $bundle .
    if ($LASTEXITCODE -ne 0) {
        throw "tar create failed with exit code $LASTEXITCODE"
    }

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




