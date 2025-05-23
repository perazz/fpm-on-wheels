#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$1"               # supplied by cibuildwheel
PLAT="${PLAT:-arm64}"          # wheel arch requested by CIBW
export PLAT                    # keep downstream tools happy

source "${PROJECT_DIR}/tools/wheels/gfortran_utils.sh"

# ---------------------------------------------------------------------------
# 1.  Always build a native tool-chain for *this* runner’s CPU
# ---------------------------------------------------------------------------
install_gfortran   # → /opt/gfortran-darwin-$(uname -m)-native
                   # and a symlink /usr/local/bin/gfortran

# ---------------------------------------------------------------------------
# 2.  Add a cross tool-chain *only* when host ≠ target
# ---------------------------------------------------------------------------
if [[ "$PLAT" == "arm64" && "$(uname -m)" != "arm64" ]]; then
    install_arm64_cross_gfortran   # → /opt/gfortran-darwin-arm64-cross

    # Put the arm64 driver at the front of PATH so CMake finds it
    export PATH="$(_prefix arm64 cross)/bin:$PATH"
fi

# ---------------------------------------------------------------------------
# 3.  Emit helpful info for debugging (won’t break set -u)
# ---------------------------------------------------------------------------
echo "@@@ FC:" "${FC:-<not-set>}"
echo "@@@ FC_ARM64_LDFLAGS:" "${FC_ARM64_LDFLAGS:-<not-set>}"
