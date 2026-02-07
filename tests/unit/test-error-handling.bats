#!/usr/bin/env bats
# test-error-handling.bats — Tests for rollback_push, rollback_execute, run_safe, log

setup() {
    load '../helpers/test-helper'
    setup_test_env
    source_deploy_script
    override_run_with_sudo
}

teardown() {
    teardown_test_env
}

# --- rollback_push / rollback_execute ---

@test "rollback_push: adds commands to stack" {
    ROLLBACK_STACK=()
    rollback_push "echo undo1"
    rollback_push "echo undo2"
    [[ ${#ROLLBACK_STACK[@]} -eq 2 ]]
}

@test "rollback_execute: runs commands in LIFO order" {
    ROLLBACK_STACK=()
    local order_file="$TEST_TMPDIR/rollback-order.txt"
    rollback_push "echo first >> $order_file"
    rollback_push "echo second >> $order_file"
    rollback_execute
    # "second" was pushed last, should run first
    local first_line
    first_line=$(head -1 "$order_file")
    [[ "$first_line" == "second" ]]
}

@test "rollback_execute: empties stack after execution" {
    ROLLBACK_STACK=()
    rollback_push "echo test"
    rollback_execute
    [[ ${#ROLLBACK_STACK[@]} -eq 0 ]]
}

@test "rollback_execute: handles empty stack without error" {
    ROLLBACK_STACK=()
    run rollback_execute
    assert_success
}

# --- run_safe ---

@test "run_safe: prints ok on successful command" {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    run run_safe "Test step" "true"
    assert_success
    assert_output --partial "Test step"
}

# --- log ---

@test "log: writes timestamp, level, and message to log file" {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    log "INFO" "Test message here"
    run grep "INFO" "$LOG_FILE"
    assert_success
    assert_output --partial "Test message here"
    # Verify timestamp format [YYYY-MM-DD HH:MM:SS]
    run grep -E '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$LOG_FILE"
    assert_success
}
