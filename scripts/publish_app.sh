#!/bin/bash
# 安装到当前用户的 Applications，无需管理员权限。
set -euo pipefail
if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && "$1" == "--help" ]]; then
        echo "用法：scripts/publish_app.sh；安装到 ~/Applications/MacSearch.app"
        exit 0
    fi
    echo "错误：不支持的参数。" >&2
    exit 1
fi
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_dir/scripts/build_app.sh"
destination="$HOME/Applications/MacSearch.app"
if /usr/bin/pgrep -f "^$destination/Contents/MacOS/MacSearchDesktop" >/dev/null; then
    echo "请先从菜单栏退出已运行的 MacSearch，再执行发布脚本。" >&2
    exit 1
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$project_dir/.build/app/MacSearch.app" "$destination"
/usr/bin/codesign --verify --strict "$destination"
echo "已安装：$destination"
echo "运行：open \"$destination\""
