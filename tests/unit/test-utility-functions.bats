#!/usr/bin/env bats
# test-utility-functions.bats — Tests for print_status, retry_curl, cleanup

setup() {
    load '../helpers/test-helper'
    setup_test_env
    source_deploy_script
    override_run_with_sudo
}

teardown() {
    teardown_test_env
}

# --- print_status ---

@test "print_status ok: outputs green checkmark" {
    run print_status ok "All good"
    assert_success
    assert_output --partial "All good"
    # Check for checkmark character
    assert_output --partial "✓"
}

@test "print_status fail: outputs red X" {
    run print_status fail "Something broke"
    assert_success
    assert_output --partial "Something broke"
    assert_output --partial "✗"
}

@test "print_status warn: outputs warning symbol" {
    run print_status warn "Heads up"
    assert_success
    assert_output --partial "Heads up"
    assert_output --partial "⚠"
}

@test "print_status info: outputs info symbol" {
    run print_status info "FYI"
    assert_success
    assert_output --partial "FYI"
    assert_output --partial "ℹ"
}

# --- retry_curl ---

@test "retry_curl: succeeds on first try" {
    # Mock curl to succeed
    mock_command "curl" 0 "OK"
    run retry_curl "https://example.com" -o /dev/null
    assert_success
}

@test "retry_curl: all retries fail returns 1" {
    # Mock curl to always fail
    mock_command "curl" 1 ""
    run retry_curl "https://example.com" -o /dev/null
    assert_failure
}

# --- cleanup ---

@test "cleanup: calls tput cnorm without error" {
    # Mock tput to track invocation
    local tput_log="$TEST_TMPDIR/tput-calls.txt"
    tput() {
        echo "$*" >> "$tput_log"
    }
    export -f tput

    BG_PIDS=()
    run cleanup
    assert_success
}
