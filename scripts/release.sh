#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  echo 'BLOCKED: release tooling 需要发行者安装 Python 3.9+；二进制接收方不需要 Python/Xcode。' >&2
  exit 2
fi
exec python3 -B "$script_dir/release/main.py" "$@"
