#!/usr/bin/env bash
set -euo pipefail

################################################################################
# 0.  Input + globals
################################################################################
PROJECT_DIR="$1"                         # provided by cibuildwheel
PLAT="${CIBW_ARCH:-$(uname -m)}"         # wheel arch cibuildwheel is building
GCC_SPEC="14.*"                          # accept any 14-series build
export PLAT

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

################################################################################
# 2.  Determine host/build sub-dirs and Darwin triplet
################################################################################
if [[ "$PLAT" == "x86_64" ]]; then
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
    find "$PREFIX/lib" -name "${f}*.dylib" -delete || true
  done
fi

# remove bogus -lm from gfortran specs 
spec="$GCCDIR/libgfortran.spec"
if grep -q '\-lm' "$spec"; then
  # back-up once, patch in place
  cp "$spec" "$spec.bak"
  sed -i '' 's/ -lm/ -lSystem/g' "$spec"
fi

[[ -f "$GCCDIR/cc1.bin" ]] && mv "$GCCDIR/cc1.bin" "$GCCDIR/cc1"

################################################################################
# 5.  Expose compiler to scikit-build
################################################################################
ln -sf /usr/bin/ld "$GCCDIR/ld"          # use AppleÕs system ld
export PATH="$PREFIX/bin:$PATH"
export FC="$PREFIX/bin/${TRIPLE}-gfortran"

# LDFLAGS must exist even in the native job
LDFLAGS=""
if [[ "$type" == "cross" ]]; then
  LDFLAGS="-L$GCCDIR -Wl,-rpath,$GCCDIR"
else
  sudo cp "$PREFIX"/lib/lib{gfortran*,quadmath*,gcc_s*}.dylib /usr/local/lib/
fi
export LDFLAGS

# CMake autoconf helpers
sudo ln -sf "$FC" /usr/local/bin/gfortran

# hand back to later GitHub Actions steps
echo "FC=$FC"           >> "$GITHUB_ENV"
echo "LDFLAGS=$LDFLAGS" >> "$GITHUB_ENV"

################################################################################
# 6.  Sanity check
################################################################################
echo "### sanity check"
echo "FC      = $FC"
echo "LDFLAGS = ${LDFLAGS:-<none>}"

"$FC" -v | head -n 1 || { echo "gfortran failed to start"; exit 99; }
