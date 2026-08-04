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
Import-Module (Join-Path $moduleRoot 'Logger.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Common.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Validation.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Package.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Dism.psm1') -Force

$exitCode = 1
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
    Write-Fatal -Message $_.Exception.Message -Component 'Deployment'
    throw
}
finally {
    Close-Logger
    if ($MyInvocation.InvocationName -ne '.') { $host.SetShouldExit($exitCode) }
}
