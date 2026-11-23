#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'WithTemplates')]
param(
    [Parameter(Mandatory, ParameterSetName = 'WithTemplates')]
    [string] $TemplateBnf,

    [Parameter(Mandatory, ParameterSetName = 'WithTemplates')]
    [string] $TemplateBnl,

    [Parameter(Mandatory, ParameterSetName = 'WithoutTemplates')]
    [switch] $SkipTemplates,

    [ValidateSet('x64', 'arm64')]
    [string] $Architecture,
    [string] $SwiftRuntimeDirectory,
    [string] $MsvcRuntimeDirectory,
    [string] $Project,
    [string] $OutputDirectory,
    [string] $SwiftBuildSystem
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist\windows' }
if (-not $Project) {
    $projects = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Windows') -Filter '*.csproj' -File -Recurse)
    if ($projects.Count -ne 1) { throw 'Specify the Windows application .csproj using -Project.' }
    $Project = $projects[0].FullName
}
$Project = (Resolve-Path -LiteralPath $Project).Path
if (-not $SkipTemplates) {
    $TemplateBnf = (Resolve-Path -LiteralPath $TemplateBnf).Path
    $TemplateBnl = (Resolve-Path -LiteralPath $TemplateBnl).Path
}
$swift = (Get-Command swift.exe -CommandType Application -ErrorAction Stop).Source
$dotnet = (Get-Command dotnet.exe -CommandType Application -ErrorAction Stop).Source

function Invoke-Native {
    param([string] $Program, [string[]] $Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program exited with status $LASTEXITCODE." }
}

function Get-PeMachine {
    param([string] $File)
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($File))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Missing DOS header: $File" }
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Missing PE header: $File" }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
    }
}

$target = ((Invoke-Native $swift @('-print-target-info')) -join "`n" | ConvertFrom-Json).target.triple
$nativeArchitecture = switch -Regex ($target) {
    '^x86_64-.*-windows-msvc' { 'x64'; break }
    '^(arm64|aarch64)-.*-windows-msvc' { 'arm64'; break }
    default { throw "Swift target is not supported by this packaging script: $target" }
}
if ($Architecture -and $Architecture -ne $nativeArchitecture) {
    throw "Swift defaults to $nativeArchitecture. Use the $Architecture Windows toolchain to build this package."
}
$Architecture = $nativeArchitecture
$machine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xaa64 }

if (-not $SwiftRuntimeDirectory) {
    # Official layout: Swift\{Toolchains,Runtimes}\<version>\usr\bin.
    $toolchain = (Get-Item -LiteralPath $swift).Directory.Parent.Parent
    $swiftRoot = $toolchain.Parent.Parent.FullName
    $swiftVersion = $toolchain.Name -replace '\+.*$', ''
    $installedRuntime = Join-Path $swiftRoot "Runtimes\$swiftVersion\usr\bin"
    $directories = @($installedRuntime) + @($env:Path -split ';')
    $SwiftRuntimeDirectory = $directories | Where-Object {
        $_ -and (Test-Path -LiteralPath (Join-Path $_ 'swiftCore.dll') -PathType Leaf)
    } | Select-Object -First 1
}
if (-not $SwiftRuntimeDirectory -or
    -not (Test-Path -LiteralPath (Join-Path $SwiftRuntimeDirectory 'swiftCore.dll') -PathType Leaf)) {
    throw 'Could not locate the Swift runtime DLLs. Set -SwiftRuntimeDirectory to the matching Runtimes\<version>\usr\bin.'
}
$swiftCore = Join-Path $SwiftRuntimeDirectory 'swiftCore.dll'
if ((Get-PeMachine $swiftCore) -ne $machine) { throw "Swift runtime architecture does not match $Architecture." }

if (-not $MsvcRuntimeDirectory) {
    $redist = $env:VCToolsRedistDir
    if (-not $redist) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
            $vsInstall = Invoke-Native $vswhere @('-latest', '-products', '*', '-property', 'installationPath')
            if ($vsInstall) {
                $redist = Get-ChildItem -LiteralPath (Join-Path $vsInstall 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -as [version] } |
                    Sort-Object { [version] $_.Name } -Descending |
                    Select-Object -First 1 -ExpandProperty FullName
            }
        }
    }
    if ($redist) {
        $MsvcRuntimeDirectory = Get-ChildItem -LiteralPath (Join-Path $redist $Architecture) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.VC*.CRT' } |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $MsvcRuntimeDirectory -or
    -not (Test-Path -LiteralPath (Join-Path $MsvcRuntimeDirectory 'vcruntime140.dll') -PathType Leaf)) {
    throw 'Could not locate the matching redistributable VC++ CRT DLLs. Use a Visual Studio developer shell or specify -MsvcRuntimeDirectory.'
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('readingpen-win-' + [Guid]::NewGuid().ToString('N'))
$bundle = Join-Path $stage 'ReadingPenConverter'
$scratch = Join-Path $stage 'swift-build'
$templates = Join-Path $bundle 'Resources'
$originalPath = $env:Path
try {
    [void] (New-Item -ItemType Directory -Path $stage)
    $swiftArgs = @('build', '--package-path', $repo, '--scratch-path', $scratch, '-c', 'release')
    if ($SwiftBuildSystem) { $swiftArgs += @('--build-system', $SwiftBuildSystem) }
    Invoke-Native $swift ($swiftArgs + @('--product', 'penconvert'))
    $swiftBin = Invoke-Native $swift ($swiftArgs + @('--show-bin-path')) | Select-Object -Last 1
    $swiftExe = Join-Path $swiftBin 'penconvert.exe'
    if ((Get-PeMachine $swiftExe) -ne $machine) { throw "penconvert.exe architecture does not match $Architecture." }

    Invoke-Native $dotnet @('publish', $Project, '-c', 'Release', '-r', "win-$Architecture",
        '--self-contained', 'true', '-p:DebugType=None', '-o', $bundle)
    $gui = Join-Path $bundle 'ReadingPenConverter.exe'
    if ((Get-PeMachine $gui) -ne $machine) { throw "ReadingPenConverter.exe architecture does not match $Architecture." }
    Copy-Item -LiteralPath $swiftExe -Destination (Join-Path $bundle 'penconvert.exe')
    foreach ($runtime in @($SwiftRuntimeDirectory, $MsvcRuntimeDirectory)) {
        Get-ChildItem -LiteralPath $runtime -File -Filter '*.dll' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $bundle
        }
    }
    Copy-Item -LiteralPath (Join-Path $repo 'Sources\CMP3Decoder\LICENSE') -Destination (Join-Path $bundle 'minimp3-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $repo 'Sources\CMP3Decoder\UPSTREAM.md') -Destination (Join-Path $bundle 'minimp3-UPSTREAM.md')
    if (-not $SkipTemplates) {
        [void] (New-Item -ItemType Directory -Path $templates)
        Copy-Item -LiteralPath $TemplateBnf -Destination (Join-Path $templates 'target.bnf')
        Copy-Item -LiteralPath $TemplateBnl -Destination (Join-Path $templates 'target.bnl')
    }

    # Validate the shipped CLI without relying on the developer toolchain PATH.
    $env:Path = [Environment]::SystemDirectory + ';' + $env:SystemRoot
    $PSNativeCommandUseErrorActionPreference = $false
    $usage = & (Join-Path $bundle 'penconvert.exe')
    $usageStatus = $LASTEXITCODE
    $env:Path = $originalPath
    if ($usageStatus -ne 1 -or ($usage -join "`n") -notmatch 'penconvert inspect') {
        throw "The packaged converter could not start (exit $usageStatus)."
    }
    # PowerShell's CI wrapper propagates the last native exit code after this script returns.
    $global:LASTEXITCODE = 0

    [void] (New-Item -ItemType Directory -Path $OutputDirectory -Force)
    $suffix = if ($SkipTemplates) { '-without-templates' } else { '' }
    $archive = Join-Path $OutputDirectory "ReadingPenConverter-windows-$Architecture$suffix.zip"
    Compress-Archive -LiteralPath $bundle -DestinationPath $archive -CompressionLevel Optimal -Force
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
} finally {
    $env:Path = $originalPath
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
