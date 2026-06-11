#!/bin/sh
# Godot 4.6 ヘッドレスバイナリの展開 (Linux x86_64)。
#
# 生バイナリは 133MB で GitHub の 100MB/ファイル制限を超えるため、リポジトリには
# zip (69MB) を置き、初回にこのスクリプトで展開する。展開済みバイナリは
# .gitignore 対象 (コミットしない)。冪等 (展開済みなら何もしない)。
#
# 使い方 (リポジトリどこからでも可):
#   tools/godot/setup.sh
#   tools/godot/Godot_v4.6-stable_linux.x86_64 --headless --path Game --import
set -eu
dir="$(cd "$(dirname "$0")" && pwd)"
bin="$dir/Godot_v4.6-stable_linux.x86_64"
if [ -x "$bin" ]; then
	echo "ok: $bin (already extracted)"
	exit 0
fi
unzip -o -q "$dir/Godot_v4.6-stable_linux.x86_64.zip" -d "$dir"
chmod +x "$bin"
"$bin" --version
echo "ok: $bin"
