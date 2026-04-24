#!/bin/bash
# =============================================================================
# run_tests.sh — Test runner (execute on host: Arch Linux / any Docker host)
# =============================================================================
# Usage:
#   ./run_tests.sh              # test both Ubuntu 22.04 and 24.04
#   ./run_tests.sh 2204         # test Ubuntu 22.04 only
#   ./run_tests.sh 2404         # test Ubuntu 24.04 only
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS=("2204" "2404")

# Filter to specific version if given
if [[ $# -ge 1 ]]; then
    VERSIONS=("$1")
fi

# ── Check Docker is available ─────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Docker is not installed."
    echo "  Arch: sudo pacman -S docker && sudo systemctl start docker"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Docker daemon is not running or no permissions."
    echo "  Try: sudo systemctl start docker"
    echo "  Or add user to docker group: sudo usermod -aG docker \$USER"
    exit 1
fi

# ── Run tests per Ubuntu version ──────────────────────────────────────────────
OVERALL_PASS=0
OVERALL_FAIL=0
FAILED_VERSIONS=()

for VER in "${VERSIONS[@]}"; do
    IMAGE="rdp-test-ubuntu${VER}"
    DOCKERFILE="tests/Dockerfile.ubuntu${VER}"

    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║  Testing Ubuntu ${VER}                       ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"

    # Build
    echo -e "${YELLOW}Building image ${IMAGE}...${NC}"
    if docker build \
        --file "$DOCKERFILE" \
        --tag "$IMAGE" \
        --quiet \
        "$SCRIPT_DIR" 2>&1 | tail -5; then
        echo -e "${GREEN}[OK]${NC} Image built"
    else
        echo -e "${RED}[FAIL]${NC} Docker build failed for Ubuntu ${VER}"
        (( OVERALL_FAIL++ ))
        FAILED_VERSIONS+=("ubuntu${VER}: build failed")
        continue
    fi

    # Run
    echo -e "${YELLOW}Running tests...${NC}"
    if docker run --rm "$IMAGE"; then
        echo -e "\n${GREEN}[PASS]${NC} Ubuntu ${VER} — all tests passed"
        (( OVERALL_PASS++ ))
    else
        echo -e "\n${RED}[FAIL]${NC} Ubuntu ${VER} — some tests failed"
        (( OVERALL_FAIL++ ))
        FAILED_VERSIONS+=("ubuntu${VER}: tests failed")
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Results: ${GREEN}${OVERALL_PASS} passed${NC} / ${RED}${OVERALL_FAIL} failed${NC}"

if [[ ${#FAILED_VERSIONS[@]} -gt 0 ]]; then
    echo -e "\n${RED}Failed:${NC}"
    for v in "${FAILED_VERSIONS[@]}"; do
        echo "  • $v"
    done
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    exit 1
fi

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
exit 0
