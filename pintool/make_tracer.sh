#!/bin/bash
# Build both ChampSim pintools.
#
# PIN_ROOT and ZSTD_HOME may be overridden from the environment; the defaults
# below are the lab host's paths and will not exist elsewhere. ZSTD_HOME must
# contain include/zstd.h and lib/libzstd.a (symlinks to a system zstd work).
#
#   PIN_ROOT=/path/to/pin-4.0-kit ZSTD_HOME=/path/to/zstd bash make_tracer.sh
#
# Note: a conda environment exports CXX/CXXFLAGS that PIN propagates into its
# own compiler wrapper, which breaks the build. Strip them if that applies:
#   env -u CXX -u CC -u CXXFLAGS -u CFLAGS -u CPPFLAGS -u LDFLAGS bash make_tracer.sh
set -e

export PIN_ROOT="${PIN_ROOT:-/home/rahbera/softwares/pin-external-4.0-99633-g5ca9893f2-gcc-linux}"
export ZSTD_HOME="${ZSTD_HOME:-/home/rahbera/local}"

if [ ! -e "$PIN_ROOT/source/include/pin/pin.H" ]; then
  echo "make_tracer.sh: PIN_ROOT does not look like a PIN kit: $PIN_ROOT" >&2
  echo "  set PIN_ROOT to your Intel PIN 4.0 kit and re-run" >&2
  exit 1
fi
if [ ! -e "$ZSTD_HOME/include/zstd.h" ] || [ ! -e "$ZSTD_HOME/lib/libzstd.a" ]; then
  echo "make_tracer.sh: ZSTD_HOME must contain include/zstd.h and lib/libzstd.a: $ZSTD_HOME" >&2
  exit 1
fi

mkdir -p obj-intel64
make obj-intel64/champsim_tracer_mt_roi_v2.so
make obj-intel64/champsim_tracer_mt_roi_v3.so
