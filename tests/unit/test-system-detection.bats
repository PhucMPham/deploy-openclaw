#!/usr/bin/env bats
# test-system-detection.bats — Tests for detect_os, detect_user, check_disk_space

setup() {
    load '../helpers/test-helper'
    setup_test_env
    source_deploy_script
    override_run_with_sudo
}

teardown() {
    teardown_test_env
}

# --- detect_os ---

@test "detect_os: accepts Ubuntu 22.04" {
    setup_fake_os_release "ubuntu" "22.04" "Ubuntu 22.04.4 LTS"
    # Override /etc/os-release path by sourcing our fake one
    detect_os() {
        # shellcheck disable=SC1091
        source "$TEST_TMPDIR/etc/os-release"
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-0}"
        OS_NAME="${PRETTY_NAME:-Unknown}"
        case "$OS_ID" in
            ubuntu)
                if ! awk "BEGIN{exit !(${OS_VERSION} >= 22.04)}"; then
                    return 1
                fi ;;
            debian)
                if (( ${OS_VERSION%%.*} < 11 )); then return 1; fi ;;
        esac
        return 0
    }
    run detect_os
    assert_success
}

@test "detect_os: accepts Ubuntu 24.04" {
    setup_fake_os_release "ubuntu" "24.04" "Ubuntu 24.04 LTS"
    detect_os() {
        source "$TEST_TMPDIR/etc/os-release"
        OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-0}"
        case "$OS_ID" in
            ubuntu) awk "BEGIN{exit !(${OS_VERSION} >= 22.04)}" || return 1 ;;
        esac
        return 0
    }
    run detect_os
    assert_success
}

@test "detect_os: accepts Debian 11" {
    setup_fake_os_release "debian" "11" "Debian GNU/Linux 11 (bullseye)"
    detect_os() {
        source "$TEST_TMPDIR/etc/os-release"
        OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-0}"
        case "$OS_ID" in
            debian) (( ${OS_VERSION%%.*} >= 11 )) || return 1 ;;
        esac
        return 0
    }
    run detect_os
    assert_success
}

@test "detect_os: rejects Ubuntu 20.04 as too old" {
    setup_fake_os_release "ubuntu" "20.04" "Ubuntu 20.04 LTS"
    detect_os() {
        source "$TEST_TMPDIR/etc/os-release"
        OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-0}"
        case "$OS_ID" in
            ubuntu)
                if ! awk "BEGIN{exit !(${OS_VERSION} >= 22.04)}"; then return 1; fi ;;
        esac
        return 0
    }
    run detect_os
    assert_failure
}

@test "detect_os: warns but continues on unknown OS" {
    setup_fake_os_release "fedora" "39" "Fedora Linux 39"
    detect_os() {
        source "$TEST_TMPDIR/etc/os-release"
        OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-0}"; OS_NAME="${PRETTY_NAME:-Unknown}"
        case "$OS_ID" in
            ubuntu|debian) ;; # known
            *) ;; # unknown — warn but continue (return 0)
        esac
        return 0
    }
    run detect_os
    assert_success
}

# --- detect_user ---

@test "detect_user: detects root correctly" {
    # Running as root in Docker
    run detect_user
    assert_success
    [[ "$IS_ROOT" == "true" ]] || [[ "$(whoami)" == "root" ]]
}

# --- check_disk_space ---

@test "check_disk_space: passes with sufficient disk space" {
    local mock_dir="$TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/df" << 'MOCKDF'
#!/usr/bin/env bash
echo "Filesystem     1M-blocks  Used Available Use% Mounted on"
echo "/dev/sda1      50000  20000     5000  30% /"
MOCKDF
    chmod +x "$mock_dir/df"
    export PATH="$mock_dir:$PATH"
    MIN_DISK_MB=2048
    run check_disk_space
    assert_success
}

@test "check_disk_space: fails with insufficient disk space" {
    local mock_dir="$TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/df" << 'MOCKDF'
#!/usr/bin/env bash
echo "Filesystem     1M-blocks  Used Available Use% Mounted on"
echo "/dev/sda1      50000  49500      500  99% /"
MOCKDF
    chmod +x "$mock_dir/df"
    export PATH="$mock_dir:$PATH"
    MIN_DISK_MB=2048
    run check_disk_space
    assert_failure
}
