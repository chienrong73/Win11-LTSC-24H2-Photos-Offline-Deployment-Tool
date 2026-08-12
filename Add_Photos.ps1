<#
.SYNOPSIS
    Adds Microsoft Photos to an offline Windows image.
.DESCRIPTION
    Validates the deployment environment, discovers and verifies packages, then uses DISM
    to provision Microsoft Photos and its dependencies into the configured Windows image.
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

    $validation = Invoke-PreDeploymentValidation
    if (-not $validation.Passed) { throw ("Pre-deployment validation failed ({0} check(s) failed)." -f $validation.FailedCount) }

    $preparation = Invoke-PackagePreparation
    if (-not $preparation.Passed) { throw 'Package preparation failed.' }
    if (@($preparation.PhotosPackages).Count -ne 1) { throw 'Exactly one Microsoft Photos package is required.' }

    $invokeParameters = @{
        ImagePath            = [string]$config.Image.ImagePath
        MountPath            = [string]$config.Image.MountPath
        Index                = [int]$config.Image.Index
        PhotosPackagePath    = [string]$preparation.PhotosPackages[0]
        DependencyPackagePath = [string[]]$preparation.DependencyPackages
        CommitOnSuccess      = [bool]$config.Image.CommitOnSuccess
        AutoUnmount          = [bool]$config.Image.AutoUnmount
        WhatIf               = [bool]$WhatIfPreference
    }
    $result = Invoke-OfflineDeployment @invokeParameters
    Write-Success -Message 'Microsoft Photos offline deployment completed successfully.' -Component 'Deployment'
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
