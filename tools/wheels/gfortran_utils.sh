# This file is vendored from github.com/MacPython/gfortran-install It is
# licensed under BSD-2 which is copied as a comment below

# Copyright 2016-2021 Matthew Brett, Isuru Fernando, Matti Picus

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:

# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.

# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or
# other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Bash utilities for use with gfortran

ARCHIVE_SDIR="${ARCHIVE_SDIR:-archives}"

GF_UTIL_DIR=$(dirname "${BASH_SOURCE[0]}")

function get_distutils_platform {
    # Report platform as in form of distutils get_platform.
    # This is like the platform tag that pip will use.
    # Modify fat architecture tags on macOS to reflect compiled architecture

    # Deprecate this function once get_distutils_platform_ex is used in all
    # downstream projects
    local plat=$1
    case $plat in
        i686|x86_64|arm64|universal2|intel|aarch64|s390x|ppc64le) ;;
        *) echo Did not recognize plat $plat; return 1 ;;
    esac
    local uname=${2:-$(uname)}
    if [ "$uname" != "Darwin" ]; then
        if [ "$plat" == "intel" ]; then
            echo plat=intel not allowed for Manylinux
            return 1
        fi
        echo "manylinux1_$plat"
        return
    fi
    # macOS 32-bit arch is i386
    [ "$plat" == "i686" ] && plat="i386"
    local target=$(echo $MACOSX_DEPLOYMENT_TARGET | tr .- _)
    echo "macosx_${target}_${plat}"
}

function get_distutils_platform_ex {
    # Report platform as in form of distutils get_platform.
    # This is like the platform tag that pip will use.
    # Modify fat architecture tags on macOS to reflect compiled architecture
    # For non-darwin, report manylinux version
    local plat=$1
    local mb_ml_ver=${MB_ML_VER:-1}
    case $plat in
        i686|x86_64|arm64|universal2|intel|aarch64|s390x|ppc64le) ;;
        *) echo Did not recognize plat $plat; return 1 ;;
    esac
    local uname=${2:-$(uname)}
    if [ "$uname" != "Darwin" ]; then
        if [ "$plat" == "intel" ]; then
            echo plat=intel not allowed for Manylinux
            return 1
        fi
        echo "manylinux${mb_ml_ver}_${plat}"
        return
    fi
    # macOS 32-bit arch is i386
    [ "$plat" == "i686" ] && plat="i386"
    local target=$(echo $MACOSX_DEPLOYMENT_TARGET | tr .- _)
    echo "macosx_${target}_${plat}"
}

function get_macosx_target {
    # Report MACOSX_DEPLOYMENT_TARGET as given by distutils get_platform.
    python3 -c "import sysconfig as s; print(s.get_config_vars()['MACOSX_DEPLOYMENT_TARGET'])"
}

function check_gfortran {
    # Check that gfortran exists on the path
    if [ -z "$(which gfortran)" ]; then
        echo Missing gfortran
        exit 1
    fi
}

function get_gf_lib_for_suf {
    local suffix=$1
    local prefix=$2
    local plat=${3:-$PLAT}
    local uname=${4:-$(uname)}
    if [ -z "$prefix" ]; then echo Prefix not defined; exit 1; fi
    local plat_tag=$(get_distutils_platform_ex $plat $uname)
    if [ -n "$suffix" ]; then suffix="-$suffix"; fi
    local fname="$prefix-${plat_tag}${suffix}.tar.gz"
    local out_fname="${ARCHIVE_SDIR}/$fname"
    [ -s $out_fname ] || (echo "$out_fname is empty"; exit 24)
    echo "$out_fname"
}

# ---------- macOS (build GCC / GFortran 14.3.0) -----------------------------

if [ "$(uname)" = "Darwin" ]; then
    : "${MACOSX_DEPLOYMENT_TARGET:=$(python3 -c 'import sysconfig, os;print(sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET") or "11.0")')}"
    export MACOSX_DEPLOYMENT_TARGET
    export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"

    # ---- version/URL helpers ------------------------------------------------
    GCC_VERSION="14.3.0"
    GCC_TAG="releases/gcc-${GCC_VERSION}"
    GCC_TARBALL="gcc-${GCC_VERSION}.tar.gz"
    GCC_URL="https://github.com/gcc-mirror/gcc/archive/refs/tags/${GCC_TAG}.tar.gz"

    # installation prefix keeps the old naming convention so the rest
    # of the build machinery (wheel-repair, rpaths, etc.) stays unchanged
    function _prefix() { echo "/opt/gfortran-darwin-$1-$2"; }   # $1 = arch, $2 = native|cross

    # ---- download & verify --------------------------------------------------
    function _fetch_gcc_source {
        [ -s "${GCC_TARBALL}" ] || curl -L -o "${GCC_TARBALL}" "${GCC_URL}"

        local sha_file="${GCC_TARBALL}.sha1"
        if [ ! -f "${sha_file}" ]; then
            shasum "${GCC_TARBALL}" | cut -d' ' -f1 > "${sha_file}"
        fi
        echo "$(cat "${sha_file}")  ${GCC_TARBALL}" | shasum -c -

        # Unpack only once, renaming the top-level dir to gcc-14.3.0
        if [ ! -d "gcc-${GCC_VERSION}" ]; then
            mkdir "gcc-${GCC_VERSION}"
            tar -xf "${GCC_TARBALL}" --strip-components=1 -C "gcc-${GCC_VERSION}"
        fi
    }    
        
    # ---- build helpers ------------------------------------------------------
    # $1 = arch (arm64 / x86_64) ; $2 = native|cross
    function _build_gcc {
        local arch="$1" ; local kind="$2"
        local srcdir="gcc-${GCC_VERSION}"
        local builddir="build-${arch}-${kind}"
        local prefix="$(_prefix ${arch} ${kind})"

        # Host triplet for configure – arm64-apple-darwin23 or x86_64-apple-darwin23, etc.
        local host="${arch}-apple-darwin$(uname -r)"

        mkdir -p "${builddir}" && pushd "${builddir}"

        # Configure
        ../"${srcdir}"/configure \
            --prefix="${prefix}" \
            --build="$(../${srcdir}/config.guess)" \
            --host="${host}" \
            --target="${host}" \
            --enable-languages=c,fortran \
            --disable-multilib \
            --disable-nls \
            --with-system-zlib \
            --with-gmp=${GMP_PREFIX} \
            --with-mpfr=${MPFR_PREFIX} \
            --with-mpc=${MPC_PREFIX}
        # Build + install
        make -j"$(sysctl -n hw.logicalcpu)" && sudo make install
        popd
    }

    # ---- high-level entry points --------------------------------------------
    function install_gfortran {          # native toolchain for current host
        _fetch_gcc_source
        _build_gcc "$(uname -m)" native
        sudo ln -sf "$(_prefix $(uname -m) native)/bin/gfortran" /usr/local/bin/gfortran
        for f in libgfortran.dylib libgfortran.a libquadmath.dylib; do
            sudo ln -sf "$(_prefix $(uname -m) native)/lib/$f" /usr/local/lib/$f
        done
    }

    function install_arm64_cross_gfortran {
        _fetch_gcc_source
        if [[ "$(uname -m)" != "arm64" ]]; then
            _build_gcc arm64 cross
        fi
        export FC_ARM64="$(_prefix arm64 cross)/bin/aarch64-apple-darwin$(uname -r)-gfortran"
        local libdir="$(_prefix arm64 cross)/lib"
        export FC_ARM64_LDFLAGS="-L${libdir} -Wl,-rpath,${libdir}"
        [[ "${PLAT:-}" == "arm64" ]] && export FC="${FC_ARM64}"
    }

    # keep get_gf_lib unchanged – the library file names still start with libgfortran…
    function get_gf_lib {
        get_gf_lib_for_suf "gf_$(cat ${GCC_TARBALL}.sha1 | cut -c1-7)" "$@"
    }
else
    function install_gfortran {
        # No-op - already installed on manylinux image
        check_gfortran
    }

    function get_gf_lib {
        # Get library with no suffix
        get_gf_lib_for_suf "" $@
    }
fi
