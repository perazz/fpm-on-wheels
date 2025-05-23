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

# host_subdir = *target* arch  (libs that will end up in the wheel)
if [[ "$PLAT" == "x86_64" ]]; then
  host_subdir="osx-64";   kern_ver=13.4.0
else
  host_subdir="osx-arm64"; kern_ver=20.0.0
fi

# build_subdir = *runner* arch (the compiler we can execute right now)
if [[ "$(uname -m)" == "x86_64" ]]; then
  build_subdir="osx-64"
else
  build_subdir="osx-arm64"
fi
type=$([[ "$PLAT" == "$(uname -m)" ]] && echo "native" || echo "cross")
ENVNAME="gfortran-darwin-${PLAT}-${type}"

###############################################################################
# 2b.  Make sure the env name is clean
###############################################################################
ENVPATH="$MFROOT/envs/$ENVNAME"
if [[ -d "$ENVPATH" && ! -f "$ENVPATH/conda-meta/history" ]]; then
  echo "Removing stale non-conda folder at $ENVPATH"
  rm -rf "$ENVPATH"
fi

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

PREFIX="$CONDA_PREFIX"
if [[ "$PLAT" == "arm64" ]]; then
  TRIPLE="aarch64-apple-darwin${kern_ver}"   # GCC’s naming
else
  TRIPLE="x86_64-apple-darwin${kern_ver}"
fi

# First make sure that driver exists (cross build only)
FC_DRIVER="$PREFIX/bin/${TRIPLE}-gfortran"
[[ -x "$FC_DRIVER" ]] || {
  echo "ERROR: cross-compiler driver $FC_DRIVER not found"
  exit 1
}
export FC="$FC_DRIVER"

###############################################################################
# 3b.  Locate GCC versioned lib directory 
###############################################################################
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
sed -i '' 's/-Wl,-syslibroot,/-syslibroot /g' "$spec"

[[ -f "$GCCDIR/cc1.bin" ]] && mv "$GCCDIR/cc1.bin" "$GCCDIR/cc1"

###############################################################################
# 4c.  Cross wrapper that injects “-arch arm64” on every invocation
###############################################################################
if [[ "$type" == "cross" ]]; then
  WRAPPER="$PREFIX/bin/gfortran-arm64"
  cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Forward to the host gfortran but force Apple-Silicon output
exec "$(dirname "$0")/gfortran" -arch arm64 "$@"
EOF
  chmod +x "$WRAPPER"
  export FC="$WRAPPER"
fi

################################################################################
# 5.  Expose compiler to scikit-build
################################################################################
ln -sf /usr/bin/ld "$GCCDIR/ld"          # use Apple’s system ld
export PATH="$PREFIX/bin:$PATH"

# CMake autoconf helpers
sudo ln -sf "$FC" /usr/local/bin/gfortran   # CMake will call this path
echo "FC=$FC" >> "$GITHUB_ENV"


# LDFLAGS must exist even in the native job
LDFLAGS="-Wl,-syslibroot,$SDKROOT"
if [[ "$type" == "cross" ]]; then
  LDFLAGS+=" -L$GCCDIR -Wl,-rpath,$GCCDIR"
else
  sudo cp "$PREFIX"/lib/lib{gfortran*,quadmath*,gcc_s*}.dylib /usr/local/lib/
fi
export LDFLAGS
echo "LDFLAGS=$LDFLAGS" >> "$GITHUB_ENV"

# hand back to later GitHub Actions steps
echo "CMAKE_OSX_ARCHITECTURES=$PLAT" >> "$GITHUB_ENV"
if [[ "$type" == "cross" ]]; then
  echo "CMAKE_SYSTEM_PROCESSOR=$PLAT" >> "$GITHUB_ENV"   # arm64
fi

# ────────────────────────────────────────────────────────────────────────────
# Record SDK path for cibuildwheel's build phase
# (the variable CIBW_ENVIRONMENT_OUTPUT_PATH exists only in >= 2.18;
# guard with -n to stay compatible with older releases)
# ────────────────────────────────────────────────────────────────────────────
if [[ -n "${CIBW_ENVIRONMENT_OUTPUT_PATH:-}" ]]; then
  {
    echo "FC=$FC"
    echo "LDFLAGS=$LDFLAGS"  
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
