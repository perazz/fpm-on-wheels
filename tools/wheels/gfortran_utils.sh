#!/usr/bin/env bash
set -euo pipefail

# Minimal vendored helper for universal2 builds
: "${MACOSX_DEPLOYMENT_TARGET:=$(python3 -c 'import sysconfig;print(sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET") or "11.0")')}"
export SDKROOT="$(xcrun --show-sdk-path)"
GCC_VERSION=14.3.0
GCC_TARBALL=gcc-${GCC_VERSION}.tar.gz
GCC_URL=https://github.com/gcc-mirror/gcc/archive/refs/tags/releases/gcc-${GCC_VERSION}.tar.gz

# Prefix for cross build
function _prefix { echo "/opt/gfortran-darwin-$1-cross"; }

# Fetch and unpack GCC source
function _fetch_gcc_source {
  [[ -s "$GCC_TARBALL" ]] || curl -L -o "$GCC_TARBALL" "$GCC_URL"
  mkdir -p gcc-${GCC_VERSION}
  tar -xf "$GCC_TARBALL" --strip-components=1 -C gcc-${GCC_VERSION}
}

# Build helper
function _build_gcc {
  arch="$1"
  prefix="$(_prefix $arch)"
  host="${arch}-apple-darwin$(uname -r)"
  export AR=/usr/bin/ar
  export RANLIB=/usr/bin/ranlib
  mkdir -p build-${arch}-cross && pushd build-${arch}-cross
  ../gcc-${GCC_VERSION}/configure \
    --prefix="$prefix" \
    --build=$(../gcc-${GCC_VERSION}/config.guess) \
    --host="$host" --target="$host" \
    --enable-languages=c,fortran \
    --disable-multilib --disable-nls \
    --with-system-zlib \
    --with-gmp=${GMP_PREFIX} --with-mpfr=${MPFR_PREFIX} --with-mpc=${MPC_PREFIX}
  make -j$(sysctl -n hw.logicalcpu) && sudo make install
  popd
}

# Update config.sub and config.guess to latest versions
function _update_config_sub {
  local src_dir="gcc-${GCC_VERSION}"
  pushd "$src_dir" >/dev/null

  # Download newest autotools helper scripts
  curl -fsSL \
    https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub \
    -o build-aux/config.sub
  curl -fsSL \
    https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess \
    -o build-aux/config.guess

  # Propagate to all subdirectories
  find . -name config.sub   -exec cp build-aux/config.sub   {} \;
  find . -name config.guess -exec cp build-aux/config.guess {} \;
  popd >/dev/null
}

function install_arm64_cross_gfortran {
  _fetch_gcc_source
  _update_config_sub
  _build_gcc arm64
    
  # where gcc got installed for arm64
  prefix="$(_prefix arm64)"  
  
  # generate a "universal2" wrapper
  cat > "$prefix/bin/gfortran-universal" <<EOF
#!/usr/bin/env bash
# call the sibling gfortran binary with both arches
exec "\$(dirname "\$0")/gfortran" -arch x86_64 -arch arm64 "\$@"
EOF

  chmod +x "$prefix/bin/gfortran-universal"

  # export for callers
  export FC_ARM64="$prefix/bin/gfortran"
  export FC_ARM64_LDFLAGS="-L$prefix/lib -Wl,-rpath,$prefix/lib"
}


