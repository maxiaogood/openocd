#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build OpenOCD for linux-x64 or windows-x64, statically linking third-party
# libraries whenever possible.
set -euo pipefail
set -x

TARGET="${1:?usage: build-static.sh <linux-x64|windows-x64>}"
: "${OPENOCD_SRC:?}"
: "${DL_DIR:?}"

MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
STAGING="${STAGING:-${PWD}/staging-${TARGET}}"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"

fix_capstone_pc() {
  local pc_file="$1"
  local prefix="$2"
  if [[ ! -f "${pc_file}" ]]; then
    return 0
  fi
  sed -i '/^prefix=/d;/^exec_prefix=/d;/^libdir=/d;/^includedir=/d;/^archive=/d' "${pc_file}"
  cat > "${pc_file}.hdr" <<EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/capstone

EOF
  cat "${pc_file}.hdr" "${pc_file}" > "${pc_file}.new"
  mv "${pc_file}.new" "${pc_file}"
  rm -f "${pc_file}.hdr"
}

package_tree() {
  local src_root="$1"
  mkdir -p "${STAGING}/bin" "${STAGING}/share"
  if [[ -d "${src_root}/bin" ]]; then
    cp -a "${src_root}/bin/." "${STAGING}/bin/"
  fi
  if [[ -d "${src_root}/share" ]]; then
    cp -a "${src_root}/share/." "${STAGING}/share/"
  fi
  # Static packages do not need development files or leftover import libs.
  rm -rf "${STAGING}/include" "${STAGING}/lib" "${STAGING}/lib64" \
    "${STAGING}/share/pkgconfig" "${STAGING}/bin/"*.dll
  find "${STAGING}" -name '*.la' -delete
  find "${STAGING}" -name '*.a' -delete
}

case "${TARGET}" in
  windows-x64)
    export HOST="x86_64-w64-mingw32"
    export BUILD_DIR="${BUILD_DIR:-${PWD}/../build-windows-x64}"
    export OPENOCD_TAG="${OPENOCD_TAG:-$(git -C "${OPENOCD_SRC}" rev-parse --short HEAD)}"
    export LIBUSB1_CONFIG="--enable-static --disable-shared"
    export HIDAPI_CONFIG="--enable-static --disable-shared --disable-testgui"
    export LIBFTDI_CONFIG="-DSTATICLIBS=ON -DBUILD_SHARED_LIBS=OFF -DEXAMPLES=OFF -DFTDI_EEPROM=OFF -DBUILD_TESTS=OFF -DCMAKE_INSTALL_LIBDIR=lib"
    export CAPSTONE_CONFIG="CAPSTONE_BUILD_CORE_ONLY=yes CAPSTONE_STATIC=yes CAPSTONE_SHARED=no"
    export LIBJAYLINK_CONFIG="--enable-static --disable-shared"
    export JIMTCL_CONFIG="--disable-shared --with-ext=json --minimal --disable-ssl"
    # Fully static MinGW binary: no extra runtime DLLs (WinUSB/HID stay as system DLLs).
    export OPENOCD_CONFIG="LDFLAGS=-static"
    export MAKE_JOBS
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"
    bash "${OPENOCD_SRC}/contrib/cross-build.sh" "${HOST}"
    package_tree "${BUILD_DIR}/${HOST}-root/usr"
    if [[ -f "${STAGING}/bin/openocd.exe" ]]; then
      "${HOST}-objdump" -p "${STAGING}/bin/openocd.exe" | grep -E 'DLL Name' || true
    fi
    ;;

  linux-x64)
    PREFIX="${PREFIX:-${PWD}/../deps-linux-x64}"
    BUILD_DIR="${BUILD_DIR:-${PWD}/../build-linux-x64}"
    rm -rf "${PREFIX}" "${BUILD_DIR}"
    mkdir -p "${PREFIX}" "${BUILD_DIR}"
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
    export CMAKE_PREFIX_PATH="${PREFIX}"
    export CPPFLAGS="-I${PREFIX}/include"
    export LDFLAGS="-L${PREFIX}/lib -static-libgcc"
    PKG_CONFIG_WRAP="${BUILD_DIR}/pkg-config-static"
    mkdir -p "${BUILD_DIR}"
    cat > "${PKG_CONFIG_WRAP}" <<'EOF'
#!/bin/sh
exec pkg-config --static "$@"
EOF
    chmod +x "${PKG_CONFIG_WRAP}"
    export PKG_CONFIG="${PKG_CONFIG_WRAP}"

    # libusb: static library; udev remains a system shared library (no static libudev on Ubuntu).
    mkdir -p "${BUILD_DIR}/libusb1"
    cd "${BUILD_DIR}/libusb1"
    "${LIBUSB1_SRC}/configure" --prefix="${PREFIX}" --enable-static --disable-shared
    make -j "${MAKE_JOBS}"
    make install

    mkdir -p "${BUILD_DIR}/hidapi"
    cd "${BUILD_DIR}/hidapi"
    "${HIDAPI_SRC}/configure" --prefix="${PREFIX}" --enable-static --disable-shared --disable-testgui
    make -j "${MAKE_JOBS}"
    make install

    mkdir -p "${BUILD_DIR}/libftdi"
    cd "${BUILD_DIR}/libftdi"
    cmake "${LIBFTDI_SRC}" \
      -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
      -DCMAKE_PREFIX_PATH="${PREFIX}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DPKG_CONFIG_EXECUTABLE="$(command -v pkg-config)" \
      -DSTATICLIBS=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DEXAMPLES=OFF \
      -DFTDI_EEPROM=OFF \
      -DBUILD_TESTS=OFF
    make -j "${MAKE_JOBS}"
    make install

    mkdir -p "${BUILD_DIR}/capstone"
    cd "${BUILD_DIR}/capstone"
    cp -a "${CAPSTONE_SRC}/." .
    make -j "${MAKE_JOBS}" PREFIX="${PREFIX}" \
      CAPSTONE_BUILD_CORE_ONLY=yes CAPSTONE_STATIC=yes CAPSTONE_SHARED=no
    make install PREFIX="${PREFIX}" \
      CAPSTONE_BUILD_CORE_ONLY=yes CAPSTONE_STATIC=yes CAPSTONE_SHARED=no
    fix_capstone_pc "${PREFIX}/lib/pkgconfig/capstone.pc" "${PREFIX}"

    mkdir -p "${BUILD_DIR}/libjaylink"
    cd "${BUILD_DIR}/libjaylink"
    "${LIBJAYLINK_SRC}/configure" --prefix="${PREFIX}" --enable-static --disable-shared
    make -j "${MAKE_JOBS}"
    make install

    mkdir -p "${BUILD_DIR}/jimtcl"
    cd "${BUILD_DIR}/jimtcl"
    "${JIMTCL_SRC}/configure" --prefix="${PREFIX}" --disable-shared \
      --with-ext=json --minimal --disable-ssl
    make -j "${MAKE_JOBS}"
    make install

    mkdir -p "${BUILD_DIR}/openocd"
    cd "${BUILD_DIR}/openocd"
    "${OPENOCD_SRC}/configure" --prefix=/usr
    make -j "${MAKE_JOBS}"
    make install-strip DESTDIR="${BUILD_DIR}/openocd-root"
    package_tree "${BUILD_DIR}/openocd-root/usr"
    file "${STAGING}/bin/openocd"
    ldd "${STAGING}/bin/openocd" || true
    ;;

  *)
    echo "unknown target: ${TARGET}" >&2
    exit 1
    ;;
esac
