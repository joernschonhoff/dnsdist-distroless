#!/bin/bash
set -v
set -e

test -n "${QUICHE_VERSION}" || { echo "ERROR: QUICHE_VERSION is not set"; exit 1; }

for _libdir in "/usr/lib/x86_64-linux-gnu" "/usr/lib/aarch64-linux-gnu" "/usr/lib64" "/usr/lib"; do
    if [ -f "${_libdir}/libc.so.6" ]; then
        LIBDIR="${_libdir}"
        break
    fi
done
test -n "${LIBDIR}" || { echo "ERROR: could not detect LIBDIR"; exit 1; }
RUST_BACKTRACE=1 cargo build --release --no-default-features --features ffi,boringssl-boring-crate --package quiche

cat > target/release/quiche.pc <<EOF
# quiche
Name: quiche
Description: quiche library
URL: https://github.com/cloudflare/quiche
Version: ${QUICHE_VERSION}
Cflags: -I/usr/include
Libs: -L${LIBDIR} -lquiche
EOF

mkdir -p \
    /quiche_lib/usr/include \
    /quiche_lib${LIBDIR} \
    /quiche_lib${LIBDIR}/pkgconfig/

install -m644 quiche/include/quiche.h /quiche_lib/usr/include/
install -m755 target/release/libquiche.so /quiche_lib${LIBDIR}/libquiche.so.0
ln -s libquiche.so.0 /quiche_lib${LIBDIR}/libquiche.so
install -m644 target/release/quiche.pc /quiche_lib${LIBDIR}/pkgconfig/