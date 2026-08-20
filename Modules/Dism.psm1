<#
.SYNOPSIS
    Provides DISM operations for Microsoft Photos offline deployment.
.DESCRIPTION
    Wraps dism.exe with checked exit codes and coordinates the complete mount, package
    servicing, save, and dismount workflow. Compatible with Windows PowerShell 5.1.
#>
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LoggerModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Logger.psm1'
Import-Module -Name $script:LoggerModulePath -Force

function Invoke-DismExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $command = Get-Command -Name 'dism.exe' -CommandType Application -ErrorAction Stop
    Write-Info -Message ("Starting DISM operation: {0}" -f $Operation) -Component 'Dism'
    $output = @(& $command.Source @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-Debug -Message ([string]$line) -Component 'Dism' }
    if ($exitCode -notin @(0, 3010)) {
        throw ("DISM operation '{0}' failed with exit code {1}. {2}" -f $Operation, $exitCode, ($output -join [Environment]::NewLine))
    }
    if ($exitCode -eq 3010) {
        Write-Warning -Message ("DISM operation '{0}' requires a restart." -f $Operation) -Component 'Dism'
    }
    return [pscustomobject]@{ Operation = $Operation; ExitCode = $exitCode; Output = $output; RestartRequired = ($exitCode -eq 3010) }
}

function Mount-WindowsImage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ImagePath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath,
        [Parameter()][ValidateRange(1, 65535)][int]$Index = 1,
        [Parameter()][switch]$ReadOnly
    )
    if (-not (Test-Path -LiteralPath $MountPath -PathType Container)) { New-Item -Path $MountPath -ItemType Directory -Force | Out-Null }
    $arguments = @('/English', '/Mount-Image', ('/ImageFile:{0}' -f $ImagePath), ('/Index:{0}' -f $Index), ('/MountDir:{0}' -f $MountPath))
    if ($ReadOnly) { $arguments += '/ReadOnly' }
    if ($PSCmdlet.ShouldProcess($ImagePath, "Mount image index $Index at $MountPath")) { Invoke-DismExecutable -ArgumentList $arguments -Operation 'Mount Windows image' }
}

function Dismount-WindowsImage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath,
        [Parameter()][switch]$Save
    )
    $action = if ($Save) { '/Commit' } else { '/Discard' }
    if ($PSCmdlet.ShouldProcess($MountPath, "Dismount Windows image ($action)")) {
        Invoke-DismExecutable -ArgumentList @('/English', '/Unmount-Image', ('/MountDir:{0}' -f $MountPath), $action) -Operation 'Dismount Windows image'
    }
}

function Save-WindowsImage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath)
    if ($PSCmdlet.ShouldProcess($MountPath, 'Save Windows image changes')) {
        Invoke-DismExecutable -ArgumentList @('/English', '/Commit-Image', ('/MountDir:{0}' -f $MountPath)) -Operation 'Save Windows image'
    }
}

function Get-WindowsImageInfo {
    [CmdletBinding(DefaultParameterSetName = 'Image')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Image')][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ImagePath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Mounted')][ValidateNotNullOrEmpty()][string]$MountPath,
        [Parameter(ParameterSetName = 'Image')][ValidateRange(1, 65535)][int]$Index
    )
    $arguments = @('/English', '/Get-ImageInfo')
    if ($PSCmdlet.ParameterSetName -eq 'Mounted') { $arguments += ('/Image:{0}' -f $MountPath) }
    else {
        $arguments += ('/ImageFile:{0}' -f $ImagePath)
        if ($PSBoundParameters.ContainsKey('Index')) { $arguments += ('/Index:{0}' -f $Index) }
    }
    Invoke-DismExecutable -ArgumentList $arguments -Operation 'Get Windows image information'
}

function Add-OfflinePackage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath,
        [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string[]]$PackagePath
    )
    foreach ($package in $PackagePath) {
        if ($PSCmdlet.ShouldProcess($package, "Add package to $MountPath")) {
            Invoke-DismExecutable -ArgumentList @('/English', ('/Image:{0}' -f $MountPath), '/Add-ProvisionedAppxPackage', ('/PackagePath:{0}' -f $package), '/SkipLicense') -Operation ("Add offline package {0}" -f (Split-Path -Leaf $package))
        }
    }
}

function Remove-OfflinePackage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$PackageName
    )
    foreach ($package in $PackageName) {
        if ($PSCmdlet.ShouldProcess($package, "Remove package from $MountPath")) {
            Invoke-DismExecutable -ArgumentList @('/English', ('/Image:{0}' -f $MountPath), '/Remove-ProvisionedAppxPackage', ('/PackageName:{0}' -f $package)) -Operation ("Remove offline package {0}" -f $package)
        }
    }
}

function Get-OfflinePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath)
    Invoke-DismExecutable -ArgumentList @('/English', ('/Image:{0}' -f $MountPath), '/Get-ProvisionedAppxPackages') -Operation 'Get offline packages'
}

function Test-MountState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MountPath)
    try {
        $result = Invoke-DismExecutable -ArgumentList @('/English', '/Get-MountedImageInfo') -Operation 'Get mounted image state'
        $escapedPath = [regex]::Escape([System.IO.Path]::GetFullPath($MountPath).TrimEnd('\'))
        return [bool](($result.Output -join "`n") -match ("Mount Dir\s*:\s*{0}(\s|$)" -f $escapedPath))
    }
    catch { Write-Warning -Message $_.Exception.Message -Component 'Dism'; return $false }
}

function Invoke-OfflineDeployment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$MountPath,
        [Parameter(Mandatory = $true)][string[]]$ApplicationPackagePath,
        [Parameter()][string[]]$DependencyPackagePath = @(),
        [Parameter()][string[]]$ExpectedPackageIdentity = @(),
        [Parameter()][ValidateRange(1, 65535)][int]$Index = 1,
        [Parameter()][bool]$CommitOnSuccess = $true,
        [Parameter()][bool]$AutoUnmount = $true,
        [Parameter()][bool]$ContinueOnError = $false
    )
    $mountedHere = $false
    $committed = $false
    try {
        $wasMounted = Test-MountState -MountPath $MountPath
        if (-not $wasMounted) {
            Mount-WindowsImage -ImagePath $ImagePath -MountPath $MountPath -Index $Index -WhatIf:$WhatIfPreference | Out-Null
            $mountedHere = -not $WhatIfPreference
        }
        $installationErrors = @()
        foreach ($dependency in $DependencyPackagePath) {
            try { Add-OfflinePackage -MountPath $MountPath -PackagePath $dependency -WhatIf:$WhatIfPreference | Out-Null }
            catch { $installationErrors += $_; if (-not $ContinueOnError) { throw } }
        }
        foreach ($application in $ApplicationPackagePath) {
            try { Add-OfflinePackage -MountPath $MountPath -PackagePath $application -WhatIf:$WhatIfPreference | Out-Null }
            catch { $installationErrors += $_; if (-not $ContinueOnError) { throw } }
        }
        if ($installationErrors.Count -gt 0) {
            throw ('One or more package installations failed: {0}' -f (($installationErrors | ForEach-Object { $_.Exception.Message }) -join '; '))
        }

        if (-not $WhatIfPreference) {
            $provisioned = Get-OfflinePackage -MountPath $MountPath
            $provisionedText = $provisioned.Output -join "`n"
            $missingIdentity = @($ExpectedPackageIdentity | Where-Object { $provisionedText -notmatch [regex]::Escape($_) })
            if ($missingIdentity.Count -gt 0) { throw ('Post-install verification did not find: {0}' -f ($missingIdentity -join ', ')) }
        }

        if ($CommitOnSuccess) {
            if ($AutoUnmount -and $mountedHere) {
                Dismount-WindowsImage -MountPath $MountPath -Save -WhatIf:$WhatIfPreference | Out-Null
                $committed = -not $WhatIfPreference
                $mountedHere = $false
            }
            else {
                Save-WindowsImage -MountPath $MountPath -WhatIf:$WhatIfPreference | Out-Null
                $committed = -not $WhatIfPreference
            }
        }
        elseif ($AutoUnmount -and $mountedHere) {
            Dismount-WindowsImage -MountPath $MountPath -WhatIf:$WhatIfPreference | Out-Null
            $mountedHere = $false
        }

        return [pscustomobject]@{ Succeeded = $true; ImagePath = $ImagePath; MountPath = $MountPath; Committed = $committed; Timestamp = Get-Date }
    }
    catch {
        Write-Fatal -Message ("Offline deployment failed: {0}" -f $_.Exception.Message) -Component 'Dism'
        if ($mountedHere) {
            try {
                # A mount owned by this invocation is always discarded after failure, even
                # when KeepMounted was requested; preserving a dirty image is never safe.
                Dismount-WindowsImage -MountPath $MountPath -WhatIf:$WhatIfPreference | Out-Null
                $mountedHere = $false
            }
            catch { Write-Warning -Message ("Cleanup failed: {0}" -f $_.Exception.Message) -Component 'Dism' }
        }
        throw
    }
}

Export-ModuleMember -Function 'Mount-WindowsImage', 'Dismount-WindowsImage', 'Save-WindowsImage', 'Get-WindowsImageInfo', 'Add-OfflinePackage', 'Remove-OfflinePackage', 'Get-OfflinePackage', 'Test-MountState', 'Invoke-OfflineDeployment'
