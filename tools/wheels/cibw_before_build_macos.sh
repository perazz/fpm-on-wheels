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
# 1.  Miniforge bootstrap (~ 35 MB)
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

SDKROOT=$(xcrun --show-sdk-path)

# make the SDK visible *while linking*
export LIBRARY_PATH="$SDKROOT/usr/lib:${LIBRARY_PATH:-}"
export LDFLAGS="-Wl,-syslibroot,$SDKROOT ${LDFLAGS:-}"

# keep the compile-time sysroot flags we already added
export CFLAGS="-isysroot $SDKROOT ${CFLAGS:-}"
export CXXFLAGS="-isysroot $SDKROOT ${CXXFLAGS:-}"
export FFLAGS="-isysroot $SDKROOT ${FFLAGS:-}"

echo "CFLAGS=$CFLAGS"   >> "$GITHUB_ENV"
echo "CXXFLAGS=$CXXFLAGS" >> "$GITHUB_ENV"
echo "FFLAGS=$FFLAGS"   >> "$GITHUB_ENV"
echo "LDFLAGS=$LDFLAGS" >> "$GITHUB_ENV"

PREFIX="$CONDA_PREFIX"
TRIPLE="${PLAT}-apple-darwin${kern_ver}"

###############################################################################
# 3b.  Locate GCC versioned lib directory 
###############################################################################
FC="$PREFIX/bin/${TRIPLE}-gfortran"        # we know this path already
GCCDIR="$(dirname "$("$FC" -print-libgcc-file-name)")"

# sanity-check
[[ -d "$GCCDIR" ]] || {
  echo "ERROR: could not determine GCC lib directory (got: $GCCDIR)"
  exit 1
}


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

###############################################################################
# 4b.  Patch libgfortran.spec → add sysroot + swap -lm → -lSystem
###############################################################################
spec="$GCCDIR/libgfortran.spec"
if ! grep -q -- "-Wl,-syslibroot," "$spec"; then
  cp "$spec" "$spec.bak"                 # keep one pristine copy
  # turn each " -lm" into " -Wl,-syslibroot,<sdk> -lSystem"
  sed -i '' "s| -lm| -Wl,-syslibroot,$SDKROOT -lSystem|g" "$spec"
fi

[[ -f "$GCCDIR/cc1.bin" ]] && mv "$GCCDIR/cc1.bin" "$GCCDIR/cc1"

################################################################################
# 5.  Expose compiler to scikit-build
################################################################################
ln -sf /usr/bin/ld "$GCCDIR/ld"          # use Apple’s system ld
export PATH="$PREFIX/bin:$PATH"
export FC="$PREFIX/bin/${TRIPLE}-gfortran"

# LDFLAGS must exist even in the native job
LDFLAGS="-Wl,-syslibroot,$SDKROOT"
LDFLAGS="-syslibroot $SDKROOT"              
if [[ "$type" == "cross" ]]; then
  LDFLAGS+=" -L$GCCDIR -rpath $GCCDIR"      
else
  sudo cp "$PREFIX"/lib/lib{gfortran*,quadmath*,gcc_s*}.dylib /usr/local/lib/
fi
export LDFLAGS

# CMake autoconf helpers
sudo ln -sf "$FC" /usr/local/bin/gfortran

# hand back to later GitHub Actions steps
echo "FC=$FC"           >> "$GITHUB_ENV"
echo "LDFLAGS=$LDFLAGS" >> "$GITHUB_ENV"

# ────────────────────────────────────────────────────────────────────────────
# Record SDK path for cibuildwheel's build phase
# (the variable CIBW_ENVIRONMENT_OUTPUT_PATH exists only in >= 2.18;
# guard with -n to stay compatible with older releases)
# ────────────────────────────────────────────────────────────────────────────
if [[ -n "${CIBW_ENVIRONMENT_OUTPUT_PATH:-}" ]]; then
  {
    echo "SDKROOT=$SDKROOT"
    echo "CMAKE_OSX_SYSROOT=$SDKROOT"
  } >> "$CIBW_ENVIRONMENT_OUTPUT_PATH"
fi

################################################################################
# 6.  Sanity check
################################################################################
echo "### sanity check"
echo "FC      = $FC"
echo "LDFLAGS = ${LDFLAGS:-<none>}"

"$FC" -v | head -n 1 || { echo "gfortran failed to start"; exit 99; }
