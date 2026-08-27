#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Download and unpack OpenOCD third-party sources used by the x64 static builds.
set -euo pipefail

: "${DL_DIR:?DL_DIR must be set}"
mkdir -p "${DL_DIR}"
cd "${DL_DIR}"

LIBUSB1_VER="${LIBUSB1_VER:-1.0.26}"
HIDAPI_VER="${HIDAPI_VER:-0.13.1}"
LIBFTDI_VER="${LIBFTDI_VER:-1.5}"
CAPSTONE_VER="${CAPSTONE_VER:-4.0.2}"
LIBJAYLINK_VER="${LIBJAYLINK_VER:-0.3.1}"
JIMTCL_VER="${JIMTCL_VER:-0.83}"

wget -nv -O "libusb-${LIBUSB1_VER}.tar.bz2" \
  "https://github.com/libusb/libusb/releases/download/v${LIBUSB1_VER}/libusb-${LIBUSB1_VER}.tar.bz2"
tar -xjf "libusb-${LIBUSB1_VER}.tar.bz2"
LIBUSB1_SRC="${DL_DIR}/libusb-${LIBUSB1_VER}"

wget -nv -O "hidapi-${HIDAPI_VER}.tar.gz" \
  "https://github.com/libusb/hidapi/archive/hidapi-${HIDAPI_VER}.tar.gz"
tar -xzf "hidapi-${HIDAPI_VER}.tar.gz"
HIDAPI_SRC="${DL_DIR}/hidapi-hidapi-${HIDAPI_VER}"
( cd "${HIDAPI_SRC}" && ./bootstrap )

wget -nv -O "libftdi1-${LIBFTDI_VER}.tar.bz2" \
  "https://www.intra2net.com/en/developer/libftdi/download/libftdi1-${LIBFTDI_VER}.tar.bz2"
tar -xjf "libftdi1-${LIBFTDI_VER}.tar.bz2"
LIBFTDI_SRC="${DL_DIR}/libftdi1-${LIBFTDI_VER}"
# libftdi always adds a shared 'ftdi1' target regardless of BUILD_SHARED_LIBS,
# and linking it against a static libusb fails. Build the only target as static
# instead; STATICLIBS must then stay OFF to avoid two targets named libftdi1.a.
sed -i 's/add_library(ftdi1 SHARED/add_library(ftdi1 STATIC/' \
  "${LIBFTDI_SRC}/src/CMakeLists.txt"
grep -q 'add_library(ftdi1 STATIC' "${LIBFTDI_SRC}/src/CMakeLists.txt"

wget -nv -O "capstone-${CAPSTONE_VER}.tar.gz" \
  "https://github.com/aquynh/capstone/archive/${CAPSTONE_VER}.tar.gz"
tar -xzf "capstone-${CAPSTONE_VER}.tar.gz"
CAPSTONE_SRC="${DL_DIR}/capstone-${CAPSTONE_VER}"

wget -nv -O "libjaylink-${LIBJAYLINK_VER}.tar.gz" \
  "https://gitlab.zapb.de/libjaylink/libjaylink/-/archive/${LIBJAYLINK_VER}/libjaylink-${LIBJAYLINK_VER}.tar.gz"
tar -xzf "libjaylink-${LIBJAYLINK_VER}.tar.gz"
LIBJAYLINK_SRC="${DL_DIR}/libjaylink-${LIBJAYLINK_VER}"
( cd "${LIBJAYLINK_SRC}" && ./autogen.sh )

wget -nv -O "jimtcl-${JIMTCL_VER}.tar.gz" \
  "https://github.com/msteveb/jimtcl/archive/refs/tags/${JIMTCL_VER}.tar.gz"
tar -xzf "jimtcl-${JIMTCL_VER}.tar.gz"
JIMTCL_SRC="${DL_DIR}/jimtcl-${JIMTCL_VER}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "LIBUSB1_SRC=${LIBUSB1_SRC}"
    echo "HIDAPI_SRC=${HIDAPI_SRC}"
    echo "LIBFTDI_SRC=${LIBFTDI_SRC}"
    echo "CAPSTONE_SRC=${CAPSTONE_SRC}"
    echo "LIBJAYLINK_SRC=${LIBJAYLINK_SRC}"
    echo "JIMTCL_SRC=${JIMTCL_SRC}"
  } >> "${GITHUB_ENV}"
fi
