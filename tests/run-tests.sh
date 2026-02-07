#!/usr/bin/env bash
# run-tests.sh — Build Docker image and run BATS tests for deploy-openclaw.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="deploy-openclaw-tests"

cd "$PROJECT_ROOT"

# Parse arguments
TEST_FILTER=""
case "${1:-}" in
    --unit)        TEST_FILTER="tests/unit/" ;;
    --integration) TEST_FILTER="tests/integration/" ;;
    --help|-h)
        echo "Usage: $0 [--unit|--integration]"
        echo "  --unit         Run unit tests only"
        echo "  --integration  Run integration tests only"
        echo "  (no args)      Run all tests"
        exit 0
        ;;
esac

echo "=== Building test image ==="
docker build -t "$IMAGE_NAME" -f tests/Dockerfile .

echo ""
echo "=== Running tests ==="
if [[ -n "$TEST_FILTER" ]]; then
    docker run --rm "$IMAGE_NAME" bats --recursive "$TEST_FILTER"
else
    docker run --rm "$IMAGE_NAME" bats --recursive tests/
fi
