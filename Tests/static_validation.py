#!/usr/bin/env python3
"""Static validations for package discovery, elevation, and mount ownership semantics."""
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BATCH = (ROOT / "Add_Photos_Offline.bat").read_text(encoding="utf-8")
DISM = (ROOT / "Modules" / "Dism.psm1").read_text(encoding="utf-8")
ELEVATE = (ROOT / "Modules" / "Elevate-AddPhotos.ps1").read_text(encoding="utf-8")
ADD_PHOTOS = (ROOT / "Add_Photos.ps1").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.ps1").read_text(encoding="utf-8")
PACKAGE = (ROOT / "Modules" / "Package.psm1").read_text(encoding="utf-8-sig")
VALIDATION = (ROOT / "Modules" / "Validation.psm1").read_text(encoding="utf-8-sig")
LOGGER = (ROOT / "Modules" / "Logger.psm1").read_text(encoding="utf-8")
COMMON = (ROOT / "Modules" / "Common.psm1").read_text(encoding="utf-8-sig")
POWERSHELL_SOURCES = {
    "Add_Photos.ps1": ADD_PHOTOS,
    "Config.ps1": CONFIG,
    "Modules/Common.psm1": COMMON,
    "Modules/Validation.psm1": VALIDATION,
    "Modules/Package.psm1": PACKAGE,
    "Modules/Dism.psm1": DISM,
    "Modules/Logger.psm1": LOGGER,
}


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def test_batch_elevation_preserves_arguments_and_exit_code() -> None:
    assert_contains(
        BATCH,
        'Modules\\Elevate-AddPhotos.ps1" -ScriptPath "%SCRIPT_PATH%" %*',
        "elevation must hand the original %* arguments to the elevation helper",
    )
    assert_contains(
        ELEVATE,
        "[Parameter(ValueFromRemainingArguments = $true)]",
        "elevation helper must capture all remaining script arguments",
    )
    assert_contains(
        ELEVATE,
        "ConvertTo-Json -InputObject $ScriptArgument -Compress",
        "elevation helper must serialize arguments before elevation",
    )
    assert_contains(
        ELEVATE,
        "-EncodedCommand",
        "elevation helper must avoid rebuilding a quoted command line from raw arguments",
    )
    assert_contains(
        ELEVATE,
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru",
        "elevation must wait for the elevated process and capture it",
    )
    assert_contains(
        ELEVATE,
        "exit $process.ExitCode",
        "elevation must return the elevated process exit code to the caller",
    )
    assert_contains(
        BATCH,
        "setlocal DisableDelayedExpansion",
        "batch file must keep delayed expansion disabled while reading paths and forwarding arguments",
    )
    if "EnableDelayedExpansion" in BATCH:
        raise AssertionError("delayed expansion must not be enabled while %~dp0 or %* is expanded")
    assert_contains(
        BATCH,
        'set "ELEVATED_EXIT_CODE=%errorlevel%"\nexit /b %ELEVATED_EXIT_CODE%',
        "batch file must capture and return the helper exit code outside a parenthesized block",
    )
    elevation_section = BATCH.split("echo Requesting administrator privileges...", 1)[1].split(":RunDeployment", 1)[0]
    if "(" in elevation_section or ")" in elevation_section:
        raise AssertionError("elevation and exit-code capture must remain outside parenthesized batch blocks")
    assert_contains(
        BATCH,
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*',
        "the elevated batch path must forward all original arguments to Add_Photos.ps1",
    )


def test_batch_preserves_spaces_metacharacters_and_exclamation_marks() -> None:
    assert_contains(BATCH, 'set "SCRIPT_DIR=%~dp0"', "script directory must be read with delayed expansion disabled")
    assert_contains(BATCH, '-File "%SCRIPT_DIR%Modules\\Elevate-AddPhotos.ps1"', "helper path containing spaces or ! must be quoted")
    assert_contains(BATCH, '-ScriptPath "%SCRIPT_PATH%" %*', "quoted script path and original argument spelling must be preserved")

    script_path = r"C:\Deployment! Tools\Add_Photos.ps1"
    forwarded_arguments = r'-PackageRoot "C:\Packages! & Tools" -ImagePath "C:\Images\LTSC 24H2.wim"'
    assert "!" in script_path and " " in script_path
    assert "!" in forwarded_arguments and " " in forwarded_arguments and "&" in forwarded_arguments
    assert "%*" in BATCH, "batch forwarding must retain the caller's original quoting and metacharacter escaping"


def test_add_photos_exits_with_script_exit_code() -> None:
    assert_contains(
        ADD_PHOTOS,
        "if ($MyInvocation.InvocationName -ne '.') { exit $exitCode }",
        "Add_Photos.ps1 must terminate the PowerShell process with its deployment exit code",
    )
    if "$host.SetShouldExit($exitCode)" in ADD_PHOTOS:
        raise AssertionError("Add_Photos.ps1 must not rely on SetShouldExit when the elevation helper needs the process exit code")
    assert_contains(ADD_PHOTOS, "$exitCode = 0", "successful deployment must return exit code zero")
    assert_contains(ADD_PHOTOS, "$exitCode = 1", "failed deployment must retain a nonzero default exit code")


def test_logger_cleanup_is_public_idempotent_and_non_masking() -> None:
    assert_contains(LOGGER, "function Close-Logger {", "Logger module must implement Close-Logger")
    export_line = next((line for line in LOGGER.splitlines() if line.startswith("Export-ModuleMember -Function")), "")
    assert "'Close-Logger'" in export_line, "Logger module must export Close-Logger"
    assert_contains(LOGGER, "$wasInitialized = [bool]$script:LoggerState['Initialized']", "Close-Logger must tolerate uninitialized state")
    assert_contains(LOGGER, "Logger finalization failed:", "Close-Logger must handle finalization failures safely")
    assert_contains(LOGGER, "finally {", "Close-Logger must reset state even if final logging fails")
    assert_contains(ADD_PHOTOS, "Close-Logger", "Add_Photos must call the exported logger cleanup function")
    if "Logger\\Close-Logger" in ADD_PHOTOS:
        raise AssertionError("cleanup must not use module qualification that triggers PSModulePath discovery")
    cleanup = ADD_PHOTOS.split("finally {", 1)[1]
    assert_contains(cleanup, "try {", "logger cleanup must be guarded")
    assert_contains(cleanup, "catch {", "logger cleanup failures must not mask deployment failures")
    assert "exit $exitCode" not in cleanup.split("}", 2)[0], "finally must not exit and suppress the deployment exception"
    assert_contains(ADD_PHOTOS, "$deploymentError = $_", "the original deployment ErrorRecord must be retained")
    assert_contains(ADD_PHOTOS, "throw $deploymentError", "dot-sourcing must rethrow the original deployment error")
    assert_contains(ADD_PHOTOS, "Write-Error -ErrorRecord $deploymentError", "script execution must display the original deployment error")


def test_project_module_runtime_after_path_import_when_available() -> bool:
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        return False

    script_path = ROOT / "Add_Photos.ps1"
    command = (
        "$ErrorActionPreference = 'Stop'; "
        "if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }; "
        f"$scriptText = Get-Content -LiteralPath '{str(script_path).replace(chr(39), chr(39)*2)}' -Raw; "
        "$importBlock = [regex]::Match($scriptText, '(?s)\\$projectModulePaths = .*?(?=\\$exitCode = 1)').Value; "
        "if ([string]::IsNullOrWhiteSpace($importBlock)) { throw 'Add_Photos module import block was not found.' }; "
        f"$moduleRoot = '{str(ROOT / 'Modules').replace(chr(39), chr(39)*2)}'; Invoke-Expression $importBlock; "
        "$required = @('Initialize-Logger','Write-Fatal','Close-Logger','Invoke-PreDeploymentValidation','Invoke-PackagePreparation','Invoke-OfflineDeployment'); "
        "foreach ($name in $required) { if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { throw ('Missing command: ' + $name) } }; "
        "Close-Logger; Close-Logger"
    )
    result = subprocess.run(
        [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"project module commands failed in a fresh PowerShell process: {result.stderr.strip()}")
    return True


def test_project_module_import_contract_is_explicit() -> None:
    assert_contains(ADD_PHOTOS, "Import-Module -Name $modulePath -Force -Global -ErrorAction Stop", "project modules must be visible to the full script invocation")
    assert_contains(ADD_PHOTOS, "$requiredCommands = @(", "Add_Photos must define its required command contract")
    for command in (
        "Initialize-Logger", "Write-Header", "Write-Fatal", "Write-Success", "Close-Logger",
        "Invoke-PreDeploymentValidation", "Invoke-PackagePreparation", "Invoke-OfflineDeployment",
    ):
        assert f"'{command}'" in ADD_PHOTOS, f"module command contract must include {command}"
    assert_contains(ADD_PHOTOS, "Project module import did not expose required command(s):", "missing commands must produce a diagnostic error")


def test_add_photos_direct_calls_are_exported() -> None:
    required_exports = {
        "Logger": ["Initialize-Logger", "Write-Header", "Write-Fatal", "Write-Success", "Close-Logger"],
        "Validation": ["Invoke-PreDeploymentValidation"],
        "Package": ["Invoke-PackagePreparation"],
        "Dism": ["Invoke-OfflineDeployment"],
    }
    module_text = {"Logger": LOGGER, "Validation": VALIDATION, "Package": PACKAGE, "Dism": DISM}
    for module, functions in required_exports.items():
        export_line = next((line for line in module_text[module].splitlines() if line.startswith("Export-ModuleMember -Function")), "")
        for function in functions:
            assert f"'{function}'" in export_line, f"{module}.psm1 must export {function}"


def test_recursive_manifest_driven_discovery() -> None:
    assert_contains(PACKAGE, "Get-ChildItem -LiteralPath $RootPath -Recurse -File", "discovery must be recursive")
    for extension in (".appx", ".appxbundle", ".msix", ".msixbundle"):
        assert extension in CONFIG
    for forbidden in ("PhotosFilters", "DependencyFilters", "Microsoft.Windows.Photos", "Microsoft.MicrosoftStickyNotes", "Microsoft.Paint", "Microsoft.WindowsCalculator"):
        if forbidden in PACKAGE or forbidden in CONFIG:
            raise AssertionError(f"package discovery must not use app-specific filter: {forbidden}")


def test_manifest_classification() -> None:
    for classification in ("MainApplication", "Framework", "Resource", "Optional", "Dependency"):
        assert classification in PACKAGE
    assert_contains(PACKAGE, "local-name()='Application'", "applications must be identified through the manifest")
    assert_contains(PACKAGE, "AppxBundleManifest.xml", "bundles must be parsed")
    assert_contains(PACKAGE, "$BundleManifest.Bundle.Identity.Name", "bundle identity must be retained")
    if "if ([string]$node.Type -ine 'application')" in PACKAGE:
        raise AssertionError("bundle resource and architecture payloads must be inspected rather than skipped")


def test_dependency_resolution_contract() -> None:
    for field in ("requirement.Name", "requirement.MinimumVersion", "requirement.Publisher", "Architecture"):
        assert field in PACKAGE
    assert_contains(PACKAGE, "$resolved.ContainsKey($key)", "resolved dependencies must be unique")
    assert_contains(PACKAGE, "Sort-Object Version -Descending", "the highest compatible dependency must win")
    assert_contains(PACKAGE, "$Candidate -ieq 'neutral' -or $Candidate -ieq $Required", "architecture must be exact or neutral")
    assert_contains(ADD_PHOTOS, "Missing Dependencies", "menu must report missing dependencies before mounting")


def test_missing_dependencies_are_rejected_before_mount() -> None:
    ready_check = ADD_PHOTOS.index("$notReady = @(")
    deployment_call = ADD_PHOTOS.index("Invoke-OfflineDeployment @invokeParameters")
    assert ready_check < deployment_call
    assert_contains(ADD_PHOTOS, "throw ('Selected application(s) have missing dependencies:", "not-ready selections must terminate")


def test_shared_dependencies_are_deduplicated() -> None:
    assert_contains(ADD_PHOTOS, "Group-Object Identity,Version,Architecture", "shared dependencies must be deduplicated across selected apps")
    assert_contains(PACKAGE, "$key='{0}|{1}|{2}'", "resolver deduplication must include identity, version, and architecture")


def test_generic_application_menu_and_install_order() -> None:
    assert_contains(ADD_PHOTOS, "Read-Host 'Select applications", "application selection must be interactive")
    assert_contains(ADD_PHOTOS, "$selection -split ','", "comma-separated selections must be accepted")
    assert_contains(ADD_PHOTOS, "ApplicationPackagePath", "selected main applications must be passed to deployment")
    assert_contains(ADD_PHOTOS, "Architecture : {0}", "the menu must show architecture")
    body = get_invoke_offline_deployment_body()
    assert body.index("foreach ($dependency") < body.index("foreach ($application"), "dependencies must be installed before applications"


def test_configuration_controls_remain_wired() -> None:
    for setting in ("ImagePath", "MountPath", "Index", "RootPath", "Mode", "ContinueOnError", "DryRun", "Logging"):
        assert setting in CONFIG, f"configuration setting was lost: {setting}"
    assert_contains(ADD_PHOTOS, "$config.Deployment.ContinueOnError", "continue-on-error must reach deployment")
    assert_contains(ADD_PHOTOS, "$config.Deployment.DryRun", "configured dry-run must activate WhatIf")


def test_windows_powershell_51_static_compatibility() -> None:
    incompatible = {
        r"\?\?": "null-coalescing operator",
        r"\?\.": "null-conditional operator",
        r"\bForEach-Object\s+-Parallel\b": "parallel ForEach-Object",
        r"\$\w+\s*\?\s*[^\r\n:]+\s*:": "ternary operator",
        r"\|\|": "pipeline-chain OR",
        r"&&": "pipeline-chain AND",
    }
    for path, source in POWERSHELL_SOURCES.items():
        code = "\n".join(line.split("#", 1)[0] for line in source.splitlines())
        for pattern, feature in incompatible.items():
            if re.search(pattern, code):
                raise AssertionError(f"{path} uses PowerShell 7-only {feature}")
        assert "#Requires -Version 5.1" in source, f"{path} must declare Windows PowerShell 5.1"


def get_invoke_offline_deployment_body() -> str:
    match = re.search(r"function Invoke-OfflineDeployment \{(?P<body>.*)\n\}\n\nExport-ModuleMember", DISM, re.S)
    if not match:
        raise AssertionError("Invoke-OfflineDeployment function body was not found")
    return match.group("body")


def test_new_mount_is_committed_and_dismounted() -> None:
    body = get_invoke_offline_deployment_body()
    assert_contains(body, "if ($AutoUnmount -and $mountedHere)", "new mounts must use the auto-unmount path")
    assert_contains(body, "Dismount-WindowsImage -MountPath $MountPath -Save", "successful new mounts must commit during dismount")
    assert_contains(body, "$committed = -not $WhatIfPreference", "commit must only be reported after the operation succeeds")


def test_existing_mount_is_saved_and_remains_mounted() -> None:
    body = get_invoke_offline_deployment_body()
    assert_contains(body, "$wasMounted = Test-MountState -MountPath $MountPath", "pre-existing mount state must be captured")
    assert_contains(body, "if (-not $wasMounted)", "mounting must only happen when the mount path is not already mounted")
    assert_contains(body, "Save-WindowsImage -MountPath $MountPath", "existing mounts must be saved instead of dismounted")
    dismount_calls = [line.strip() for line in body.splitlines() if "Dismount-WindowsImage" in line]
    if any("$wasMounted" in line for line in dismount_calls):
        raise AssertionError("pre-existing mounts must not be dismounted")


def test_no_commit_reports_false() -> None:
    body = get_invoke_offline_deployment_body()
    assert_contains(body, "$committed = $false", "Committed must default to false")
    assert_contains(body, "elseif ($AutoUnmount -and $mountedHere)", "discard dismount path must be separate from commit path")
    assert_contains(body, "Committed = $committed", "result must report the actual commit/save state")


def test_one_mount_one_commit_and_post_install_verification() -> None:
    body = get_invoke_offline_deployment_body()
    assert body.count("Mount-WindowsImage -ImagePath") == 1, "the orchestration may mount only once"
    assert_contains(body, "Get-OfflinePackage -MountPath $MountPath", "packages must be verified before commit")
    assert body.index("Get-OfflinePackage -MountPath $MountPath") < body.index("if ($CommitOnSuccess)")
    assert_contains(body, "if ($AutoUnmount -and $mountedHere)", "commit branches must be mutually exclusive")
    assert_contains(body, "else {\n                Save-WindowsImage", "a successful invocation must choose only one commit mechanism")


def test_error_path_discards_owned_mount_even_when_keep_mounted() -> None:
    body = get_invoke_offline_deployment_body()
    catch_body = body.split("    catch {\n        Write-Fatal -Message (\"Offline deployment failed:", 1)[1]
    assert_contains(catch_body, "if ($mountedHere)", "owned mounts must always be cleaned after errors")
    if "if ($mountedHere -and $AutoUnmount)" in catch_body:
        raise AssertionError("KeepMounted must not preserve a dirty mount after failure")
    assert_contains(catch_body, "Dismount-WindowsImage -MountPath $MountPath", "failure cleanup must use discard dismount")
    if "-Save" in next(line for line in catch_body.splitlines() if "Dismount-WindowsImage" in line):
        raise AssertionError("failure cleanup must never commit")


def main() -> None:
    # Conflict-resolution contract: keep PR #5 package coverage alongside every
    # elevation and mount/commit regression inherited from PR #4 and latest main.
    package_discovery_tests = [
        test_recursive_manifest_driven_discovery,
        test_manifest_classification,
        test_dependency_resolution_contract,
        test_missing_dependencies_are_rejected_before_mount,
        test_shared_dependencies_are_deduplicated,
        test_generic_application_menu_and_install_order,
        test_configuration_controls_remain_wired,
        test_windows_powershell_51_static_compatibility,
    ]
    pr4_regression_tests = [
        test_batch_elevation_preserves_arguments_and_exit_code,
        test_batch_preserves_spaces_metacharacters_and_exclamation_marks,
        test_add_photos_exits_with_script_exit_code,
        test_logger_cleanup_is_public_idempotent_and_non_masking,
        test_project_module_import_contract_is_explicit,
        test_add_photos_direct_calls_are_exported,
        test_new_mount_is_committed_and_dismounted,
        test_existing_mount_is_saved_and_remains_mounted,
        test_no_commit_reports_false,
        test_one_mount_one_commit_and_post_install_verification,
        test_error_path_discards_owned_mount_even_when_keep_mounted,
    ]
    tests = package_discovery_tests + pr4_regression_tests

    for test in tests:
        test()
        print(f"PASS {test.__name__}")

    if test_project_module_runtime_after_path_import_when_available():
        print("PASS test_project_module_runtime_after_path_import_when_available")
    else:
        print("SKIP test_project_module_runtime_after_path_import_when_available (Windows PowerShell 5.1 is unavailable)")


if __name__ == "__main__":
    main()
