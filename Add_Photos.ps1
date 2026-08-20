<#
.SYNOPSIS
    Adds selected AppX/MSIX applications to an offline Windows image.
.DESCRIPTION
    Validates the deployment environment, discovers and verifies packages, then uses DISM
    to provision selected applications and their resolved dependencies into the configured Windows image.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()][ValidateNotNullOrEmpty()][string]$ImagePath,
    [Parameter()][ValidateNotNullOrEmpty()][string]$MountPath,
    [Parameter()][ValidateRange(1, 65535)][int]$Index,
    [Parameter()][ValidateNotNullOrEmpty()][string]$PackageRoot,
    [Parameter()][switch]$NoCommit,
    [Parameter()][switch]$KeepMounted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Config.ps1')
$config = Get-DeploymentConfig
if ($PSBoundParameters.ContainsKey('ImagePath')) { $config.Image.ImagePath = $ImagePath }
if ($PSBoundParameters.ContainsKey('MountPath')) { $config.Image.MountPath = $MountPath }
if ($PSBoundParameters.ContainsKey('Index')) { $config.Image.Index = $Index }
if ($PSBoundParameters.ContainsKey('PackageRoot')) { $config.Package.RootPath = $PackageRoot }
if ($NoCommit) { $config.Image.CommitOnSuccess = $false }
if ($KeepMounted) { $config.Image.AutoUnmount = $false }

$moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Modules'
$projectModulePaths = @(
    (Join-Path $moduleRoot 'Logger.psm1')
    (Join-Path $moduleRoot 'Common.psm1')
    (Join-Path $moduleRoot 'Validation.psm1')
    (Join-Path $moduleRoot 'Package.psm1')
    (Join-Path $moduleRoot 'Dism.psm1')
)
foreach ($modulePath in $projectModulePaths) {
    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

$requiredCommands = @(
    'Initialize-Logger'
    'Write-Header'
    'Write-Fatal'
    'Write-Success'
    'Close-Logger'
    'Invoke-PreDeploymentValidation'
    'Invoke-PackagePreparation'
    'Invoke-OfflineDeployment'
)
$missingCommands = @($requiredCommands | Where-Object {
    -not (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue)
})
if ($missingCommands.Count -gt 0) {
    throw ('Project module import did not expose required command(s): {0}. Module root: {1}' -f ($missingCommands -join ', '), $moduleRoot)
}

$exitCode = 1
$deploymentError = $null
try {
    Test-DeploymentConfig | Out-Null
    Initialize-Logger -EnableConsole $config.Logging.EnableConsole -EnableFile $config.Logging.EnableFile -LogFolder $config.Logging.LogFolder -LogFileName $config.Logging.LogFileName -LogLevel $config.Logging.LogLevel | Out-Null
    Write-Header -Message ("{0} v{1}" -f $config.Project.Name, $config.Project.Version)

    # These are convenience folders only. Discovery never assigns meaning to their names.
    foreach ($packageFolder in @('Common', 'Photos', 'StickyNotes')) {
        New-Item -ItemType Directory -Path (Join-Path ([string]$config.Package.RootPath) $packageFolder) -Force | Out-Null
    }

    $validation = Invoke-PreDeploymentValidation
    if (-not $validation.Passed) { throw ("Pre-deployment validation failed ({0} check(s) failed)." -f $validation.FailedCount) }

    $preparation = Invoke-PackagePreparation
    if (-not $preparation.Passed) { throw 'No main application packages were discovered.' }

    Write-Host ''
    for ($i = 0; $i -lt $preparation.Applications.Count; $i++) {
        $app = $preparation.Applications[$i]
        $status = if ($app.Resolution.Passed) { 'Ready' } else { 'Missing Dependencies' }
        Write-Host ('[{0}] {1}' -f ($i + 1),$app.DisplayName)
        Write-Host ('    Identity : {0}' -f $app.Identity)
        Write-Host ('    Version  : {0}' -f $app.Version)
        Write-Host ('    Architecture : {0}' -f $app.Architecture)
        Write-Host ('    Status   : {0}' -f $status)
        if (-not $app.Resolution.Passed) { foreach ($missing in $app.Resolution.Missing) { Write-Host ('    Missing  : {0}' -f $missing) } }
        Write-Host ''
    }
    Write-Host '[A] Install All Ready Applications'
    Write-Host '[Q] Quit'
    $selection = Read-Host 'Select applications (for example: 1,2 or A)'
    if ($selection -match '^(?i)q$') { $exitCode = 0; return }
    if ($selection -match '^(?i)a$') { $selected = @($preparation.Applications | Where-Object { $_.Resolution.Passed }) }
    else {
        $indexes = @($selection -split ',' | ForEach-Object { if ($_ -notmatch '^\s*\d+\s*$') { throw "Invalid selection: $_" }; [int]$_.Trim() } | Select-Object -Unique)
        $selected = @($indexes | ForEach-Object { if ($_ -lt 1 -or $_ -gt $preparation.Applications.Count) { throw "Selection is out of range: $_" }; $preparation.Applications[$_ - 1] })
    }
    if ($selected.Count -eq 0) { throw 'No ready applications were selected.' }
    $notReady = @($selected | Where-Object { -not $_.Resolution.Passed })
    if ($notReady.Count -gt 0) { throw ('Selected application(s) have missing dependencies: {0}' -f ($notReady.Identity -join ', ')) }
    $dependencyPaths = @($selected | ForEach-Object { $_.Resolution.Dependencies } | Group-Object Identity,Version,Architecture | ForEach-Object { $_.Group[0].Path })
    $applicationPaths = @($selected.Path | Select-Object -Unique)
    $expectedIdentities = @($selected.Identity + @($selected | ForEach-Object { $_.Resolution.Dependencies.Identity }) | Select-Object -Unique)

    $invokeParameters = @{
        ImagePath             = [string]$config.Image.ImagePath
        MountPath             = [string]$config.Image.MountPath
        Index                 = [int]$config.Image.Index
        ApplicationPackagePath = [string[]]$applicationPaths
        DependencyPackagePath = [string[]]$dependencyPaths
        ExpectedPackageIdentity = [string[]]$expectedIdentities
        CommitOnSuccess      = [bool]$config.Image.CommitOnSuccess
        AutoUnmount          = [bool]$config.Image.AutoUnmount
        ContinueOnError      = [bool]$config.Deployment.ContinueOnError
        WhatIf               = ([bool]$WhatIfPreference -or [bool]$config.Deployment.DryRun)
    }
    $result = Invoke-OfflineDeployment @invokeParameters
    Write-Success -Message 'Offline application deployment completed successfully.' -Component 'Deployment'
    $result
    $exitCode = 0
}
catch {
    $deploymentError = $_
    try {
        Write-Fatal -Message $deploymentError.Exception.Message -Component 'Deployment'
    }
    catch {
        Microsoft.PowerShell.Utility\Write-Warning -Message ('Unable to log deployment failure: {0}' -f $_.Exception.Message)
    }
}
finally {
    try {
        Close-Logger
    }
    catch {
        Microsoft.PowerShell.Utility\Write-Warning -Message ('Logger cleanup failed: {0}' -f $_.Exception.Message)
    }
}

if ($deploymentError) {
    if ($MyInvocation.InvocationName -eq '.') {
        throw $deploymentError
    }

    Microsoft.PowerShell.Utility\Write-Error -ErrorRecord $deploymentError -ErrorAction Continue
}

if ($MyInvocation.InvocationName -ne '.') { exit $exitCode }
