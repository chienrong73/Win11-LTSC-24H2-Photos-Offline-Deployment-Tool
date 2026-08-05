#!/usr/bin/env python3
"""Static validations for elevation and offline deployment ownership semantics."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BATCH = (ROOT / "Add_Photos_Offline.bat").read_text(encoding="utf-8")
DISM = (ROOT / "Modules" / "Dism.psm1").read_text(encoding="utf-8")
ELEVATE = (ROOT / "Modules" / "Elevate-AddPhotos.ps1").read_text(encoding="utf-8")


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
        "setlocal EnableDelayedExpansion",
        "batch file must enable delayed expansion for exit code reads inside the elevation block",
    )
    assert_contains(
        BATCH,
        "exit /b !ELEVATED_EXIT_CODE!",
        "batch file must return the actual elevated helper exit code, not stale %errorlevel%",
    )
    assert_contains(
        BATCH,
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*',
        "the elevated batch path must forward all original arguments to Add_Photos.ps1",
    )


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


def main() -> None:
    tests = [
        test_batch_elevation_preserves_arguments_and_exit_code,
        test_new_mount_is_committed_and_dismounted,
        test_existing_mount_is_saved_and_remains_mounted,
        test_no_commit_reports_false,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")


if __name__ == "__main__":
    main()
