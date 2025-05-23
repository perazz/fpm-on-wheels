#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$1"              # passed in by cibuildwheel
PLAT="${PLAT:-arm64}"         # macosx-arm64 wheel in this job
export PLAT

source "${PROJECT_DIR}/tools/wheels/gfortran_utils.sh"

# 1.  Build a native compiler for the host we are actually running on
install_gfortran               # produces /opt/gfortran-darwin-$(uname -m)-native

# 2.  If we’re cross-compiling, add an arm64 tool-chain as well
if [[ "$PLAT" == "arm64" && "$(uname -m)" != "arm64" ]]; then
    install_arm64_cross_gfortran   # /opt/gfortran-darwin-arm64-cross
fi

# 3.  Print the variables that the build step needs to copy from the log
echo "@@@ FC:" "$FC"
echo "@@@ FC_ARM64_LDFLAGS:" "$FC_ARM64_LDFLAGS"

