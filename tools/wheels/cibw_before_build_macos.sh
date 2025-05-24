#!/usr/bin/env bash
set -euo pipefail

# Usage: bash .../cibw_before_build_macos.sh <project_dir>
PROJECT_DIR="$1"

# Bootstrap Conda
MFROOT="$HOME/mf"
[[ -d "$MFROOT" ]] || bash <(curl -sL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-$(uname -m).sh) -b -p "$MFROOT"
eval "$($MFROOT/bin/conda shell.bash hook)"

# Create and activate toolchain env
BUILD_SUBDIR=osx-64
mamba create -y -n fpm-gfortran-cross gfortran_impl_osx-64="14.*" libgfortran-devel_osx-64="14.*" gmp mpfr mpc
conda activate fpm-gfortran-cross
export GMP_PREFIX="$CONDA_PREFIX"
export MPFR_PREFIX="$CONDA_PREFIX"
export MPC_PREFIX="$CONDA_PREFIX"

# Build universal2 GCC/GFortran
GFORTRAN_UTILS="$(pwd)/${PROJECT_DIR}/tools/wheels/gfortran_utils.sh"
source "$GFORTRAN_UTILS"
install_arm64_cross_gfortran  # builds arm64 cross into /opt/gfortran-darwin-arm64-cross
install_arm64_cross_gfortran x86_64 cross universal2

# Export compiler & flags
PREFIX="/opt/gfortran-darwin-arm64-cross"
export FC="$PREFIX/bin/gfortran-universal"
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
echo "FC=$FC" >> "$CIBW_ENVIRONMENT_OUTPUT_PATH"
echo "LDFLAGS=$LDFLAGS" >> "$CIBW_ENVIRONMENT_OUTPUT_PATH"
