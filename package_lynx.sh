#!/bin/bash
# package_lynx.sh
# Creates a tar.gz of out/lynx-kernel suitable for use by the APKBUILD.
# Optionally starts a local HTTP server on port 8080 to serve it.
#
# Usage:
#   ./package_lynx.sh          # create tarball only
#   ./package_lynx.sh --serve  # create tarball and serve via HTTP
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/out/lynx-kernel"
PKGVER="6.1.124"
PKGNAME="linux-google-lynx"
TARNAME="${PKGNAME}-${PKGVER}.tar.gz"
OUT="${SCRIPT_DIR}/${TARNAME}"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: $SRC does not exist. Run ./extract_lynx.sh first."
    exit 1
fi

echo "Cleaning up build artifacts from source tree..."
find "${SRC}" -name ".config" -delete || true
rm -rf "${SRC}/include/config" || true
rm -rf "${SRC}/include/generated" || true
find "${SRC}" -name "generated" -type d -path "*/arch/*/include/generated" -exec rm -rf {} + || true

echo "Creating ${TARNAME} from ${SRC} ..."
echo "This may take a few minutes for a ~4.6G source tree..."

# Create tar with the directory named linux-google-lynx-<version> inside
tar --create \
    --use-compress-program=pigz \
    --file="${OUT}" \
    --transform="s|^out/lynx-kernel|${PKGNAME}-${PKGVER}|" \
    --exclude="*/.config" \
    --exclude="*/include/config" \
    --exclude="*/include/generated" \
    --exclude="*/arch/*/include/generated" \
    --exclude="*.a" \
    --exclude="*.cmd" \
    --exclude="*.o" \
    --exclude="*.ko" \
    --exclude=".tmp_versions" \
    --exclude="*.mod" \
    --exclude="modules.order" \
    --exclude="Module.symvers" \
    -C "${SCRIPT_DIR}" \
    out/lynx-kernel

echo "Done: ${OUT}"
echo "Size: $(du -sh "${OUT}" | cut -f1)"
echo ""
echo "SHA-512:"
sha512sum "${OUT}"
echo ""

if [[ "$1" == "--serve" ]]; then
    echo "Serving on http://localhost:8080 ..."
    echo "Press Ctrl+C to stop."
    cd "${SCRIPT_DIR}"
    python3 -m http.server 8080
fi
