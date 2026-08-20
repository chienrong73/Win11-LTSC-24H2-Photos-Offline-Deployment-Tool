<#
.SYNOPSIS
    Defines configuration for Microsoft Photos offline deployment.

.DESCRIPTION
    Establishes the settings used by the Windows 11 LTSC 24H2 Microsoft Photos offline
    deployment workflow.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    File: Config.ps1
    Encoding: UTF-8
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Global:PhotosDeploymentConfig = [ordered]@{
    Project     = [ordered]@{
        Name    = 'Win11-LTSC-24H2-Photos-Offline-Deployment-Tool'
        Version = '2.0.0'
        Author  = 'Enterprise Endpoint Engineering'
        Company = 'Enterprise'
    }
    Deployment  = [ordered]@{
        Mode            = 'Offline'
        ContinueOnError = $false
        DryRun          = $false
    }
    Image       = [ordered]@{
        ImagePath       = Join-Path -Path $PSScriptRoot -ChildPath 'install.wim'
        MountPath       = Join-Path -Path $PSScriptRoot -ChildPath 'Mount'
        Index           = 1
        CommitOnSuccess = $true
        AutoUnmount     = $true
    }
    Package     = [ordered]@{
        RootPath         = Join-Path -Path $PSScriptRoot -ChildPath 'Packages'
        SupportedExtensions = @('.appx', '.appxbundle', '.msix', '.msixbundle')
    }
    Logging     = [ordered]@{
        EnableConsole = $true
        EnableFile    = $true
        LogFolder     = Join-Path -Path $PSScriptRoot -ChildPath 'Logs'
        LogFileName   = 'PhotosDeployment.log'
        LogLevel      = 'Information'
    }
    Validation  = [ordered]@{
        RequireAdministrator = $true
        RequirePowerShell51  = $true
        RequireDISM          = $true
        RequireWindows11     = $true
        MinimumBuild         = 26100
    }
    Retry       = [ordered]@{
        RetryCount        = 3
        RetryDelaySeconds = 5
    }
    Performance = [ordered]@{
        EnableProgress  = $true
        EnableStopwatch = $true
    }
}

function Get-DeploymentConfig {
    <#
    .SYNOPSIS
        Returns the Microsoft Photos deployment configuration.

    .DESCRIPTION
        Retrieves the global ordered configuration object used by the Windows 11 LTSC
        24H2 Microsoft Photos offline deployment workflow.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    return $Global:PhotosDeploymentConfig
}

function Test-DeploymentConfig {
    <#
    .SYNOPSIS
        Validates required Microsoft Photos deployment configuration values.

    .DESCRIPTION
        Validates required paths and numeric retry settings before deployment logic uses
        the global configuration object. Throws descriptive exceptions for invalid values.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param()

    $config = Get-DeploymentConfig

    if ([string]::IsNullOrWhiteSpace([string]$config.Image.ImagePath)) {
        throw 'Deployment configuration validation failed: Image.ImagePath must not be empty.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.Image.MountPath)) {
        throw 'Deployment configuration validation failed: Image.MountPath must not be empty.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.Package.RootPath)) {
        throw 'Deployment configuration validation failed: Package.RootPath must not be empty.'
    }

    if ([int]$config.Image.Index -lt 1) {
        throw 'Deployment configuration validation failed: Image.Index must be greater than or equal to 1.'
    }

    if ([int]$config.Retry.RetryCount -lt 0) {
        throw 'Deployment configuration validation failed: Retry.RetryCount must be greater than or equal to 0.'
    }

    if ([int]$config.Retry.RetryDelaySeconds -lt 0) {
        throw 'Deployment configuration validation failed: Retry.RetryDelaySeconds must be greater than or equal to 0.'
    }

    return $true
}

if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function 'Get-DeploymentConfig', 'Test-DeploymentConfig'
}
