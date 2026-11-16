#!/bin/bash
# 构建并发布命令行工具到当前用户目录。
set -euo pipefail

if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
        echo "用法：scripts/publish.sh"
        echo "构建 release 版本并安装到 ~/.local/bin/mac-search，无需管理员权限。"
        exit 0
    fi
    echo "错误：不支持的参数。使用 scripts/publish.sh --help 查看用法。" >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination_dir="$HOME/.local/bin"
destination="$destination_dir/mac-search"
cd "$project_dir"

echo "正在构建 mac-search release 版本……"
swift build -c release --product mac-search
binary_dir="$(swift build -c release --show-bin-path)"
binary="$binary_dir/mac-search"
if [[ ! -x "$binary" ]]; then
    echo "错误：未找到可执行文件：$binary" >&2
    exit 1
fi

/usr/bin/install -d "$destination_dir"
/usr/bin/install -m 0755 "$binary" "$destination"
"$destination" help
echo "已发布到 $destination"
case ":$PATH:" in
    *":$destination_dir:"*) echo "现在可以在终端使用：mac-search help" ;;
    *) echo '请将 ~/.local/bin 加入 PATH：export PATH="$HOME/.local/bin:$PATH"（可保存到 ~/.zprofile）' ;;
esac
