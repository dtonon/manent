#!/usr/bin/env bash
# Strip the bundled mpv/ffmpeg media stack from the packaged Linux AppImage.
#
# Why: flutter_distributor's AppImage maker runs `ldd` on
# libmedia_kit_video_plugin.so and copies libmpv + its entire transitive
# ffmpeg/libplacebo/libass stack into the AppImage, then forces
# LD_LIBRARY_PATH=usr/lib. On systems where ffmpeg is split across packages
# (e.g. Fedora's base ffmpeg-free + RPM Fusion libavcodec-freeworld) `ldd`
# grabs a mismatched mix of libav* libraries. That inconsistent set aborts
# inside libmpv's option system on video playback:
#   m_config_cache_from_shadow: Assertion `group_index >= 0' failed.
#
# Removing these libs makes the AppImage fall back to the *system* libmpv,
# which is internally self-consistent and plays video correctly.
#
# Runtime requirement this introduces: the target machine must have libmpv
# installed  (Fedora: `mpv-libs`, Debian/Ubuntu: `libmpv2`).
#
# Usage: strip_bundled_mpv.sh <path-to.AppImage>   (defaults to dist/*/*-linux.AppImage)
set -euo pipefail

APPIMAGE="${1:-$(ls dist/*/*-linux.AppImage 2>/dev/null | head -1)}"
if [[ -z "${APPIMAGE}" || ! -f "${APPIMAGE}" ]]; then
  echo "strip_bundled_mpv: AppImage not found: '${APPIMAGE}'" >&2
  exit 1
fi
APPIMAGE="$(readlink -f "${APPIMAGE}")"

# Libraries to remove so they resolve to the system copies instead.
PATTERNS=(libmpv.so libavcodec.so libavdevice.so libavfilter.so libavformat.so \
  libavutil.so libswscale.so libswresample.so libpostproc.so libplacebo.so \
  libass.so libdav1d.so libvulkan.so)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}"

echo "strip_bundled_mpv: extracting ${APPIMAGE}"
"${APPIMAGE}" --appimage-extract >/dev/null

removed=0
for pat in "${PATTERNS[@]}"; do
  for f in squashfs-root/usr/lib/${pat}*; do
    [[ -e "${f}" ]] || continue
    rm -f "${f}"
    removed=$((removed + 1))
  done
done
echo "strip_bundled_mpv: removed ${removed} bundled media libs"

echo "strip_bundled_mpv: repacking"
ARCH="${ARCH:-x86_64}" appimagetool squashfs-root "${APPIMAGE}" >/dev/null 2>&1
chmod +x "${APPIMAGE}"
echo "strip_bundled_mpv: done -> ${APPIMAGE}"
