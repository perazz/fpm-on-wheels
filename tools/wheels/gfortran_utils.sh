#!/usr/bin/env bash
set -euo pipefail

: "${MACOSX_DEPLOYMENT_TARGET:=$(python3 -c 'import sysconfig;print(sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET") or "11.0"))}"
export SDKROOT="$(xcrun --show-sdk-path)"
GCC_VERSION=14.3.0
GCC_TARBALL=gcc-${GCC_VERSION}.tar.gz
GCC_URL=https://github.com/gcc-mirror/gcc/archive/refs/tags/releases/gcc-${GCC_VERSION}.tar.gz

function _prefix() { echo "/opt/gfortran-darwin-$1-cross"; }

function _fetch_gcc_source {
  [[ -s "$GCC_TARBALL" ]] || curl -L -o "$GCC_TARBALL" "$GCC_URL"
  tar -xf "$GCC_TARBALL" --strip-components=1 -C gcc-${GCC_VERSION}
}

function _build_gcc {
  arch="$1"
  prefix="$(_prefix $arch)"
  host="${arch}-apple-darwin$(uname -r)"
  mkdir -p build-${arch}-cross && pushd build-${arch}-cross
  ../gcc-${GCC_VERSION}/configure --prefix="$prefix" \
    --build=$(../gcc-${GCC_VERSION}/config.guess) \
    --host="$host" --target="$host" \
    --enable-languages=c,fortran --disable-multilib --disable-nls \
    --with-system-zlib --with-gmp=${GMP_PREFIX} --with-mpfr=${MPFR_PREFIX} --with-mpc=${MPC_PREFIX}
  make -j$(sysctl -n hw.logicalcpu) && sudo make install
  popd
}

function install_arm64_cross_gfortran {
  _fetch_gcc_source
  _build_gcc arm64
  # universal wrapper
  ws="$(_prefix arm64)/bin"
  cat > "$ws/gfortran-universal" << 'EOF'
#!/usr/bin/env bash
exec "$ws/gfortran" -arch x86_64 -arch arm64 "$@"
EOF
  chmod +x "$ws/gfortran-universal"
}

