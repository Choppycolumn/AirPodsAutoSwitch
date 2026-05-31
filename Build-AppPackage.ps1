[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "dist\AirPodsAutoSwitchApp.exe"
}

$iexpress = Join-Path $env:WINDIR "System32\iexpress.exe"
if (-not (Test-Path $iexpress)) {
    throw "IExpress was not found at $iexpress"
}

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) {
    throw "The .NET Framework C# compiler was not found."
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    [void](New-Item -Path $outputDirectory -ItemType Directory -Force)
}

$buildDirectory = Join-Path $PSScriptRoot "build"
if (-not (Test-Path $buildDirectory)) {
    [void](New-Item -Path $buildDirectory -ItemType Directory -Force)
}

$packageDirectory = Join-Path $buildDirectory "package"
if (-not (Test-Path $packageDirectory)) {
    [void](New-Item -Path $packageDirectory -ItemType Directory -Force)
}

$launcherSource = Join-Path $PSScriptRoot "AirPodsAutoSwitchLauncher.cs"
$launcherOutput = Join-Path $packageDirectory "AirPodsAutoSwitchLauncher.exe"
& $csc /nologo /target:winexe /out:$launcherOutput /reference:System.Windows.Forms.dll $launcherSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $launcherOutput)) {
    throw "Failed to compile launcher."
}

$sourceFiles = @(
    "AirPodsAutoSwitchLauncher.exe",
    "AirPodsAutoSwitch.ps1",
    "AirPodsAutoSwitchApp.ps1",
    "Start-AirPodsAutoSwitchApp.cmd",
    "README.md"
)

foreach ($file in $sourceFiles | Where-Object { $_ -ne "AirPodsAutoSwitchLauncher.exe" }) {
    $sourcePath = Join-Path $PSScriptRoot $file
    $destinationPath = Join-Path $packageDirectory $file
    if (-not (Test-Path $sourcePath)) {
        throw "Missing package file: $sourcePath"
    }
    Copy-Item -Path $sourcePath -Destination $destinationPath -Force
}

$absoluteOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$sedPath = Join-Path $PSScriptRoot "AirPodsAutoSwitchApp.sed"

$fileStrings = New-Object System.Collections.Generic.List[string]
$sourceEntries = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $sourceFiles.Count; $i++) {
    $fileStrings.Add(("FILE{0}={1}" -f $i, $sourceFiles[$i]))
    $sourceEntries.Add(("%FILE{0}%=" -f $i))
}

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3

[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles

[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$absoluteOutput
FriendlyName=AirPods Auto Switch
AppLaunched=AirPodsAutoSwitchLauncher.exe
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
$($fileStrings -join "`r`n")

[SourceFiles]
SourceFiles0=$packageDirectory\

[SourceFiles0]
$($sourceEntries -join "`r`n")
"@

Set-Content -Path $sedPath -Value $sed -Encoding ASCII

& $iexpress /N /Q $sedPath
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "IExpress failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $absoluteOutput)) {
    throw "Package was not created: $absoluteOutput"
}

Get-Item $absoluteOutput
