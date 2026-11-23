#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/readingpen-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/readingpen-swift-cache"
build_path="${TMPDIR:-/tmp}/readingpen-build"
package_stage=$(mktemp -d "${TMPDIR:-/tmp}/pen-package.XXXXXX")
trap 'rm -rf "$package_stage"' EXIT
app_dir="$package_stage/点读包转换.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

typeset -a app_slices cli_slices
for architecture in arm64 x86_64; do
    build_args=(--disable-sandbox --cache-path "${TMPDIR:-/tmp}/readingpen-cache"
        --scratch-path "$build_path-$architecture" --triple "$architecture-apple-macosx14.0"
        -c release -debug-info-format none)
    swift build "${build_args[@]}"
    binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
    app_slices+=("$binary_dir/PenMac")
    cli_slices+=("$binary_dir/penconvert")
done
lipo -create "${app_slices[@]}" -output "$app_dir/Contents/MacOS/PenMac"
lipo -create "${cli_slices[@]}" -output "$package_stage/penconvert"
for executable in "$app_dir/Contents/MacOS/PenMac" "$package_stage/penconvert"; do
    architectures=$(lipo -archs "$executable")
    if [[ "$architectures" != "x86_64 arm64" && "$architectures" != "arm64 x86_64" ]]; then
        print -u2 "通用二进制架构错误：$executable（$architectures）"
        exit 1
    fi
done

cp "samples/tadpole/宝宝巴士录音贴纸_214_378.bnf" "$app_dir/Contents/Resources/target.bnf"
cp "[需解压使用]牛津阅读树拓展阅读 点读版升级套装 Level 1+ 36册/ORT_L1_The_Journey_P.bnl" "$app_dir/Contents/Resources/target.bnl"
if [[ -f Sources/CMP3Decoder/LICENSE ]]; then
    cp Sources/CMP3Decoder/LICENSE "$app_dir/Contents/Resources/minimp3-LICENSE.txt"
    cp Sources/CMP3Decoder/UPSTREAM.md "$app_dir/Contents/Resources/minimp3-UPSTREAM.md"
fi

iconset="$package_stage/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    double_size=$((size * 2))
    sips -z "$size" "$size" assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double_size" "$double_size" assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PenMac</string>
<key>CFBundleIdentifier</key><string>local.readingpen.converter</string>
<key>CFBundleName</key><string>点读包转换</string>
<key>CFBundleDisplayName</key><string>点读包转换</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>点读包或固件</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>CFBundleTypeExtensions</key><array><string>bnl</string><string>bnf</string><string>nob</string><string>nod</string><string>nos</string><string>chp</string><string>bin</string></array>
</dict></array>
</dict></plist>
PLIST
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
codesign --force --sign - "$package_stage/penconvert"
codesign --verify --strict "$package_stage/penconvert"
mkdir -p "$PWD/dist"
cp "$package_stage/penconvert" "$PWD/dist/penconvert"
# Store file contents and modes only; iCloud may add FinderInfo after signing.
python3 scripts/package_app.py "$app_dir"
python3 - "$app_dir" "$PWD/dist/点读包转换.app" <<'PY'
from pathlib import Path
import shutil, sys
source, destination = map(Path, sys.argv[1:])
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, copy_function=shutil.copyfile)
for path in source.rglob('*'):
    if path.is_file():
        destination.joinpath(path.relative_to(source)).chmod(path.stat().st_mode & 0o777)
PY
print "已构建：$PWD/dist/点读包转换.app（arm64 + x86_64，ZIP 不含 iCloud 扩展属性）"
