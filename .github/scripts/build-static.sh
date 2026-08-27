#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build OpenOCD for linux/windows x64 and arm64, statically linking
# third-party libraries whenever possible.
set -euo pipefail
set -x

TARGET="${1:?usage: build-static.sh <linux-x64|linux-arm64|windows-x64|windows-arm64>}"
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

# Static linking needs Libs.private, so force --static on every pkg-config
# invocation, including the ones cmake and cross-build.sh make on their own.
setup_pkgconfig_shim() {
  local shim_dir="$1"
  local real_pkg_config
  real_pkg_config="$(command -v pkg-config)"
  mkdir -p "${shim_dir}"
  cat > "${shim_dir}/pkg-config" <<EOF
#!/bin/sh
exec ${real_pkg_config} --static "\$@"
EOF
  chmod +x "${shim_dir}/pkg-config"
  export PATH="${shim_dir}:${PATH}"
}

ensure_libftdi_mingw_toolchain() {
  local host="$1"
  local f="${LIBFTDI_SRC}/cmake/Toolchain-${host}.cmake"
  if [[ -f "${f}" ]]; then
    return 0
  fi
  cat > "${f}" <<EOF
SET(CMAKE_SYSTEM_NAME Windows)
SET(CMAKE_C_COMPILER ${host}-gcc)
SET(CMAKE_CXX_COMPILER ${host}-g++)
SET(CMAKE_RC_COMPILER ${host}-windres)
SET(CMAKE_FIND_ROOT_PATH /placeholder)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
}

# llvm-mingw is Clang; GCC-only flags such as -mwin32 (injected by libusb)
# must be stripped or the Windows ARM64 build dies.
setup_clang_flag_filter() {
  local host="$1"
  local wrap_dir="$2"
  local real_cc real_cxx
  real_cc="$(command -v "${host}-gcc")"
  real_cxx="$(command -v "${host}-g++")"
  mkdir -p "${wrap_dir}"
  cat > "${wrap_dir}/${host}-gcc" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in
    -mwin32|-static-libgcc) continue ;;
  esac
  args+=("\$a")
done
exec "${real_cc}" "\${args[@]}"
EOF
  cat > "${wrap_dir}/${host}-g++" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in
    -mwin32|-static-libgcc) continue ;;
  esac
  args+=("\$a")
done
exec "${real_cxx}" "\${args[@]}"
EOF
  chmod +x "${wrap_dir}/${host}-gcc" "${wrap_dir}/${host}-g++"
  export PATH="${wrap_dir}:${PATH}"
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

build_windows() {
  local host="$1"
  export HOST="${host}"
  export BUILD_DIR="${BUILD_DIR:-${PWD}/../build-${TARGET}}"
  export OPENOCD_TAG="${OPENOCD_TAG:-$(git -C "${OPENOCD_SRC}" rev-parse --short HEAD)}"
  export LIBUSB1_CONFIG="--enable-static --disable-shared"
  export HIDAPI_CONFIG="--enable-static --disable-shared --disable-testgui"
  export LIBFTDI_CONFIG="-DSTATICLIBS=OFF -DLIB_SUFFIX= -DEXAMPLES=OFF -DFTDI_EEPROM=OFF -DBUILD_TESTS=OFF -DDOCUMENTATION=OFF -DFTDIPP=OFF -DPYTHON_BINDINGS=OFF"
  export CAPSTONE_CONFIG="CAPSTONE_BUILD_CORE_ONLY=yes CAPSTONE_STATIC=yes CAPSTONE_SHARED=no"
  export LIBJAYLINK_CONFIG="--enable-static --disable-shared"
  export JIMTCL_CONFIG="--disable-shared --with-ext=json --minimal --disable-ssl"
  # Fully static MinGW binary: no extra runtime DLLs (WinUSB/HID stay as system DLLs).
  export OPENOCD_CONFIG="LDFLAGS=-static"
  export MAKE_JOBS
  ensure_libftdi_mingw_toolchain "${host}"
  mkdir -p "${BUILD_DIR}"
  setup_pkgconfig_shim "${BUILD_DIR}/pkgconfig-shim"
  if "${host}-gcc" --version 2>/dev/null | grep -qi clang; then
    setup_clang_flag_filter "${host}" "${BUILD_DIR}/clang-flag-filter"
  fi
  cd "${BUILD_DIR}"
  bash "${OPENOCD_SRC}/contrib/cross-build.sh" "${host}"
  package_tree "${BUILD_DIR}/${host}-root/usr"
  if [[ -f "${STAGING}/bin/openocd.exe" ]]; then
    "${host}-objdump" -p "${STAGING}/bin/openocd.exe" | grep -E 'DLL Name' || true
  fi
}

build_linux_native() {
  PREFIX="${PREFIX:-${PWD}/../deps-${TARGET}}"
  BUILD_DIR="${BUILD_DIR:-${PWD}/../build-${TARGET}}"
  rm -rf "${PREFIX}" "${BUILD_DIR}"
  mkdir -p "${PREFIX}" "${BUILD_DIR}"
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
  export CMAKE_PREFIX_PATH="${PREFIX}"
  export CPPFLAGS="-I${PREFIX}/include"
  export LDFLAGS="-L${PREFIX}/lib -static-libgcc"
  setup_pkgconfig_shim "${BUILD_DIR}/pkgconfig-shim"
  export PKG_CONFIG="${BUILD_DIR}/pkgconfig-shim/pkg-config"

  # libusb: static library; udev remains a system shared library (no static libudev on Ubuntu).
  mkdir -p "${BUILD_DIR}/libusb1"
  cd "${BUILD_DIR}/libusb1"
  "${LIBUSB1_SRC}/configure" --prefix="${PREFIX}" \
    --enable-static --disable-shared --with-pic
  make -j "${MAKE_JOBS}"
  make install

  mkdir -p "${BUILD_DIR}/hidapi"
  cd "${BUILD_DIR}/hidapi"
  "${HIDAPI_SRC}/configure" --prefix="${PREFIX}" \
    --enable-static --disable-shared --disable-testgui --with-pic
  make -j "${MAKE_JOBS}"
  make install

  mkdir -p "${BUILD_DIR}/libftdi"
  cd "${BUILD_DIR}/libftdi"
  cmake "${LIBFTDI_SRC}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DPKG_CONFIG_EXECUTABLE="${PKG_CONFIG}" \
    -DLIB_SUFFIX= \
    -DSTATICLIBS=OFF \
    -DEXAMPLES=OFF \
    -DFTDI_EEPROM=OFF \
    -DFTDIPP=OFF \
    -DPYTHON_BINDINGS=OFF \
    -DBUILD_TESTS=OFF \
    -DDOCUMENTATION=OFF
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
  "${LIBJAYLINK_SRC}/configure" --prefix="${PREFIX}" \
    --enable-static --disable-shared --with-pic
  make -j "${MAKE_JOBS}"
  make install

  mkdir -p "${BUILD_DIR}/jimtcl"
  cd "${BUILD_DIR}/jimtcl"
  "${JIMTCL_SRC}/configure" --prefix="${PREFIX}" --disable-shared \
    --with-ext=json --minimal --disable-ssl
  make -j "${MAKE_JOBS}"
  make install

  # Leave the linker no choice but the static archives.
  rm -f "${PREFIX}"/lib/*.so "${PREFIX}"/lib/*.so.*

  mkdir -p "${BUILD_DIR}/openocd"
  cd "${BUILD_DIR}/openocd"
  "${OPENOCD_SRC}/configure" --prefix=/usr
  make -j "${MAKE_JOBS}"
  make install-strip DESTDIR="${BUILD_DIR}/openocd-root"
  package_tree "${BUILD_DIR}/openocd-root/usr"
  file "${STAGING}/bin/openocd"
  ldd "${STAGING}/bin/openocd" || true
}

case "${TARGET}" in
  windows-x64)
    build_windows x86_64-w64-mingw32
    ;;
  windows-arm64)
    build_windows aarch64-w64-mingw32
    ;;
  linux-x64|linux-arm64)
    build_linux_native
    ;;
  *)
    echo "unknown target: ${TARGET}" >&2
    exit 1
    ;;
esac
