#!/usr/bin/env bats
# test-state-persistence.bats — Tests for state_save, state_load, state_get, state_init

setup() {
    load '../helpers/test-helper'
    setup_test_env
    source_deploy_script
    override_run_with_sudo
}

teardown() {
    teardown_test_env
}

# --- state_save ---

@test "state_save: writes valid key=value to state file" {
    touch "$STATE_FILE"
    state_save "my_key" "my_value"
    run grep '^my_key=' "$STATE_FILE"
    assert_success
    assert_output 'my_key="my_value"'
}

@test "state_save: rejects invalid key with hyphen" {
    touch "$STATE_FILE"
    run state_save "bad-key" "value"
    assert_failure
}

@test "state_save: rejects key starting with number" {
    touch "$STATE_FILE"
    run state_save "123key" "value"
    assert_failure
}

@test "state_save: rejects key with spaces" {
    touch "$STATE_FILE"
    run state_save "key with spaces" "value"
    assert_failure
}

@test "state_save: sanitizes dangerous characters from value" {
    touch "$STATE_FILE"
    state_save "test_key" '$(rm -rf /)'
    local stored
    stored=$(grep '^test_key=' "$STATE_FILE" | cut -d'"' -f2)
    # Should NOT contain $, (, ), or spaces
    [[ "$stored" != *'$'* ]]
    [[ "$stored" != *'('* ]]
    [[ "$stored" != *')'* ]]
}

@test "state_save: overwrites existing key without duplicates" {
    touch "$STATE_FILE"
    state_save "phase_one" "partial"
    state_save "phase_one" "done"
    local count
    count=$(grep -c '^phase_one=' "$STATE_FILE")
    [[ "$count" -eq 1 ]]
    run grep '^phase_one=' "$STATE_FILE"
    assert_output 'phase_one="done"'
}

# --- state_load ---

@test "state_load: populates shell variables from state file" {
    cat > "$STATE_FILE" << 'EOF'
phase_check="done"
deploy_user="openclaw"
EOF
    state_load
    [[ "$phase_check" == "done" ]]
    [[ "$deploy_user" == "openclaw" ]]
}

@test "state_load: does not execute code injection in values" {
    local pwned_file="$TEST_TMPDIR/pwned"
    cat > "$STATE_FILE" << EOF
evil_key="touch ${pwned_file}"
EOF
    state_load
    assert_file_not_exist "$pwned_file"
}

@test "state_load: skips comment lines" {
    cat > "$STATE_FILE" << 'EOF'
# This is a comment
valid_key="hello"
EOF
    state_load
    [[ "$valid_key" == "hello" ]]
}

@test "state_load: skips keys with invalid characters" {
    cat > "$STATE_FILE" << 'EOF'
valid_key="good"
bad-key="should_skip"
also bad="should_skip"
EOF
    state_load
    [[ "$valid_key" == "good" ]]
}

@test "state_load: handles empty file without error" {
    touch "$STATE_FILE"
    run state_load
    assert_success
}

# --- state_get ---

@test "state_get: retrieves correct value for existing key" {
    cat > "$STATE_FILE" << 'EOF'
phase_system_check="done"
phase_user_setup="partial"
EOF
    run state_get "phase_system_check"
    assert_success
    assert_output "done"
}

@test "state_get: returns empty for missing key" {
    touch "$STATE_FILE"
    run state_get "nonexistent_key"
    assert_success
    assert_output ""
}
