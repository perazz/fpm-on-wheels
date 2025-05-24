#!/usr/bin/env bash
set -euo pipefail

# USAGE: bash cibw_before_build_macos.sh <project_dir>
PROJECT_DIR="$1"

# 1. Bootstrap Miniforge
MFROOT="$HOME/mf"
if [[ ! -d "$MFROOT" ]]; then
  curl -sL \
    https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-$(uname -m).sh \
    -o miniforge.sh
  bash miniforge.sh -b -p "$MFROOT"
fi
source "$MFROOT/bin/activate"

# 2. Create toolchain env and install deps
ENVNAME="fpm-gfortran-universal"
BUILD_SUBDIR=osx-64
mamba create -y -n "$ENVNAME" \
  gfortran_impl_${BUILD_SUBDIR}="14.*" \
  libgfortran-devel_${BUILD_SUBDIR}="14.*" \
  gmp mpfr mpc

# 3. Activate and set prefixes
conda activate "$ENVNAME"
export GMP_PREFIX="$CONDA_PREFIX"
export MPFR_PREFIX="$CONDA_PREFIX"
export MPC_PREFIX="$CONDA_PREFIX"

# 4. Build universal2 GCC/GFortran
GFORTRAN_UTILS="$(pwd)/${PROJECT_DIR}/tools/wheels/gfortran_utils.sh"
source "$GFORTRAN_UTILS"
install_arm64_cross_gfortran

# 5. Expose universal driver and flags
PREFIX="$(dirname "$(install_arm64_cross_gfortran; echo $FC_ARM64)")/.."
# (install_arm64_cross_gfortran sets FC_ARM64 and FC_ARM64_LDFLAGS)
export FC="$PREFIX/bin/gfortran-universal"
export LDFLAGS="$FC_ARM64_LDFLAGS -Wl,-syslibroot,$(xcrun --show-sdk-path)"

echo "FC=$FC" >> "$CIBW_ENVIRONMENT_OUTPUT_PATH"
echo "LDFLAGS=$LDFLAGS" >> "$CIBW_ENVIRONMENT_OUTPUT_PATH"

