#!/usr/bin/env bash
set -euo pipefail

################################################################################
# 0.  Input + globals
################################################################################
PROJECT_DIR="$1"                         # provided by cibuildwheel
PLAT="${PLAT:-arm64}"                    # wheel arch cibuildwheel is building
GCC_SPEC="14.*"                          # accept any 14-series build

################################################################################
# 1.  Miniforge bootstrap (Å 35 MB)
################################################################################
MFROOT="$HOME/mf"
if [[ ! -d "$MFROOT" ]]; then
  curl -sL \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-$(uname -m).sh" \
    -o miniforge.sh
  bash miniforge.sh -b -p "$MFROOT"
fi
eval "$("$MFROOT/bin/conda" shell.bash hook)"
# no `mamba config` needed Ð we pass `-y` to every call

################################################################################
# 2.  Determine host / build sub-dirs and Darwin triplet
################################################################################
if [[ "$(uname -m)" == "x86_64" ]]; then
  host_subdir="osx-64";   kern_ver=13.4.0
else
  host_subdir="osx-arm64"; kern_ver=20.0.0
fi
build_subdir=$([[ "$PLAT" == "x86_64" ]] && echo "osx-64" || echo "osx-arm64")
type=$([[ "$PLAT" == "$(uname -m)" ]] && echo "native" || echo "cross")
ENVNAME="gfortran-darwin-${PLAT}-${type}"

################################################################################
# 3.  Create tool-chain environment
################################################################################
CONDA_SUBDIR="$build_subdir" \
  mamba create -y -n "$ENVNAME" \
    gfortran_impl_${build_subdir}="$GCC_SPEC" \
    libgfortran-devel_${build_subdir}="$GCC_SPEC"

CONDA_SUBDIR="$host_subdir" \
  mamba install -y -n "$ENVNAME" libgfortran="$GCC_SPEC"

conda activate "$ENVNAME"

PREFIX="$CONDA_PREFIX"
TRIPLE="${PLAT}-apple-darwin${kern_ver}"

# detect the actual gcc 14.x directory (e.g. 14.2.0)
GCCDIR=$(ls -d "$PREFIX/lib/gcc/${TRIPLE}"/14.* 2>/dev/null | head -n1)
[[ -d "$GCCDIR" ]] || { echo "ERROR: gcc dir not found"; exit 1; }

################################################################################
# 4.  Cleanup (match legacy 11.3 script)
################################################################################
rm -rf "$PREFIX"/lib/{libc++*,*.a,pkgconfig,clang} "$PREFIX"/include "$PREFIX"/conda-meta
rm -f  "$PREFIX/lib/libiomp5.dylib"

# remove heavy math libs only for cross tool-chain
if [[ "$type" == "cross" ]]; then
  for f in libgmp libgmpxx libisl libiconv libmpfr libz libcharset libmpc; do
    find "$PREFIX/lib" -name "${f}
