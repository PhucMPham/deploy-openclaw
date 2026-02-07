#!/usr/bin/env bats
# test-phase1-system-check.bats — Integration tests for phase_system_check

setup() {
    load '../helpers/test-helper'
    setup_test_env
    source_deploy_script
    override_run_with_sudo

    # Ensure state file exists
    touch "$STATE_FILE"
}

teardown() {
    teardown_test_env
}

@test "phase_system_check: all pass saves state as done" {
    # We're root on Ubuntu 22.04 in Docker — real detect_os should work
    # Mock check_internet since we may not have network in Docker build
    check_internet() { print_status ok "Internet connectivity OK"; return 0; }
    # Mock check_existing_software to avoid side effects
    check_existing_software() { return 0; }

    run phase_system_check
    assert_success

    run state_get "phase_system_check"
    assert_output "done"
}

@test "phase_system_check: fails on unsupported OS" {
    # Override detect_os to simulate unsupported OS
    detect_os() {
        print_status fail "Ubuntu 18.04 detected. Minimum: 22.04"
        return 1
    }

    run phase_system_check
    assert_failure
}

@test "phase_system_check: fails when no internet" {
    # Override check_internet to fail
    check_internet() {
        print_status fail "Cannot reach openclaw.bot"
        return 1
    }

    run phase_system_check
    assert_failure
}

@test "phase_system_check: fails on low disk space" {
    # Override check_disk_space to fail
    check_disk_space() {
        print_status fail "Disk space: 500MB available (need 2048MB)"
        return 1
    }
    # check_internet must pass first
    check_internet() { print_status ok "Internet OK"; return 0; }

    run phase_system_check
    assert_failure
}
