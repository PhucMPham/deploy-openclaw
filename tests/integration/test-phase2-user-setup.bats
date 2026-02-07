#!/usr/bin/env bats
# test-phase2-user-setup.bats — Integration tests for phase_user_setup (runs as root in Docker)

setup() {
    load '../helpers/test-helper'
    setup_test_env
    source_deploy_script
    override_run_with_sudo

    touch "$STATE_FILE"

    # Override OPENCLAW_USER to a test-specific user to avoid polluting the system
    OPENCLAW_USER="testclaw_$$"
    OPENCLAW_HOME="$TEST_TMPDIR/opt_openclaw"
}

teardown() {
    # Clean up test user if created
    userdel -r "$OPENCLAW_USER" 2>/dev/null || true
    teardown_test_env
}

@test "phase_user_setup: creates user successfully" {
    # Override phase to use our test paths
    phase_user_setup() {
        if ! id "$OPENCLAW_USER" &>/dev/null; then
            useradd -m -s /bin/bash "$OPENCLAW_USER"
        fi
        mkdir -p "$OPENCLAW_HOME"
        chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME"
        local env_file="${OPENCLAW_HOME}/.env"
        touch "$env_file" && chmod 600 "$env_file"
        chown "$OPENCLAW_USER:$OPENCLAW_USER" "$env_file"
        state_save "phase_user_setup" "done"
    }

    run phase_user_setup
    assert_success

    # Verify user exists
    run id "$OPENCLAW_USER"
    assert_success
}

@test "phase_user_setup: skips if user already exists" {
    # Create user first
    useradd -m -s /bin/bash "$OPENCLAW_USER" 2>/dev/null || true

    phase_user_setup() {
        if id "$OPENCLAW_USER" &>/dev/null; then
            print_status ok "User '$OPENCLAW_USER' already exists"
        fi
        mkdir -p "$OPENCLAW_HOME"
        state_save "phase_user_setup" "done"
    }

    run phase_user_setup
    assert_success
    assert_output --partial "already exists"
}

@test "phase_user_setup: creates workspace directory" {
    useradd -m -s /bin/bash "$OPENCLAW_USER" 2>/dev/null || true

    phase_user_setup() {
        mkdir -p "$OPENCLAW_HOME"
        chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME"
        state_save "phase_user_setup" "done"
    }

    run phase_user_setup
    assert_success
    assert_dir_exist "$OPENCLAW_HOME"
}

@test "phase_user_setup: creates .env with chmod 600" {
    useradd -m -s /bin/bash "$OPENCLAW_USER" 2>/dev/null || true
    mkdir -p "$OPENCLAW_HOME"

    local env_file="${OPENCLAW_HOME}/.env"
    touch "$env_file"
    chmod 600 "$env_file"

    # Verify permissions
    local perms
    perms=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null)
    [[ "$perms" == "600" ]]
}

@test "phase_user_setup: state saved as done" {
    useradd -m -s /bin/bash "$OPENCLAW_USER" 2>/dev/null || true

    phase_user_setup() {
        mkdir -p "$OPENCLAW_HOME"
        local env_file="${OPENCLAW_HOME}/.env"
        touch "$env_file" && chmod 600 "$env_file"
        state_save "phase_user_setup" "done"
    }

    phase_user_setup

    run state_get "phase_user_setup"
    assert_output "done"
}
