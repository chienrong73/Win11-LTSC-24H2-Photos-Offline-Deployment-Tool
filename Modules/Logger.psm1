<#
.SYNOPSIS
    Provides enterprise logging services for Microsoft Photos offline deployment.

.DESCRIPTION
    Implements console and file logging for the Windows 11 LTSC 24H2 Microsoft Photos
    offline deployment tool. The module supports configurable log levels, timestamped
    entries, directory creation for file logging, and PowerShell 5.1-compatible output.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    Module: Logger
    File: Modules/Logger.psm1
    Encoding: UTF-8
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleMetadata = [ordered]@{
    Name        = 'Logger'
    Version     = '1.0.0'
    Description = 'Enterprise logging services for Microsoft Photos offline deployment.'
    Project     = 'Win11-LTSC-24H2-Photos-Offline-Deployment-Tool'
    Encoding    = 'UTF-8'
}

$script:LoggerState = [ordered]@{
    Initialized   = $false
    EnableConsole = $true
    EnableFile    = $false
    LogFolder     = $null
    LogFileName   = 'PhotosDeployment.log'
    LogFilePath   = $null
    LogLevel      = 'Information'
}

$script:LogLevelMap = [ordered]@{
    Debug       = 10
    Information = 20
    Warning     = 30
    Error       = 40
}

$script:LoggerStartTime = Get-Date

function Initialize-Logger {
    <#
    .SYNOPSIS
        Initializes logging for the Photos offline deployment workflow.

    .DESCRIPTION
        Configures console and file logging preferences. When file logging is enabled,
        the log folder is created if it does not already exist.

    .PARAMETER EnableConsole
        Enables log messages to be written to the PowerShell host.

    .PARAMETER EnableFile
        Enables log messages to be written to a UTF-8 log file.

    .PARAMETER LogFolder
        Directory path where the log file is written when file logging is enabled.

    .PARAMETER LogFileName
        Name of the log file when file logging is enabled.

    .PARAMETER LogLevel
        Minimum log level to emit. Supported values are Debug, Information, Warning, and Error.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [bool]
        $EnableConsole = $true,

        [Parameter()]
        [bool]
        $EnableFile = $false,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $LogFolder = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Logs'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $LogFileName = 'PhotosDeployment.log',

        [Parameter()]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]
        $LogLevel = 'Information'
    )

    $resolvedLogFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFolder)
    $logFilePath = Join-Path -Path $resolvedLogFolder -ChildPath $LogFileName

    if ($EnableFile -and -not (Test-Path -LiteralPath $resolvedLogFolder -PathType Container)) {
        New-Item -Path $resolvedLogFolder -ItemType Directory -Force | Out-Null
    }

    $script:LoggerState['Initialized'] = $true
    $script:LoggerState['EnableConsole'] = $EnableConsole
    $script:LoggerState['EnableFile'] = $EnableFile
    $script:LoggerState['LogFolder'] = $resolvedLogFolder
    $script:LoggerState['LogFileName'] = $LogFileName
    $script:LoggerState['LogFilePath'] = $logFilePath
    $script:LoggerState['LogLevel'] = $LogLevel

    return $script:LoggerState
}

function Get-LoggerState {
    <#
    .SYNOPSIS
        Returns the current logger state.

    .DESCRIPTION
        Provides the effective logger configuration for callers that need to inspect
        current logging behavior.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    return $script:LoggerState
}

function Test-LogLevelEnabled {
    <#
    .SYNOPSIS
        Determines whether a log level should be emitted.

    .DESCRIPTION
        Compares a candidate log level with the configured minimum log level.

    .PARAMETER Level
        Candidate log level to evaluate.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]
        $Level
    )

    return ($script:LogLevelMap[$Level] -ge $script:LogLevelMap[$script:LoggerState['LogLevel']])
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped deployment log entry.

    .DESCRIPTION
        Writes a structured log entry to the configured console and file targets when the
        entry level is greater than or equal to the configured minimum log level.

    .PARAMETER Message
        Message text to write to the log.

    .PARAMETER Level
        Log severity level. Supported values are Debug, Information, Warning, and Error.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]
        $Level = 'Information',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    if (-not $script:LoggerState['Initialized']) {
        Initialize-Logger | Out-Null
    }

    if (-not (Test-LogLevelEnabled -Level $Level)) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff K'
    $entry = '[{0}] [{1}] [{2}] {3}' -f $timestamp, $Level.ToUpperInvariant(), $Component, $Message

    if ($script:LoggerState['EnableConsole']) {
        switch ($Level) {
            'Debug' { Write-Verbose -Message $entry }
            'Information' { Write-Host $entry }
            'Warning' { Write-Warning -Message $entry }
            'Error' { Write-Error -Message $entry -ErrorAction Continue }
        }
    }

    if ($script:LoggerState['EnableFile']) {
        Add-Content -LiteralPath $script:LoggerState['LogFilePath'] -Value $entry -Encoding UTF8
    }
}



function Get-LoggerDeploymentConfig {
    <#
    .SYNOPSIS
        Gets deployment configuration for logger formatting decisions.

    .DESCRIPTION
        Loads Config.ps1 when needed and returns the global deployment configuration if it
        is available. This private helper keeps public logger functions aligned with the
        central project configuration without changing the logger state schema.

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

function Write-Info {
    <#
    .SYNOPSIS
        Writes an informational deployment log entry.

    .DESCRIPTION
        Writes an informational message through the central Write-Log function using the
        Information log level.

    .PARAMETER Message
        Informational message text to write.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    Write-Log -Message $Message -Level 'Information' -Component $Component
}

function Write-Success {
    <#
    .SYNOPSIS
        Writes a successful operation deployment log entry.

    .DESCRIPTION
        Writes a success message through the central Write-Log function using the
        Information log level and a success-oriented message prefix.

    .PARAMETER Message
        Success message text to write.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    Write-Log -Message ('SUCCESS: {0}' -f $Message) -Level 'Information' -Component $Component
}

function Write-Warning {
    <#
    .SYNOPSIS
        Writes a warning deployment log entry.

    .DESCRIPTION
        Writes a warning message through the central Write-Log function. When invoked by
        Write-Log for console output, the function delegates to the built-in warning cmdlet
        to avoid recursive logging.

    .PARAMETER Message
        Warning message text to write.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    if ((Get-PSCallStack | Select-Object -Skip 1 -First 1).Command -eq 'Write-Log') {
        Microsoft.PowerShell.Utility\Write-Warning -Message $Message
        return
    }

    Write-Log -Message $Message -Level 'Warning' -Component $Component
}

function Write-Error {
    <#
    .SYNOPSIS
        Writes an error deployment log entry.

    .DESCRIPTION
        Writes an error message through the central Write-Log function. When invoked by
        Write-Log for console output, the function delegates to the built-in error cmdlet
        to avoid recursive logging.

    .PARAMETER Message
        Error message text to write.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    if ((Get-PSCallStack | Select-Object -Skip 1 -First 1).Command -eq 'Write-Log') {
        Microsoft.PowerShell.Utility\Write-Error -Message $Message -ErrorAction Continue
        return
    }

    Write-Log -Message $Message -Level 'Error' -Component $Component
}

function Write-Debug {
    <#
    .SYNOPSIS
        Writes a debug deployment log entry.

    .DESCRIPTION
        Writes a debug message through the central Write-Log function using the Debug log
        level.

    .PARAMETER Message
        Debug message text to write.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    Write-Log -Message $Message -Level 'Debug' -Component $Component
}


function Write-Fatal {
    <#
    .SYNOPSIS
        Writes a fatal deployment log entry.

    .DESCRIPTION
        Writes a fatal error message through the central Write-Log function using the Error
        log level. The function does not terminate execution by itself so callers can decide
        whether to throw, exit, or continue according to deployment policy.

    .PARAMETER Message
        Fatal error message text to write.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    Write-Log -Message ('FATAL: {0}' -f $Message) -Level 'Error' -Component $Component
}

function Write-Step {
    <#
    .SYNOPSIS
        Writes a deployment step log entry.

    .DESCRIPTION
        Writes a numbered, named, or progress-style deployment step through the central
        Write-Log function using the Information log level. When Current and Total are
        provided, the emitted message uses the format [Current/Total] Message.

    .PARAMETER Message
        Step description to write.

    .PARAMETER StepNumber
        Optional legacy step number to include in the log message.

    .PARAMETER Current
        Current step number for progress-style step output.

    .PARAMETER Total
        Total number of steps for progress-style step output.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]
        $StepNumber,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]
        $Current,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]
        $Total,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    if ($PSBoundParameters.ContainsKey('Current') -xor $PSBoundParameters.ContainsKey('Total')) {
        throw 'Write-Step requires both Current and Total when using progress-style step output.'
    }

    if ($PSBoundParameters.ContainsKey('Current')) {
        if ($Current -gt $Total) {
            throw 'Write-Step requires Current to be less than or equal to Total.'
        }

        Write-Log -Message ('[{0}/{1}] {2}' -f $Current, $Total, $Message) -Level 'Information' -Component $Component
        return
    }

    if ($PSBoundParameters.ContainsKey('StepNumber')) {
        Write-Log -Message ('STEP {0}: {1}' -f $StepNumber, $Message) -Level 'Information' -Component $Component
        return
    }

    Write-Log -Message ('STEP: {0}' -f $Message) -Level 'Information' -Component $Component
}

function Write-Header {
    <#
    .SYNOPSIS
        Writes a formatted deployment log header.

    .DESCRIPTION
        Writes a visually distinct header through the central Write-Log function using the
        Information log level. When Message is not supplied, the header text is built from
        Config.ps1 Project.Name and Project.Version values.

    .PARAMETER Message
        Optional header text to write. If omitted, project name and version are read from
        Config.ps1.

    .PARAMETER Component
        Logical component name associated with the log entry.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Component = 'Deployment'
    )

    if (-not $PSBoundParameters.ContainsKey('Message')) {
        $config = Get-LoggerDeploymentConfig
        $projectName = $config.Project.Name
        $projectVersion = $config.Project.Version
        $Message = '{0} v{1}' -f $projectName, $projectVersion
    }

    Write-Log -Message ('========== {0} ==========' -f $Message) -Level 'Information' -Component $Component
}

function Close-Logger {
    <#
    .SYNOPSIS
        Closes the current logger session.

    .DESCRIPTION
        Finalizes an initialized logger and resets its state without changing the logger state
        schema. The operation is safe before initialization, after partial initialization, and
        when called repeatedly. If Config.ps1 enables Performance.EnableStopwatch, the function
        also writes the total elapsed runtime.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()

    $wasInitialized = [bool]$script:LoggerState['Initialized']

    try {
        if ($wasInitialized) {
            $enableStopwatch = $false
            try {
                $config = Get-LoggerDeploymentConfig
                $enableStopwatch = [bool]$config.Performance.EnableStopwatch
            }
            catch {
                # Logger shutdown must not depend on configuration being available.
                $enableStopwatch = $false
            }

            if ($enableStopwatch) {
                $elapsed = (Get-Date) - $script:LoggerStartTime
                Write-Log -Message ('Total runtime: {0:hh\:mm\:ss\.fff}' -f $elapsed) -Level 'Information' -Component 'Logger'
            }

            Write-Log -Message 'Logger session closed.' -Level 'Information' -Component 'Logger'
        }
    }
    catch {
        Microsoft.PowerShell.Utility\Write-Warning -Message ('Logger finalization failed: {0}' -f $_.Exception.Message)
    }
    finally {
        $script:LoggerState['Initialized'] = $false
        $script:LoggerState['EnableFile'] = $false
        $script:LoggerState['LogFolder'] = $null
        $script:LoggerState['LogFilePath'] = $null
    }
}

Export-ModuleMember -Function 'Initialize-Logger', 'Get-LoggerState', 'Test-LogLevelEnabled', 'Write-Log', 'Write-Info', 'Write-Success', 'Write-Warning', 'Write-Error', 'Write-Debug', 'Write-Fatal', 'Write-Step', 'Write-Header', 'Close-Logger'
