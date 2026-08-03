<#
.SYNOPSIS
    Provides DISM integration services for Microsoft Photos offline deployment.

.DESCRIPTION
    Implements Windows image mounting, package servicing, image saving, dismounting,
    mount-state validation, and full offline deployment orchestration for the Windows 11
    LTSC 24H2 Microsoft Photos offline deployment tool. DISM PowerShell cmdlets are used
    when available, with automatic fallback to dism.exe.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    Module: Dism
    File: Modules/Dism.psm1
    Encoding: UTF-8 with BOM
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleMetadata = [ordered]@{
    Name        = 'Dism'
    Version     = '1.0.0'
    Description = 'DISM integration services for Microsoft Photos offline deployment.'
    Project     = 'Win11-LTSC-24H2-Photos-Offline-Deployment-Tool'
    Encoding    = 'UTF-8 with BOM'
}

$script:LoggerModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Logger.psm1'
$script:CommonModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Common.psm1'
$script:ValidationModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Validation.psm1'
$script:PackageModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Package.psm1'
Import-Module -Name $script:LoggerModulePath -Force
Import-Module -Name $script:CommonModulePath -Force
Import-Module -Name $script:ValidationModulePath -Force
Import-Module -Name $script:PackageModulePath -Force

function Get-DismDeploymentConfig {
    <#
    .SYNOPSIS
        Returns the deployment configuration for DISM operations.

    .DESCRIPTION
        Loads Config.ps1 when needed and returns the global deployment configuration used by
        DISM servicing functions.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $configurationVariable = Get-Variable -Name 'PhotosDeploymentConfig' -Scope Global -ErrorAction SilentlyContinue

    if (-not $configurationVariable) {
        $configPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Config.ps1'

        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            . $configPath
        }
    }

    return (Get-Variable -Name 'PhotosDeploymentConfig' -Scope Global -ErrorAction Stop).Value
}

function Get-DismCmdlet {
    <#
    .SYNOPSIS
        Gets a DISM PowerShell cmdlet by name.

    .DESCRIPTION
        Finds a DISM cmdlet without resolving to wrapper functions defined by this module.

    .PARAMETER Name
        DISM cmdlet name to find.

    .OUTPUTS
        System.Management.Automation.CommandInfo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-Command -Name $Name -CommandType Cmdlet -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Invoke-DismExe {
    <#
    .SYNOPSIS
        Invokes dism.exe with arguments.

    .DESCRIPTION
        Executes dism.exe with the provided argument list and throws a logged terminating
        error when dism.exe returns a non-zero exit code.

    .PARAMETER Arguments
        Arguments to pass to dism.exe.

    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string[]]
        $Arguments
    )

    $dismCommand = Get-Command -Name 'dism.exe' -CommandType Application -ErrorAction SilentlyContinue

    if (-not $dismCommand) {
        Write-Fatal -Message 'dism.exe was not found and DISM PowerShell cmdlets are unavailable.' -Component 'Dism'
        throw 'dism.exe was not found.'
    }

    Write-Info -Message ('Executing dism.exe {0}' -f ($Arguments -join ' ')) -Component 'Dism'
    $output = & $dismCommand.Source @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Fatal -Message ('dism.exe failed with exit code {0}: {1}' -f $exitCode, ($output -join [System.Environment]::NewLine)) -Component 'Dism'
        throw ('dism.exe failed with exit code {0}.' -f $exitCode)
    }

    return $output
}

function Invoke-DismModuleError {
    <#
    .SYNOPSIS
        Logs and throws a DISM module error.

    .DESCRIPTION
        Writes the supplied error through the Logger module and throws a terminating
        exception for callers that cannot safely continue.

    .PARAMETER Message
        Error message to log and throw.

    .PARAMETER Exception
        Optional source exception.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [System.Exception]
        $Exception
    )

    if ($Exception) {
        Write-Error -Message ('{0} Details: {1}' -f $Message, $Exception.Message) -Component 'Dism'
        throw (New-Object -TypeName System.InvalidOperationException -ArgumentList $Message, $Exception)
    }

    Write-Error -Message $Message -Component 'Dism'
    throw $Message
}

function Mount-WindowsImage {
    <#
    .SYNOPSIS
        Mounts a Windows image for offline servicing.

    .DESCRIPTION
        Mounts a supported install.wim or install.esd image using the configured or supplied
        image path, mount path, image index, and read-only mode. DISM PowerShell cmdlets are
        preferred, with automatic fallback to dism.exe.

    .PARAMETER ImagePath
        Path to the install.wim or install.esd file. Defaults to Config.ps1 Image.ImagePath.

    .PARAMETER MountPath
        Directory where the image should be mounted. Defaults to Config.ps1 Image.MountPath.

    .PARAMETER Index
        Image index to mount. Defaults to Config.ps1 Image.Index.

    .PARAMETER ReadOnly
        Mounts the image read-only.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $ImagePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]
        $Index,

        [Parameter()]
        [switch]
        $ReadOnly
    )

    try {
        $config = Get-DismDeploymentConfig

        if (-not $PSBoundParameters.ContainsKey('ImagePath')) { $ImagePath = [string]$config.Image.ImagePath }
        if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }
        if (-not $PSBoundParameters.ContainsKey('Index')) { $Index = [int]$config.Image.Index }

        $imageValidation = Test-ImageFile -ImagePath $ImagePath

        if (-not $imageValidation['Passed']) {
            Invoke-DismModuleError -Message ('Image validation failed: {0}' -f $imageValidation['Message'])
        }

        New-Directory -Path $MountPath | Out-Null
        Write-Info -Message ('Mounting image {0} index {1} to {2}.' -f $ImagePath, $Index, $MountPath) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Mount-WindowsImage'

        if ($cmdlet) {
            $parameters = @{ ImagePath = $ImagePath; Index = $Index; Path = $MountPath }
            if ($ReadOnly) { $parameters['ReadOnly'] = $true }
            & $cmdlet @parameters | Out-Null
        }
        else {
            $arguments = @('/Mount-Image', ('/ImageFile:{0}' -f $ImagePath), ('/Index:{0}' -f $Index), ('/MountDir:{0}' -f $MountPath))
            if ($ReadOnly) { $arguments += '/ReadOnly' }
            Invoke-DismExe -Arguments $arguments | Out-Null
        }

        return (Test-MountState -MountPath $MountPath)
    }
    catch {
        $mountException = $_.Exception

        if ($MountPath) {
            try {
                $mountState = Test-MountState -MountPath $MountPath

                if ($mountState['IsMounted']) {
                    Write-Warning -Message ('Mount operation failed after image was mounted. Discarding mount at {0}.' -f $MountPath) -Component 'Dism'
                    [void](Dismount-WindowsImage -MountPath $MountPath -Discard)
                }
            }
            catch {
                Write-Fatal -Message ('Automatic cleanup after mount failure failed: {0}' -f $_.Exception.Message) -Component 'Dism'
            }
        }

        Invoke-DismModuleError -Message 'Unable to mount Windows image.' -Exception $mountException
    }
}

function Dismount-WindowsImage {
    <#
    .SYNOPSIS
        Dismounts a Windows image.

    .DESCRIPTION
        Dismounts the mounted Windows image and either commits or discards pending changes.
        DISM PowerShell cmdlets are preferred, with automatic fallback to dism.exe.

    .PARAMETER MountPath
        Mounted image directory. Defaults to Config.ps1 Image.MountPath.

    .PARAMETER Commit
        Saves changes while dismounting.

    .PARAMETER Discard
        Discards changes while dismounting.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding(DefaultParameterSetName = 'Discard')]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath,

        [Parameter(ParameterSetName = 'Commit')]
        [switch]
        $Commit,

        [Parameter(ParameterSetName = 'Discard')]
        [switch]
        $Discard
    )

    try {
        $config = Get-DismDeploymentConfig
        if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }

        if (-not $Commit -and -not $Discard) { $Discard = $true }
        Write-Info -Message ('Dismounting image at {0}; commit={1}; discard={2}.' -f $MountPath, [bool]$Commit, [bool]$Discard) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Dismount-WindowsImage'

        if ($cmdlet) {
            $parameters = @{ Path = $MountPath }
            if ($Commit) { $parameters['Save'] = $true } else { $parameters['Discard'] = $true }
            & $cmdlet @parameters | Out-Null
        }
        else {
            $arguments = @('/Unmount-Image', ('/MountDir:{0}' -f $MountPath))
            if ($Commit) { $arguments += '/Commit' } else { $arguments += '/Discard' }
            Invoke-DismExe -Arguments $arguments | Out-Null
        }

        return (Test-MountState -MountPath $MountPath)
    }
    catch {
        Invoke-DismModuleError -Message 'Unable to dismount Windows image.' -Exception $_.Exception
    }
}

function Save-WindowsImage {
    <#
    .SYNOPSIS
        Saves changes to a mounted Windows image.

    .DESCRIPTION
        Commits pending changes to a mounted Windows image without dismounting it. DISM
        PowerShell cmdlets are preferred, with automatic fallback to dism.exe.

    .PARAMETER MountPath
        Mounted image directory. Defaults to Config.ps1 Image.MountPath.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath
    )

    try {
        $config = Get-DismDeploymentConfig
        if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }

        Write-Info -Message ('Saving mounted image changes at {0}.' -f $MountPath) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Save-WindowsImage'

        if ($cmdlet) {
            & $cmdlet -Path $MountPath | Out-Null
        }
        else {
            Invoke-DismExe -Arguments @('/Commit-Image', ('/MountDir:{0}' -f $MountPath)) | Out-Null
        }

        return (Test-MountState -MountPath $MountPath)
    }
    catch {
        Invoke-DismModuleError -Message 'Unable to save Windows image.' -Exception $_.Exception
    }
}

function Get-WindowsImageInfo {
    <#
    .SYNOPSIS
        Gets Windows image metadata.

    .DESCRIPTION
        Retrieves image metadata for a supported install.wim or install.esd file. DISM
        PowerShell cmdlets are preferred, with automatic fallback to dism.exe.

    .PARAMETER ImagePath
        Image file path. Defaults to Config.ps1 Image.ImagePath.

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $ImagePath
    )

    try {
        $config = Get-DismDeploymentConfig
        if (-not $PSBoundParameters.ContainsKey('ImagePath')) { $ImagePath = [string]$config.Image.ImagePath }

        $imageValidation = Test-ImageFile -ImagePath $ImagePath
        if (-not $imageValidation['Passed']) { Invoke-DismModuleError -Message ('Image validation failed: {0}' -f $imageValidation['Message']) }

        Write-Info -Message ('Retrieving Windows image info from {0}.' -f $ImagePath) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Get-WindowsImage'

        if ($cmdlet) {
            return (& $cmdlet -ImagePath $ImagePath)
        }

        return (Invoke-DismExe -Arguments @('/Get-WimInfo', ('/WimFile:{0}' -f $ImagePath)))
    }
    catch {
        Invoke-DismModuleError -Message 'Unable to get Windows image information.' -Exception $_.Exception
    }
}

function Add-OfflinePackage {
    <#
    .SYNOPSIS
        Adds an offline app package to a mounted image.

    .DESCRIPTION
        Adds an AppX/MSIX package to the mounted offline Windows image as a provisioned app
        package. DISM PowerShell cmdlets are preferred, with automatic fallback to dism.exe.

    .PARAMETER MountPath
        Mounted image directory. Defaults to Config.ps1 Image.MountPath.

    .PARAMETER PackagePath
        AppX/MSIX package file path to add.

    .PARAMETER DependencyPackagePath
        Optional dependency package paths required by the app package.

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath,

        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PackagePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $DependencyPackagePath
    )

    try {
        $config = Get-DismDeploymentConfig
        if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }

        $integrity = Test-PackageIntegrity -PackagePath $PackagePath
        if (-not $integrity['Passed']) { Invoke-DismModuleError -Message ('Package integrity failed: {0}' -f $integrity['Message']) }

        foreach ($dependencyPath in @($DependencyPackagePath)) {
            $dependencyIntegrity = Test-PackageIntegrity -PackagePath $dependencyPath
            if (-not $dependencyIntegrity['Passed']) { Invoke-DismModuleError -Message ('Dependency package integrity failed: {0}' -f $dependencyIntegrity['Message']) }
        }

        Write-Info -Message ('Adding provisioned app package {0} to {1}.' -f $PackagePath, $MountPath) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Add-AppxProvisionedPackage'

        if ($cmdlet) {
            $parameters = @{ Path = $MountPath; PackagePath = $PackagePath; SkipLicense = $true }
            if ($DependencyPackagePath -and $DependencyPackagePath.Count -gt 0) { $parameters['DependencyPackagePath'] = $DependencyPackagePath }
            return (& $cmdlet @parameters)
        }

        $arguments = @('/Image:{0}' -f $MountPath, '/Add-ProvisionedAppxPackage', ('/PackagePath:{0}' -f $PackagePath), '/SkipLicense')
        foreach ($dependencyPath in @($DependencyPackagePath)) {
            $arguments += ('/DependencyPackagePath:{0}' -f $dependencyPath)
        }

        return (Invoke-DismExe -Arguments $arguments)
    }
    catch {
        Invoke-DismModuleError -Message 'Unable to add offline app package.' -Exception $_.Exception
    }
}

function Remove-OfflinePackage {
    <#
    .SYNOPSIS
        Removes an offline package from a mounted image.

    .DESCRIPTION
        Removes a provisioned app package from a mounted offline Windows image by package
        identity name. DISM PowerShell cmdlets are preferred, with automatic fallback to
        dism.exe.

    .PARAMETER MountPath
        Mounted image directory. Defaults to Config.ps1 Image.MountPath.

    .PARAMETER PackageName
        Package identity name to remove.

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath,

        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PackageName
    )

    try {
        $config = Get-DismDeploymentConfig
        if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }

        Write-Info -Message ('Removing offline package {0} from {1}.' -f $PackageName, $MountPath) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Remove-AppxProvisionedPackage'

        if ($cmdlet) {
            return (& $cmdlet -Path $MountPath -PackageName $PackageName)
        }

        return (Invoke-DismExe -Arguments @('/Image:{0}' -f $MountPath, '/Remove-ProvisionedAppxPackage', ('/PackageName:{0}' -f $PackageName)))
    }
    catch {
        Invoke-DismModuleError -Message 'Unable to remove offline package.' -Exception $_.Exception
    }
}

function Get-OfflinePackage {
    <#
    .SYNOPSIS
        Gets packages installed in a mounted image.

    .DESCRIPTION
        Retrieves provisioned app packages currently present in the mounted offline Windows image.
        DISM PowerShell cmdlets are preferred, with automatic fallback to dism.exe.

    .PARAMETER MountPath
        Mounted image directory. Defaults to Config.ps1 Image.MountPath.

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath
    )

    try {
        $config = Get-DismDeploymentConfig
        if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }

        Write-Info -Message ('Getting offline package list from {0}.' -f $MountPath) -Component 'Dism'
        $cmdlet = Get-DismCmdlet -Name 'Get-AppxProvisionedPackage'

        if ($cmdlet) {
            return (& $cmdlet -Path $MountPath)
        }

        return (Invoke-DismExe -Arguments @('/Image:{0}' -f $MountPath, '/Get-ProvisionedAppxPackages'))
    }
    catch {
        Invoke-DismModuleError -Message 'Unable to get offline package list.' -Exception $_.Exception
    }
}

function Test-MountState {
    <#
    .SYNOPSIS
        Tests the current mount state.

    .DESCRIPTION
        Checks whether the mount folder exists, whether DISM reports the image as mounted,
        and whether the mount folder is writable.

    .PARAMETER MountPath
        Mounted image directory. Defaults to Config.ps1 Image.MountPath.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $MountPath
    )

    $config = Get-DismDeploymentConfig
    if (-not $PSBoundParameters.ContainsKey('MountPath')) { $MountPath = [string]$config.Image.MountPath }

    $folderExists = Test-PathExists -Path $MountPath -PathType Container
    $isMounted = $false
    $isWritable = $false

    if ($folderExists) {
        try {
            $testFile = Join-Path -Path $MountPath -ChildPath ('.write-test-{0}.tmp' -f ([System.Guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $testFile -Value 'test' -Encoding UTF8
            Remove-Item -LiteralPath $testFile -Force
            $isWritable = $true
        }
        catch {
            $isWritable = $false
        }
    }

    $cmdlet = Get-DismCmdlet -Name 'Get-WindowsImage'

    if ($cmdlet) {
        $mountedImages = @(& $cmdlet -Mounted -ErrorAction SilentlyContinue)
        $isMounted = (@($mountedImages | Where-Object { $_.Path -eq $MountPath }).Count -gt 0)
    }
    else {
        try {
            $mountedInfo = Invoke-DismExe -Arguments @('/Get-MountedWimInfo')
            $isMounted = (($mountedInfo -join [System.Environment]::NewLine) -match [regex]::Escape($MountPath))
        }
        catch {
            Write-Warning -Message ('Unable to query DISM mount state: {0}' -f $_.Exception.Message) -Component 'Dism'
        }
    }

    $result = [ordered]@{
        MountPath    = $MountPath
        FolderExists = $folderExists
        IsMounted    = $isMounted
        IsWritable   = $isWritable
        Timestamp    = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
    }

    Write-Info -Message ('Mount state: path={0}; folder={1}; mounted={2}; writable={3}.' -f $MountPath, $folderExists, $isMounted, $isWritable) -Component 'Dism'
    return $result
}

function Invoke-OfflineDeployment {
    <#
    .SYNOPSIS
        Runs the complete offline Microsoft Photos deployment workflow.

    .DESCRIPTION
        Runs pre-deployment validation, package preparation, image mount, package servicing,
        image commit or discard, and image dismount. If an error occurs after mounting, the
        function automatically attempts to discard and dismount the image to avoid stale
        mount folders.

    .PARAMETER ReadOnly
        Mounts the image read-only and skips package servicing operations.

    .PARAMETER Discard
        Discards changes during dismount instead of committing them.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]
        $ReadOnly,

        [Parameter()]
        [switch]
        $Discard
    )

    $config = Get-DismDeploymentConfig
    $summary = [ordered]@{
        Passed                = $false
        Validation            = $null
        PackagePreparation    = $null
        MountState            = $null
        AddedPackages         = @()
        Committed             = $false
        Dismounted            = $false
        CleanupAttempted      = $false
        CleanupSucceeded      = $false
        Timestamp             = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
    }
    $imageMounted = $false

    try {
        Write-Header -Message 'Offline Microsoft Photos Deployment' -Component 'Dism'
        $summary['Validation'] = Invoke-PreDeploymentValidation

        if (-not $summary['Validation']['Passed']) {
            Invoke-DismModuleError -Message 'Pre-deployment validation failed.'
        }

        $summary['PackagePreparation'] = Invoke-PackagePreparation

        if (-not $summary['PackagePreparation']['Passed']) {
            Invoke-DismModuleError -Message 'Package preparation failed.'
        }

        $summary['MountState'] = Mount-WindowsImage -ImagePath ([string]$config.Image.ImagePath) -MountPath ([string]$config.Image.MountPath) -Index ([int]$config.Image.Index) -ReadOnly:$ReadOnly
        $imageMounted = [bool]$summary['MountState']['IsMounted']

        if (-not $ReadOnly) {
            $copiedPackagePaths = @($summary['PackagePreparation']['CopiedPackages'])
            $photosPackageNames = @($summary['PackagePreparation']['PhotosPackages'] | ForEach-Object { Split-Path -Path $_ -Leaf })
            $copiedPhotosPackages = @($copiedPackagePaths | Where-Object { $photosPackageNames -contains (Split-Path -Path $_ -Leaf) })
            $dependencyPackagePaths = @($copiedPackagePaths | Where-Object { $photosPackageNames -notcontains (Split-Path -Path $_ -Leaf) })

            foreach ($packagePath in $copiedPhotosPackages) {
                $addPackageParameters = @{
                    MountPath   = [string]$config.Image.MountPath
                    PackagePath = $packagePath
                }

                if ($dependencyPackagePaths.Count -gt 0) {
                    $addPackageParameters['DependencyPackagePath'] = $dependencyPackagePaths
                }

                [void](Add-OfflinePackage @addPackageParameters)
                $summary['AddedPackages'] += $packagePath
            }

            if (-not $Discard -and [bool]$config.Image.CommitOnSuccess) {
                [void](Save-WindowsImage -MountPath ([string]$config.Image.MountPath))
                $summary['Committed'] = $true
            }
        }
        else {
            Write-Warning -Message 'ReadOnly mount requested; package servicing and commit operations were skipped.' -Component 'Dism'
        }

        if ($summary['Committed'] -and -not $Discard) {
            $dismountState = Dismount-WindowsImage -MountPath ([string]$config.Image.MountPath) -Commit
        }
        else {
            $dismountState = Dismount-WindowsImage -MountPath ([string]$config.Image.MountPath) -Discard
        }
        $summary['Dismounted'] = (-not [bool]$dismountState['IsMounted'])
        $summary['Passed'] = $summary['Dismounted']
        Write-Info -Message ('Offline deployment completed. Passed={0}.' -f $summary['Passed']) -Component 'Dism'

        return $summary
    }
    catch {
        Write-Fatal -Message ('Offline deployment failed: {0}' -f $_.Exception.Message) -Component 'Dism'

        if ($imageMounted) {
            $summary['CleanupAttempted'] = $true

            try {
                [void](Dismount-WindowsImage -MountPath ([string]$config.Image.MountPath) -Discard)
                $summary['CleanupSucceeded'] = $true
            }
            catch {
                Write-Fatal -Message ('Automatic mount cleanup failed: {0}' -f $_.Exception.Message) -Component 'Dism'
            }
        }

        return $summary
    }
}

Export-ModuleMember -Function 'Mount-WindowsImage', 'Dismount-WindowsImage', 'Save-WindowsImage', 'Get-WindowsImageInfo', 'Add-OfflinePackage', 'Remove-OfflinePackage', 'Get-OfflinePackage', 'Test-MountState', 'Invoke-OfflineDeployment'
