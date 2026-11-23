#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Package,

    [Parameter(Mandatory)]
    [string] $InputBnf,

    [Parameter(Mandatory)]
    [string] $InputBnl,

    [string] $TemplateBnf,
    [string] $TemplateBnl,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string] $ExpectedBnfSha256,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string] $ExpectedBnlSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InputBnf = (Resolve-Path -LiteralPath $InputBnf).Path
$InputBnl = (Resolve-Path -LiteralPath $InputBnl).Path
$stage = Join-Path ([IO.Path]::GetTempPath()) ('readingpen-win-test-' + [Guid]::NewGuid().ToString('N'))
$originalPath = $env:Path
try {
    $source = Get-Item -LiteralPath $Package
    if ($source.PSIsContainer) {
        $bundle = $source.FullName
    } else {
        Expand-Archive -LiteralPath $source.FullName -DestinationPath $stage
        $bundle = Join-Path $stage 'ReadingPenConverter'
    }
    $converter = Join-Path $bundle 'penconvert.exe'
    if (-not (Test-Path -LiteralPath $converter -PathType Leaf)) { throw "Cannot find $converter." }
    if (-not $TemplateBnf) { $TemplateBnf = Join-Path $bundle 'Resources\target.bnf' }
    if (-not $TemplateBnl) { $TemplateBnl = Join-Path $bundle 'Resources\target.bnl' }
    $TemplateBnf = (Resolve-Path -LiteralPath $TemplateBnf).Path
    $TemplateBnl = (Resolve-Path -LiteralPath $TemplateBnl).Path

    # Include spaces and Chinese characters without relying on the script file encoding.
    $outputName = 'Conversion ' + [char]0x70b9 + [char]0x8bfb
    $outputFolder = Join-Path $stage $outputName
    [void] (New-Item -ItemType Directory -Path $outputFolder -Force)
    $cases = @(
        @{ Operation = 'convert-bnf-to-bnl'; Input = $InputBnf; Template = $TemplateBnl; Extension = 'bnl'; Expected = $ExpectedBnlSha256 },
        @{ Operation = 'convert-bnl-to-bnf'; Input = $InputBnl; Template = $TemplateBnf; Extension = 'bnf'; Expected = $ExpectedBnfSha256 }
    )
    $env:Path = [Environment]::SystemDirectory + ';' + $env:SystemRoot
    foreach ($case in $cases) {
        $output = Join-Path $outputFolder ("Book " + [char]0x97f3 + '.' + $case.Extension)
        & $converter $case.Operation $case.Input $case.Template $output '--audio-only' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$($case.Operation) failed with exit status $LASTEXITCODE." }
        $sum = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        $receipt = Get-Content -LiteralPath "$output.conversion.json" -Encoding UTF8 -Raw | ConvertFrom-Json
        $inputSum = (Get-FileHash -LiteralPath $case.Input -Algorithm SHA256).Hash
        if ($receipt.outputSHA256 -ne $sum -or $receipt.sourceSHA256 -ne $inputSum) {
            throw "$($case.Operation) report does not match the input and output files."
        }
        if ($case.Expected -and $case.Expected -ne $sum) {
            throw "$($case.Operation) SHA-256 differs from the known result: $sum"
        }
        Write-Output "$($case.Operation) SHA-256 $($sum.ToLowerInvariant())"
    }
} finally {
    $env:Path = $originalPath
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
