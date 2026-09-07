#!/usr/bin/env bash
# bootstrap.sh — 在本機建立 memory-pg 的執行環境（冪等，可重跑）。
#
# 做的事：
#   1. 把 templates/ 複製到 ~/.claude/memory-pg/（根層目錄，被白名單 .gitignore 的 /* 擋住）
#   2. 沒有 .env 就產生一個（隨機密碼）；有就不動
#   3. 建 ~/.claude/memory-pg/.venv 並安裝本 package（非 editable：plugin 升版後重跑本腳本即可）
#   4. 印出下一步指令；不自動 docker compose up（拉 image / build 是使用者可見的動作）
#
# 不做的事：不碰 pgs / pgsdoc 的容器；不寫任何檔到 ~/.claude/scripts 以外的入庫路徑。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
DEST="$CLAUDE_HOME/memory-pg"

mkdir -p "$DEST/init" "$DEST/backups" || { echo "[bootstrap] 建不出 $DEST" >&2; exit 1; }

# 1. 範本（每次覆蓋：範本是 plugin 的一部分，本機不該有手改版本；.env 例外）
cp "$HERE/templates/Dockerfile"             "$DEST/Dockerfile"             || { echo "[bootstrap] 複製 Dockerfile 失敗" >&2; exit 1; }
cp "$HERE/templates/docker-compose.yml"     "$DEST/docker-compose.yml"     || { echo "[bootstrap] 複製 docker-compose.yml 失敗" >&2; exit 1; }
cp "$HERE/templates/init/00-extensions.sql" "$DEST/init/00-extensions.sql" || { echo "[bootstrap] 複製 init SQL 失敗" >&2; exit 1; }

# 2. .env
if [ ! -f "$DEST/.env" ]; then
  PW="$(python -c 'import secrets;print(secrets.token_urlsafe(24))' 2>/dev/null || openssl rand -base64 24 | tr -d '/+=')"
  [ -n "$PW" ] || { echo "[bootstrap] 產生密碼失敗（python 與 openssl 都不可用）" >&2; exit 1; }
  # 含密碼：以私有 umask 建立（WSL/Linux 上 022 會給出 0644），暫存檔用 mktemp 而非固定名稱
  # （固定名稱可被同帳號程序先擺成 symlink 導向別處）。Windows 走 ACL，umask 無作用但無害。
  ENV_TMP="$(umask 077; mktemp "$DEST/.env.XXXXXX")" || { echo "[bootstrap] mktemp 失敗" >&2; exit 1; }
  ( umask 077; sed "s|__GENERATED__|$PW|g" "$HERE/templates/env.example" > "$ENV_TMP" ) \
    && grep -q "^MEMORY_PG_DSN=postgresql://memory:$PW@" "$ENV_TMP" \
    && mv -f "$ENV_TMP" "$DEST/.env" \
    || { rm -f "$ENV_TMP"; echo "[bootstrap] 產生 .env 失敗" >&2; exit 1; }
  echo "[bootstrap] 已產生 $DEST/.env（密碼隨機；本檔不入庫）"
else
  echo "[bootstrap] 沿用既有 $DEST/.env"
fi

# 3. venv
PY=""
for c in "py -3.13" "py -3.12" python3 python; do
  if $c -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "[bootstrap] 找不到 Python >= 3.12" >&2; exit 1; }

if [ ! -x "$DEST/.venv/Scripts/python.exe" ] && [ ! -x "$DEST/.venv/bin/python" ]; then
  $PY -m venv "$DEST/.venv" || { echo "[bootstrap] venv 建立失敗" >&2; exit 1; }
fi
VPY="$DEST/.venv/Scripts/python.exe"; [ -x "$VPY" ] || VPY="$DEST/.venv/bin/python"

"$VPY" -m pip install --quiet --upgrade pip >/dev/null 2>&1
# 從暫存副本安裝：直接 pip install 原始碼目錄會讓 setuptools 在樹內留下 build/ 與 *.egg-info/
# （plugin repo 是入庫的，那些產物會被 git 撈進來）。
TMP_SRC="$(mktemp -d)"
cp -r "$HERE/pyproject.toml" "$HERE/memory_pg" "$TMP_SRC/"
# --force-reinstall --no-deps：plugin 升版但 pyproject 版本號沒動時，pip 會認為「已安裝」而跳過，
# 「重跑 bootstrap 即升版」的承諾就失效、實際跑的是舊碼。相依另外一行裝（那些可以讓 pip 判斷）。
"$VPY" -m pip install --quiet "$TMP_SRC"   && "$VPY" -m pip install --quiet --force-reinstall --no-deps "$TMP_SRC"   || { rm -rf "$TMP_SRC"; echo "[bootstrap] pip install 失敗" >&2; exit 1; }
rm -rf "$TMP_SRC"
echo "[bootstrap] venv 就緒: $VPY  ($("$VPY" -c 'import memory_pg,sys;print("memory_pg", memory_pg.__version__, "/ python", sys.version.split()[0])'))"

# 4. 下一步
cat <<EOF
[bootstrap] 完成。下一步：
  cd "$DEST" && docker compose build && docker compose up -d
  "$VPY" -m memory_pg doctor        # 檢查擴充、schema 版本
  "$VPY" -m memory_pg migrate       # 套用 migrations
EOF
