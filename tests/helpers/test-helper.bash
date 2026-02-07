#!/usr/bin/env bash
# test-helper.bash — Shared setup for all BATS tests

# Load bats helpers (source directly — bats 1.2.1 load resolves relative to test dir)
# shellcheck disable=SC1091
source /usr/lib/bats/bats-support/load.bash
# shellcheck disable=SC1091
source /usr/lib/bats/bats-assert/load.bash
# shellcheck disable=SC1091
source /usr/lib/bats/bats-file/load.bash

# Prevent side effects when sourcing deploy-openclaw.sh
export DEPLOY_TESTING=1

# Project root (inside Docker container)
PROJECT_ROOT="/workspace"
DEPLOY_SCRIPT="${PROJECT_ROOT}/scripts/deploy-openclaw.sh"

# Per-test temp directory for state/log files
setup_test_env() {
    TEST_TMPDIR="$(mktemp -d)"

    # Override readonly vars before sourcing — use temp paths
    export OPENCLAW_HOME="$TEST_TMPDIR/openclaw"
    export STATE_FILE="$TEST_TMPDIR/openclaw/.deploy-state"
    export LOG_FILE="$TEST_TMPDIR/openclaw/deploy.log"

    mkdir -p "$OPENCLAW_HOME"

    # Set default globals that the script expects
    export IS_ROOT=true
    export HAS_SUDO=false
    export CURRENT_USER="root"
    export HAS_GUM=false
    export HAS_FZF=false
    export TUI_RESULT=0
}

teardown_test_env() {
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# Source the deploy script with readonly var workaround.
# The script uses `readonly` for constants — we need to set our overrides
# BEFORE sourcing. Since bash won't let you re-declare readonly vars,
# we use a filtered source approach.
source_deploy_script() {
    # Create a modified version that skips readonly declarations for vars we override
    local filtered_script="$TEST_TMPDIR/deploy-filtered.sh"

    # Replace readonly for vars we need to override with regular assignments,
    # and skip set -euo pipefail / umask (applied to test runner otherwise)
    sed \
        -e 's/^set -euo pipefail$/# [test] set -euo pipefail/' \
        -e 's/^umask 077$/# [test] umask 077/' \
        -e 's/^readonly OPENCLAW_HOME=.*/# [test] OPENCLAW_HOME (overridden)/' \
        -e 's/^readonly STATE_FILE=.*/# [test] STATE_FILE (overridden)/' \
        -e 's/^readonly LOG_FILE=.*/# [test] LOG_FILE (overridden)/' \
        -e 's/^readonly MIN_DISK_MB=.*/# [test] MIN_DISK_MB (overridden)/' \
        -e 's/^readonly /declare /' \
        -e '/^\[\[.*BASH_SOURCE.*\]\] && main/d' \
        "$DEPLOY_SCRIPT" > "$filtered_script"

    # Set defaults for overridden vars
    OPENCLAW_HOME="$TEST_TMPDIR/openclaw"
    STATE_FILE="$TEST_TMPDIR/openclaw/.deploy-state"
    LOG_FILE="$TEST_TMPDIR/openclaw/deploy.log"
    MIN_DISK_MB=2048

    # Source the filtered script — source guard prevents main() from running
    # shellcheck disable=SC1090
    source "$filtered_script"
}

# Mock a command by creating a shell script in a temp bin directory
mock_command() {
    local cmd_name="$1"
    local exit_code="${2:-0}"
    local output="${3:-}"
    local mock_dir="$TEST_TMPDIR/mock-bin"

    mkdir -p "$mock_dir"
    cat > "$mock_dir/$cmd_name" << MOCK
#!/usr/bin/env bash
${output:+echo "$output"}
exit $exit_code
MOCK
    chmod +x "$mock_dir/$cmd_name"
    export PATH="$mock_dir:$PATH"
}

# Create a fake /etc/os-release for OS detection tests
setup_fake_os_release() {
    local id="${1:-ubuntu}"
    local version_id="${2:-22.04}"
    local pretty_name="${3:-$id $version_id}"

    mkdir -p "$TEST_TMPDIR/etc"
    cat > "$TEST_TMPDIR/etc/os-release" << EOF
ID=$id
VERSION_ID="$version_id"
PRETTY_NAME="$pretty_name"
EOF
}

# Override run_with_sudo to just run the command directly (we're root in Docker)
override_run_with_sudo() {
    run_with_sudo() {
        bash -c "$*"
    }
}
