#!/usr/bin/env bash
# 构建带真实家庭坐标的 M0 探针 APK。
#
# 真实数据只存在 tools/.env.places（已 gitignore），通过 --dart-define 在构建期注入，
# 不写入任何会被提交的文件。直接 `flutter build apk` 得到的是虚构示例点版本。
#
# 注意：--dart-define 的值会出现在构建进程命令行里，本机多用户环境下需自行评估。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "PATH 里找不到 flutter。把 Flutter SDK 的 bin 目录加进 PATH 后重试：" >&2
  echo "  Linux/macOS: export PATH=\"<flutter>/bin:\$PATH\"" >&2
  echo "  Windows(Git Bash): export PATH=\"/<flutter>/bin:\$PATH\"" >&2
  exit 1
fi

PLACES=tools/.env.places
if [ ! -r "$PLACES" ]; then
  echo "缺少 $PLACES，先执行：" >&2
  echo "  set -a && . ./.env.local && set +a" >&2
  echo "  python3 tools/write_places_env.py <父POI_UID>   # Windows 上命令名可能是 python" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$PLACES"; set +a
: "${PROBE_PLACES_JSON:?tools/.env.places 中没有 PROBE_PLACES_JSON}"

cd app
exec flutter build apk --debug \
  --dart-define=PROBE_PLACES_JSON="$PROBE_PLACES_JSON"
