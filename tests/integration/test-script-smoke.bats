#!/usr/bin/env bats
# test-script-smoke.bats — Smoke tests: syntax check, shellcheck, source guard, state file perms

setup() {
    load '../helpers/test-helper'
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "smoke: bash -n syntax check passes" {
    run bash -n "$DEPLOY_SCRIPT"
    assert_success
}

@test "smoke: shellcheck passes with allowed exceptions" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
    run shellcheck --severity=error "$DEPLOY_SCRIPT"
    assert_success
}

@test "smoke: source guard prevents main from running" {
    # Sourcing with DEPLOY_TESTING=1 in a subshell should NOT trigger main()
    # If main() ran, it would call ensure_not_piped and fail or hang
    # We test by checking that sourcing completes and we can call a function
    run bash -c '
        export DEPLOY_TESTING=1
        OPENCLAW_HOME="/tmp/test-smoke-$$"
        STATE_FILE="$OPENCLAW_HOME/.deploy-state"
        LOG_FILE="$OPENCLAW_HOME/deploy.log"
        MIN_DISK_MB=2048
        mkdir -p "$OPENCLAW_HOME"
        # Source with readonly vars already set — the script readonly will fail silently
        # The key test: source guard line prevents main from executing
        source "'"$DEPLOY_SCRIPT"'" 2>/dev/null || true
        # If we get here, main did not run (it would have called ensure_not_piped and hung/exited)
        echo "SOURCE_OK"
        rm -rf "$OPENCLAW_HOME"
    '
    assert_success
    assert_output --partial "SOURCE_OK"
}

@test "smoke: pipe mode does not trigger unbound BASH_SOURCE error" {
    # Simulates `curl ... | bash` where BASH_SOURCE is empty
    # The source guard must handle empty BASH_SOURCE under set -u
    run bash -c 'cat "'"$DEPLOY_SCRIPT"'" | bash -s -- --help 2>&1; echo "EXIT_CODE=$?"'
    # Should not contain "unbound variable" error
    refute_output --partial "unbound variable"
}

@test "smoke: state file gets chmod 600 when created" {
    source_deploy_script
    override_run_with_sudo

    mkdir -p "$OPENCLAW_HOME"
    state_init

    if [[ -f "$STATE_FILE" ]]; then
        local perms
        perms=$(stat -c '%a' "$STATE_FILE" 2>/dev/null || stat -f '%Lp' "$STATE_FILE" 2>/dev/null)
        [[ "$perms" == "600" ]]
    fi
}
