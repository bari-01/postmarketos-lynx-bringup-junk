#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# extract_lynx.sh — Extract Lynx (Pixel 7a) kernel sources into a traditional
# make-buildable tree suitable for postmarketOS packaging.
#
# Usage:
#   ./extract_lynx.sh [output_dir]
#
# Output structure:
#   <output_dir>/
#   ├── arch/arm64/configs/lynx_defconfig   (merged defconfig)
#   ├── Kconfig.ext                         (rewritten with relative paths)
#   ├── google-modules/                     (vendor modules)
#   ├── device-trees/gs201/                 (SoC device trees)
#   ├── device-trees/lynx/                  (device overlay trees)
#   └── ...                                 (full kernel source)
#
# Then build with:
#   cd <output_dir>
#   make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- lynx_defconfig
#   make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}"
OUT="${1:-${SCRIPT_DIR}/out/lynx-kernel}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[extract]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# Verify we're in the right directory
[[ -d "${SRC}/aosp/arch" ]] || die "Cannot find aosp/arch — run from the kernel repo root"
[[ -d "${SRC}/private/devices/google/lynx" ]] || die "Cannot find private/devices/google/lynx"

# Clean output
if [[ -d "${OUT}" ]]; then
    warn "Output directory ${OUT} already exists, removing..."
    rm -rf "${OUT}"
fi

########################################################################
# 1. Copy kernel source tree
########################################################################
log "Copying kernel source tree (aosp/ → ${OUT})..."
mkdir -p "${OUT}"
rsync -a --exclude='.git' "${SRC}/aosp/" "${OUT}/"

########################################################################
# 2. Copy vendor modules
########################################################################
log "Copying vendor modules (private/google-modules/ → google-modules/)..."
mkdir -p "${OUT}/google-modules"
rsync -a --exclude='.git' "${SRC}/private/google-modules/" "${OUT}/google-modules/"

########################################################################
# 2b. Rewrite Kconfig paths inside vendor modules
########################################################################
log "Rewriting Kconfig paths inside vendor modules..."
# The Kconfig files inside google-modules/soc/gs/ use $(KCONFIG_SOC_GS_PREFIX)
# for nested source directives. These need to resolve from the kernel root.
kconfig_count=0
while IFS= read -r -d '' kf; do
    if grep -q 'KCONFIG_SOC_GS_PREFIX\|KCONFIG_EXT_MODULES_PREFIX' "$kf"; then
        sed -i \
            -e 's|\$(KCONFIG_SOC_GS_PREFIX)|google-modules/soc/gs/|g' \
            -e 's|\$(KCONFIG_EXT_MODULES_PREFIX)private/google-modules/|google-modules/|g' \
            "$kf"
        ((kconfig_count++)) || true
    fi
done < <(find "${OUT}/google-modules" -name 'Kconfig' -print0)
log "  → Rewrote ${kconfig_count} Kconfig files"

########################################################################
# 2c. Rewrite cross-module include/symver paths in Kbuild/Makefile files
########################################################################
log "Rewriting cross-module build paths in Kbuild/Makefile files..."
# In the original repo layout, vendor modules reference each other via:
#   $(srctree)/../private/google-modules/   (srctree = aosp/)
#   $(KERNEL_SRC)/../private/google-modules/
#   $(OUT_DIR)/../private/google-modules/
#   $(O)/../private/google-modules/
# In the extracted tree, srctree IS the kernel root, so these become:
#   $(srctree)/google-modules/
#   $(KERNEL_SRC)/google-modules/
#   $(OUT_DIR)/../google-modules/  (OUT_DIR is a build subdir, keep relative)
#   $(O)/../google-modules/
kbuild_count=0
while IFS= read -r -d '' bf; do
    if grep -qE 'private/google-modules|KERNEL_SRC|KBUILD_SRC' "$bf"; then
        sed -i \
            -e 's|\$(srctree)/../private/google-modules/|\$(srctree)/google-modules/|g' \
            -e 's|\$(KERNEL_SRC)/../private/google-modules/|\$(srctree)/google-modules/|g' \
            -e 's|\$(OUT_DIR)/../private/google-modules/|\$(OUT_DIR)/../google-modules/|g' \
            -e 's|\$(O)/../private/google-modules/|\$(O)/../google-modules/|g' \
            -e 's|\$(KERNEL_SRC)/drivers/|\$(srctree)/drivers/|g' \
            -e 's|\$(KBUILD_SRC)/drivers/|\$(srctree)/drivers/|g' \
            -e 's|\$(KERNEL_SRC)/\$(M)|\$(srctree)/\$(src)|g' \
            -e 's|\$(KBUILD_SRC)/\$(M)|\$(srctree)/\$(src)|g' \
            "$bf"
        ((kbuild_count++)) || true
    fi
done < <(find "${OUT}/google-modules" \( -name 'Kbuild' -o -name 'Makefile' \) -print0)
log "  → Rewrote ${kbuild_count} Kbuild/Makefile files"

########################################################################
# 2d. Apply Clang 22 compatibility patches
########################################################################
log "Applying Clang 22 compatibility patches..."
patch_count=0

# --- Patch 1: Fix typecheck() macro in include/linux/typecheck.h ---
# New Clang errors on: typeof(x) __dummy2; when x is const-qualified
# Fix: initialize __dummy2 to zero
sed -i 's|typeof(x) __dummy2;|typeof(x) __dummy2 = (typeof(x))0;|' \
    "${OUT}/include/linux/typecheck.h"
((patch_count++)) || true

# --- Patch 2: Add -Wno- flags to Makefile for remaining const-init warnings ---
# Clang 22 adds -Wdefault-const-init-field-unsafe (shmem.c, params.c, v4l2-ioctl.c)
# and -Wuninitialized-const-pointer (kvm/sys_regs.c)
sed -i '/KBUILD_CFLAGS += $(call cc-disable-warning, dangling-pointer)/a\
KBUILD_CFLAGS += $(call cc-disable-warning, default-const-init-field-unsafe)\
KBUILD_CFLAGS += $(call cc-disable-warning, uninitialized-const-pointer)' \
    "${OUT}/Makefile"
((patch_count++)) || true

# --- Patch 3: Fix libbpf const ---
sed -i 's/char[[:space:]]*\*next_path;/const char *next_path;/' \
"$OUT/tools/lib/bpf/libbpf.c"
((patch_count++)) || true

# --- Patch 4: Fix enum mismatch in phy-exynos-usb3p1.c ---
# Function takes enum exynos_usbcon_ssp_cr but compares against
# USBCON_CR_WRITE/USBCON_CR_READ from the wrong enum (same values: 18,19)
sed -i \
    -e 's|cr_op == USBCON_CR_WRITE|cr_op == USBCON_CR_SSP_WRITE|g' \
    -e 's|cr_op == USBCON_CR_READ|cr_op == USBCON_CR_SSP_READ|g' \
    -e 's|cr_op==USBCON_CR_READ|cr_op == USBCON_CR_SSP_READ|g' \
    "${OUT}/google-modules/soc/gs/drivers/phy/samsung/phy-exynos-usb3p1.c"
((patch_count++)) || true

log "  → Applied ${patch_count} Clang 22 compatibility patches"
########################################################################
# 3. Copy device trees
########################################################################
log "Copying device trees..."
mkdir -p "${OUT}/device-trees"

# GS201 SoC device trees
rsync -a --exclude='.git' "${SRC}/private/devices/google/gs201/dts/" "${OUT}/device-trees/gs201/"

# Lynx device overlay trees (resolve the gs201 symlink)
rsync -a -L --exclude='.git' "${SRC}/private/devices/google/lynx/dts/" "${OUT}/device-trees/lynx/"

# Copy SoC dt-bindings include directory
if [[ -d "${SRC}/private/google-modules/soc/gs/include/dt-bindings" ]]; then
    log "Copying SoC dt-bindings..."
    mkdir -p "${OUT}/google-modules/soc/gs/include"
    rsync -a "${SRC}/private/google-modules/soc/gs/include/dt-bindings/" \
             "${OUT}/google-modules/soc/gs/include/dt-bindings/"
fi

# Also copy the DTC include path used by the build
if [[ -d "${SRC}/private/google-modules/soc/gs/include/dtc" ]]; then
    rsync -a "${SRC}/private/google-modules/soc/gs/include/dtc/" \
             "${OUT}/google-modules/soc/gs/include/dtc/"
fi

########################################################################
# 4. Merge defconfig
########################################################################
log "Merging defconfig fragments..."
DEFCONFIG="${OUT}/arch/arm64/configs/lynx_defconfig"

{
    echo "# Merged defconfig for Google Pixel 7a (Lynx)"
    echo "# Generated by extract_lynx.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Base: gki_defconfig + gs201_defconfig + lynx_defconfig"
    echo "#"
    echo ""
    echo "########################################################################"
    echo "# GKI base config (arch/arm64/configs/gki_defconfig)"
    echo "########################################################################"
    cat "${SRC}/aosp/arch/arm64/configs/gki_defconfig"
    echo ""
    echo "########################################################################"
    echo "# GS201 SoC config (gs201_defconfig)"
    echo "########################################################################"
    cat "${SRC}/private/devices/google/gs201/gs201_defconfig"
    echo ""
    echo "########################################################################"
    echo "# Lynx device config (lynx_defconfig)"
    echo "########################################################################"
    cat "${SRC}/private/devices/google/lynx/lynx_defconfig"
} > "${DEFCONFIG}"

log "  → Created $(wc -l < "${DEFCONFIG}") line merged defconfig"

########################################################################
# 5. Rewrite Kconfig.ext
########################################################################
log "Generating Kconfig.ext..."
KCONFIG_EXT="${OUT}/Kconfig.ext"

{
    echo "# SPDX-License-Identifier: GPL-2.0"
    echo "# Generated Kconfig.ext for Lynx (Pixel 7a)"
    echo "# Merges Kconfig.ext.gs201 + Kconfig.ext.lynx with resolved paths"
    echo "#"
    echo "# The KCONFIG_SOC_GS_PREFIX sources are rewritten to google-modules/soc/gs/"
    echo "# The KCONFIG_EXT_MODULES_PREFIX sources are rewritten to google-modules/"
    echo ""
    echo "# ---- From Kconfig.ext.gs201 ----"
    echo ""

    # Process Kconfig.ext.gs201: rewrite KCONFIG_SOC_GS_PREFIX and KCONFIG_EXT_MODULES_PREFIX
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            echo "$line"
        elif [[ "$line" =~ \$\(KCONFIG_SOC_GS_PREFIX\) ]]; then
            # e.g. source "$(KCONFIG_SOC_GS_PREFIX)drivers/X/Kconfig"
            rewritten="${line//\$(KCONFIG_SOC_GS_PREFIX)/google-modules/soc/gs/}"
            echo "$rewritten"
        elif [[ "$line" =~ \$\(KCONFIG_EXT_MODULES_PREFIX\) ]]; then
            # e.g. source "$(KCONFIG_EXT_MODULES_PREFIX)private/google-modules/X/Kconfig"
            rewritten="${line//\$(KCONFIG_EXT_MODULES_PREFIX)private\/google-modules\//google-modules/}"
            echo "$rewritten"
        else
            echo "$line"
        fi
    done < "${SRC}/private/devices/google/gs201/Kconfig.ext.gs201"

    echo ""
    echo "# ---- From Kconfig.ext.lynx (device-specific additions) ----"
    echo ""

    # Process Kconfig.ext.lynx — only lines not already covered by gs201
    # (The lynx Kconfig.ext has radio/s5300 and touch/common which are already in gs201's)
    already_sourced=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            continue
        elif [[ "$line" =~ \$\(KCONFIG_EXT_MODULES_PREFIX\) ]]; then
            rewritten="${line//\$(KCONFIG_EXT_MODULES_PREFIX)private\/google-modules\//google-modules/}"
            # Check if this was already in gs201's Kconfig.ext
            if ! grep -qF "$rewritten" "${KCONFIG_EXT}" 2>/dev/null; then
                echo "$rewritten"
            else
                echo "# (already sourced above) $rewritten"
            fi
        fi
    done < "${SRC}/private/devices/google/lynx/Kconfig.ext.lynx"

} > "${KCONFIG_EXT}"

log "  → Created Kconfig.ext with $(grep -c '^source' "${KCONFIG_EXT}") source directives"

########################################################################
# 6. Copy additional device config files
########################################################################
log "Copying device config files..."

# vendor_ramdisk modules list
mkdir -p "${OUT}/device-config"
for f in \
    "${SRC}/private/devices/google/gs201/vendor_ramdisk.modules.gs201" \
    "${SRC}/private/devices/google/lynx/vendor_ramdisk.modules.lynx" \
    "${SRC}/private/devices/google/gs201/vendor_dlkm.blocklist.gs201" \
    "${SRC}/private/devices/google/lynx/vendor_dlkm.blocklist.lynx" \
; do
    [[ -f "$f" ]] && cp "$f" "${OUT}/device-config/"
done

# Copy insmod configs
if [[ -d "${SRC}/private/devices/google/lynx/insmod_cfg" ]]; then
    rsync -a "${SRC}/private/devices/google/lynx/insmod_cfg/" "${OUT}/device-config/insmod_cfg/"
fi
if [[ -d "${SRC}/private/devices/google/gs201/insmod_cfg" ]]; then
    rsync -a "${SRC}/private/devices/google/gs201/insmod_cfg/" "${OUT}/device-config/insmod_cfg/"
fi

########################################################################
# 7. Strip Bazel/Kleaf artifacts
########################################################################
log "Cleaning up Bazel/Kleaf artifacts..."
find "${OUT}" -name 'BUILD.bazel' -delete
find "${OUT}" -name '*.bzl' -delete
find "${OUT}" -name '.bazelrc' -delete
find "${OUT}" -name 'WORKSPACE' -delete
find "${OUT}" -name 'MODULE.bazel' -delete

# ########################################################################
# 8. Integrate vendor modules into build system
# ########################################################################
log "Integrating vendor modules into build system..."
KBUILD_EXT="${OUT}/google-modules/Kbuild"
{
    echo "# SPDX-License-Identifier: GPL-2.0"
    echo "# Generated Kbuild for Google vendor modules"
    echo ""
    for d in "${OUT}/google-modules"/*/; do
        moddir=$(basename "$d")
        # Skip directories without Kconfig/Makefile/Kbuild if any
        if [[ -f "${d}Kconfig" || -f "${d}Makefile" || -f "${d}Kbuild" ]]; then
            echo "obj-y += ${moddir}/"
        fi
    done
} > "${KBUILD_EXT}"

# Hook into root Makefile
if ! grep -q "google-modules/" "${OUT}/Makefile"; then
    log "Hooking google-modules/ into root Makefile..."
    # Add after core-y/drivers-y definitions
    sed -i '/drivers-y[[:space:]]*:=/a \
drivers-y	+= google-modules/' "${OUT}/Makefile"
fi

########################################################################
# 9. Generate build instructions
########################################################################
log "Generating README..."
cat > "${OUT}/README.postmarketos.md" << 'READMEEOF'
# Lynx (Pixel 7a) Kernel — postmarketOS Build

Extracted from Google's Bazel/Kleaf kernel tree into a traditional
make-buildable form.

## Kernel Version

- **Base**: Linux 6.1.124 (android14-6.1 GKI)
- **SoC**: Google Tensor G2 (GS201)
- **Device**: Google Pixel 7a (Lynx)

## Quick Build

```bash
# Configure
make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- lynx_defconfig

# Build kernel + in-tree modules
make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs

# Install modules
make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH=/path/to/install modules_install
```

## Building Vendor Modules (Out-of-Tree)

The Google vendor modules are in `google-modules/`. The main SoC module
tree is at `google-modules/soc/gs/`:

```bash
# Build SoC modules (after building the kernel)
make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- \
    M=google-modules/soc/gs modules
```

Each vendor module subdirectory generally supports the standard external
module build interface (`make M=...`).

## Kconfig

The `Kconfig.ext` file at the kernel root sources Kconfig files from
the vendor modules in `google-modules/`. This allows `make *config` to
see the vendor module configuration options.

The build system sets `KCONFIG_EXT_PREFIX` so the kernel's root Kconfig
can source our Kconfig.ext.

## Device Trees

Device trees are in `device-trees/`:
- `device-trees/gs201/` — SoC-level device trees
- `device-trees/lynx/` — Device-specific overlays

These need to be built separately or integrated into the kernel's DTS
build system.

## postmarketOS APKBUILD

For a postmarketOS APKBUILD, use something like:

```bash
_flavor="google-lynx"
_config="config-${_flavor}.${_carch}"
# ...
build() {
    unset LDFLAGS
    make ARCH=arm64 LLVM=1 CC=clang \
        CROSS_COMPILE=aarch64-linux-gnu- \
        lynx_defconfig
    make ARCH=arm64 LLVM=1 CC=clang \
        CROSS_COMPILE=aarch64-linux-gnu- \
        -j"${JOBS}" Image modules dtbs
}
```
READMEEOF

########################################################################
# Done
########################################################################
log ""
log "Extraction complete!"
log ""
log "Output: ${OUT}"
log "  Kernel source:   ${OUT}/"
log "  Merged defconfig: ${OUT}/arch/arm64/configs/lynx_defconfig"
log "  Kconfig.ext:      ${OUT}/Kconfig.ext"
log "  Vendor modules:   ${OUT}/google-modules/"
log "  Device trees:     ${OUT}/device-trees/"
log "  Device config:    ${OUT}/device-config/"
log ""
log "To build:"
log "  cd ${OUT}"
log "  make ARCH=arm64 LLVM=1 lynx_defconfig"
log "  make ARCH=arm64 LLVM=1 -j\$(nproc) Image modules dtbs"
