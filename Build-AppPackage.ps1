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

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    [void](New-Item -Path $outputDirectory -ItemType Directory -Force)
}

$sourceFiles = @(
    "AirPodsAutoSwitch.ps1",
    "AirPodsAutoSwitchApp.ps1",
    "Launch-AirPodsAutoSwitchApp.vbs",
    "Start-AirPodsAutoSwitchApp.cmd",
    "README.md"
)

foreach ($file in $sourceFiles) {
    $path = Join-Path $PSScriptRoot $file
    if (-not (Test-Path $path)) {
        throw "Missing package file: $path"
    }
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
AppLaunched=wscript.exe Launch-AirPodsAutoSwitchApp.vbs
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
$($fileStrings -join "`r`n")

[SourceFiles]
SourceFiles0=$PSScriptRoot\

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
