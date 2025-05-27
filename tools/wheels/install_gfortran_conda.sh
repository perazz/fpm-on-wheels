#!/usr/bin/env bash
set -euxo pipefail

# Use the build environment provided by cibuildwheel (already activated)
micromamba install -y -n "$CONDA_DEFAULT_ENV" \
  gfortran_impl_osx-64=14.2.0 \
  libgfortran5=14.2.0
