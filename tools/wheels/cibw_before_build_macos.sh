#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$1"
PLAT="${PLAT:-arm64}"          # wheel arch requested by cibuildwheel
export PLAT

GCC_VER="14.3.0"

###############################################################################
# 0.  install Miniforge + mamba (≈ 35 MB)
###############################################################################
MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-$(uname -m).sh"
curl -sL "$MINIFORGE_URL" -o miniforge.sh
bash miniforge.sh -b -p "$HOME/mf"
eval "$("$HOME/mf/bin/conda" shell.bash hook)"
mamba config set always_yes true

###############################################################################
# 1.  decide native vs cross
###############################################################################
if [[ "$(uname -m)" == "x86_64" ]]; then
  host_subdir="osx-64"
  kern_ver=13.4.0
else
  host_subdir="osx-arm64"
  kern_ver=20.0.0
fi

if [[ "$PLAT" == "x86_64" ]]; then
  build_subdir="osx-64"
else
  build_subdir="osx-arm64"
fi

type=$([[ "$PLAT" == "$(uname -m)" ]] && echo "native" || echo "cross")
ENVNAME="gfortran-darwin-${PLAT}-${type}"

###############################################################################
# 2.  create the conda env with the tool-chain
###############################################################################
CONDA_SUBDIR="$build_subdir" \
  mamba create -n "$ENVNAME" \
    gfortran_impl_${build_subdir}="$GCC_VER" \
    libgfortran-devel_${build_subdir}="$GCC_VER"

CONDA_SUBDIR="$host_subdir" \
  mamba install -n "$ENVNAME" libgfortran="$GCC_VER"

conda activate "$ENVNAME"
PREFIX="$CONDA_PREFIX"
TRIPLE="${PLAT}-apple-darwin${kern_ver}"
GCCDIR="$PREFIX/lib/gcc/${TRIPLE}/${GCC_VER}"

###############################################################################
# 3.  trim rpaths & delete superfluous dylibs (same as the old script)
###############################################################################
rm -rf "$PREFIX"/lib/{libc++*,*.a,pkgconfig,clang} "$PREFIX"/include "$PREFIX"/conda-meta

# --- scrub libraries if cross-compiler 
if [[ "$type" == "cross" ]]; then
  for f in libgmp libgmpxx libisl libiconv libmpfr libz libcharset libmpc; do
      find "$PREFIX/lib" -name "${f}*.dylib" -delete || true
  done
fi

rm -f "$PREFIX/lib/libiomp5.dylib"

install_name_tool -delete_rpath "$PREFIX/lib" "$GCCDIR"/libgfortran.spec || true

# conda-forge ships cc1.bin; rename so the driver finds it
mv "$GCCDIR/cc1.bin" "$GCCDIR/cc1"

###############################################################################
# 4.  expose the compiler for scikit-build
###############################################################################
ln -sf /usr/bin/ld "$GCCDIR/ld"          # use Apple’s system ld
export PATH="$PREFIX/bin:$PATH"
export FC="$PREFIX/bin/${TRIPLE}-gfortran"

if [[ "$type" == "cross" ]]; then
  # ensure runtime libs live where the linker expects
  export LDFLAGS="-L$GCCDIR -Wl,-rpath,$GCCDIR"
else
  # make the native runtime dylibs resolvable at build time
  sudo cp "$PREFIX"/lib/libgfortran*.dylib /usr/local/lib/
  sudo cp "$PREFIX"/lib/libquadmath*.dylib /usr/local/lib/
  sudo cp "$PREFIX"/lib/libgcc_s*.dylib /usr/local/lib/
fi

echo "### sanity check"
echo "@@@ FC     : ${FC:-<unset>}"
echo "@@@ LDFLAGS:" "${LDFLAGS:-<none>}"
echo "@@@ PATH   : $PATH"

"$FC" -v || { echo "### gfortran did not start"; exit 99; }
