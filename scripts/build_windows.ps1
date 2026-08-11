[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+([+-][0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BuildNumber
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw '未找到 Flutter，请先安装并加入 PATH。'
}

$ScriptRoot = Split-Path -Parent $PSCommandPath
$CliRoot = Split-Path -Parent $ScriptRoot
$AppRoot = Join-Path $CliRoot 'app'
$OutputDir = Join-Path $CliRoot "dist\$Version+$BuildNumber"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Push-Location $AppRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 依赖解析失败。' }

    flutter build windows --release "--build-name=$Version" "--build-number=$BuildNumber"
    if ($LASTEXITCODE -ne 0) { throw 'Windows 构建失败。' }

    $ProductDir = Join-Path $AppRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path $ProductDir)) {
        throw "Windows 产物不存在：$ProductDir"
    }

    $Archive = Join-Path $OutputDir "hive-cli-windows-$Version.zip"
    Compress-Archive -Path (Join-Path $ProductDir '*') -DestinationPath $Archive -Force

    $HashFile = Join-Path $OutputDir 'SHA256SUMS'
    (Get-FileHash -Algorithm SHA256 $Archive | ForEach-Object {
        "$($_.Hash.ToLower())  $($_.Name)"
    }) | Set-Content -Encoding utf8 $HashFile

    $Commit = (git -C $CliRoot rev-parse HEAD 2>$null)
    if (-not $Commit) { $Commit = 'unknown' }
    [ordered]@{
        product = 'hive-cli'
        version = $Version
        buildNumber = $BuildNumber
        gitCommit = $Commit
        builtAt = [DateTime]::UtcNow.ToString('o')
        artifacts = 'See SHA256SUMS'
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $OutputDir 'release.json')

    Write-Host "构建完成：$OutputDir"
    Write-Host "版本：$Version+$BuildNumber"
} finally {
    Pop-Location
}
