#!/bin/bash
# 将原生 SwiftUI 程序打包为本机可运行的 macOS 应用。
set -euo pipefail
if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && "$1" == "--help" ]]; then
        echo "用法：scripts/build_app.sh；产物：.build/app/MacSearch.app"
        exit 0
    fi
    echo "错误：不支持的参数。" >&2
    exit 1
fi
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
swift build -c release --product MacSearchDesktop
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/.build/app/MacSearch.app"
resources="$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$resources"
/usr/bin/install -m 0755 "$binary_dir/MacSearchDesktop" "$app_dir/Contents/MacOS/MacSearchDesktop"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.macsearch.desktop</string>
<key>CFBundleName</key><string>MacSearch</string>
<key>CFBundleDisplayName</key><string>MacSearch</string>
<key>CFBundleExecutable</key><string>MacSearchDesktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>为你选择的文稿目录建立本地文件名索引。</string>
<key>NSDesktopFolderUsageDescription</key><string>为你选择的桌面目录建立本地文件名索引。</string>
<key>NSDownloadsFolderUsageDescription</key><string>为你选择的下载目录建立本地文件名索引。</string>
<key>NSRemovableVolumesUsageDescription</key><string>索引你选择的外置磁盘目录。</string>
<key>NSNetworkVolumesUsageDescription</key><string>索引你选择的已挂载目录。</string>
</dict></plist>
PLIST
icon_dir="$project_dir/.build/app/AppIcon.iconset"
mkdir -p "$icon_dir"
if [[ ! -f "$resources/AppIcon.icns" || "$project_dir/scripts/generate_icon.swift" -nt "$resources/AppIcon.icns" || "$project_dir/Resources/AppIcon.png" -nt "$resources/AppIcon.icns" ]]; then
    swift -module-cache-path "$project_dir/.build/icon-module-cache" "$project_dir/scripts/generate_icon.swift" "$project_dir/.build/app/icon.png"
    for size in 16 32 128 256 512; do
        /usr/bin/sips -z "$size" "$size" "$project_dir/.build/app/icon.png" --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        /usr/bin/sips -z "$double" "$double" "$project_dir/.build/app/icon.png" --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
    done
    /usr/bin/iconutil -c icns "$icon_dir" -o "$resources/AppIcon.icns"
fi
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign "${MAC_SEARCH_SIGN_IDENTITY:--}" --timestamp=none "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
echo "应用已生成：$app_dir"
