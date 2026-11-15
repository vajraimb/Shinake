#!/usr/bin/env bash
# 食蛇房间中继上线脚本。在 droplet 上由 root 执行。本机代理不会替你跑它。
#
#   sudo ./deploy.sh install
#   sudo ./deploy.sh rollback
#   sudo ./deploy.sh rollback /var/backups/shinake-YYYYmmddHHMMSS
#
# 只动食蛇自己的东西：用户 shinake、/opt/shinake、127.0.0.1:8796、
# Caddy 里的 /shinake/ws 与 /shinake/join、以及静态 AASA。
# 不停止语掼，不改 8787（/api/yi110）、8790、8015。
set -euo pipefail

ACTION="${1:-install}"
UNIT_NAME="shinake.service"
BIND_PORT="8796"
CADDY_FILE="${CADDY_FILE:-/etc/caddy/Caddyfile}"
WEB_ROOT="${WEB_ROOT:-/var/www/vajra.one}"
AASA_PATH="${WEB_ROOT}/.well-known/apple-app-site-association"
YUGUAN_AASA_URL="${YUGUAN_AASA_URL:-http://127.0.0.1:8795/.well-known/apple-app-site-association}"
OPT_DIR="/opt/shinake"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${SHINAKE_BIN:-${HERE}/shinake-server}"
SNIPPET="${HERE}/Caddyfile.snippet"
AASA_SRC="${HERE}/apple-app-site-association"
ALLOWED_APP_IDS="A5VCS5XD6R.one.vajra.yuguan A5VCS5XD6R.one.vajra.shinake"

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "需要 root。在 droplet 上执行：sudo $0 $ACTION"
}

port_listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :${BIND_PORT}" 2>/dev/null | grep -E ":${BIND_PORT}([^0-9]|$)" || true
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | grep -E "[.:]${BIND_PORT}([^0-9]|$)" || true
    return
  fi
  die "没有 ss 或 netstat，无法确认 ${BIND_PORT} 是否空闲"
}

check_port() {
  local listeners
  listeners="$(port_listeners)"
  if [[ -z "${listeners}" ]]; then
    printf '端口 %s 空闲。\n' "${BIND_PORT}"
    return
  fi
  printf '%s\n' "${listeners}"
  if printf '%s\n' "${listeners}" | grep -q 'shinake-server'; then
    printf '端口 %s 上已是 shinake-server，这次会重启它。\n' "${BIND_PORT}"
    return
  fi
  die "端口 ${BIND_PORT} 已被其他进程占用。不要继续，先看上面的监听者。8795 是语掼，8787 是 /api/yi110，8790 和 8015 是 prajnagarbha，都不能动。"
}

latest_backup() {
  local dir
  dir="$(ls -1d /var/backups/shinake-* 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "${dir}" ]] || die "没有 /var/backups/shinake-* 可以回滚"
  printf '%s\n' "${dir}"
}

restore_from() {
  local dir="$1"
  [[ -f "${dir}/Caddyfile" ]] || die "备份里没有 Caddyfile：${dir}"
  cp "${dir}/Caddyfile" "${CADDY_FILE}"
  if [[ -f "${dir}/apple-app-site-association" ]]; then
    mkdir -p "$(dirname "${AASA_PATH}")"
    cp "${dir}/apple-app-site-association" "${AASA_PATH}"
  elif [[ -f "${dir}/AASA_WAS_ABSENT" ]]; then
    rm -f "${AASA_PATH}"
  fi
  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "${CADDY_FILE}"
    systemctl reload caddy
  fi
}

rollback() {
  need_root
  local dir="${2:-}"
  if [[ -z "${dir}" ]]; then
    dir="$(latest_backup)"
  fi
  [[ -d "${dir}" ]] || die "找不到备份目录 ${dir}"
  printf '从 %s 回滚 Caddy 和 AASA，并停掉食蛇中继。\n' "${dir}"
  restore_from "${dir}"
  systemctl disable --now "${UNIT_NAME}" || true
  printf '已回滚。语掼服务没有被停止。\n'
}

check_aasa_ids() {
  local file="$1"
  python3 - "$file" ${ALLOWED_APP_IDS} <<'PY'
import json, sys
path, *allowed = sys.argv[1:]
allowed = set(allowed)
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
found = []
for detail in data.get("applinks", {}).get("details", []):
    if "appIDs" in detail:
        found.extend(detail["appIDs"])
    elif "appID" in detail:
        found.append(detail["appID"])
extra = sorted(set(found) - allowed)
missing = "A5VCS5XD6R.one.vajra.yuguan" not in found
if extra or missing:
    sys.stderr.write("live AASA appIDs: %s\n" % ", ".join(found))
    if extra:
        sys.stderr.write("unexpected appIDs: %s\n" % ", ".join(extra))
    if missing:
        sys.stderr.write("yuguan appID is missing; refusing to replace this file\n")
    sys.exit(2)
PY
}

install_all() {
  need_root
  command -v python3 >/dev/null 2>&1 || die "需要 python3 来检查 AASA 和改 Caddyfile"
  command -v caddy >/dev/null 2>&1 || die "找不到 caddy"
  [[ -f "${CADDY_FILE}" ]] || die "找不到 ${CADDY_FILE}"
  [[ -f "${BIN}" ]] || die "找不到二进制 ${BIN}。先在 droplet 上编译：swift build -c release --package-path <Shinake>/server，再把 .build/release/shinake-server 放到 ${HERE}/，或设置 SHINAKE_BIN"
  [[ -f "${SNIPPET}" ]] || die "找不到 ${SNIPPET}"
  [[ -f "${AASA_SRC}" ]] || die "找不到 ${AASA_SRC}"
  check_aasa_ids "${AASA_SRC}"

  printf '1. 检查端口 %s\n' "${BIND_PORT}"
  check_port

  local stamp dir
  stamp="$(date +%Y%m%d%H%M%S)"
  dir="/var/backups/shinake-${stamp}"
  mkdir -p "${dir}"
  printf '2. 备份到 %s\n' "${dir}"
  cp "${CADDY_FILE}" "${dir}/Caddyfile"
  if [[ -f "${AASA_PATH}" ]]; then
    cp "${AASA_PATH}" "${dir}/apple-app-site-association"
    cp "${AASA_PATH}" "${dir}/live-aasa.json"
  else
    : > "${dir}/AASA_WAS_ABSENT"
    if curl -fsS --max-time 5 "${YUGUAN_AASA_URL}" -o "${dir}/live-aasa.json"; then
      cp "${dir}/live-aasa.json" "${dir}/apple-app-site-association"
      printf '当前 AASA 来自语掼 8795，已存进备份。\n'
    else
      die "没有静态 AASA，也拉不到 ${YUGUAN_AASA_URL}。停下来，不要改站点。"
    fi
  fi
  check_aasa_ids "${dir}/live-aasa.json"

  if ! grep -q 'handle /yuguan/ws' "${CADDY_FILE}"; then
    die "Caddyfile 里没有 handle /yuguan/ws。不插入食蛇路由，避免贴错站点。"
  fi
  python3 - "${CADDY_FILE}" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.find("handle /.well-known/apple-app-site-association")
if start < 0:
    sys.exit(0)
window = text[start:start + 400]
if "127.0.0.1:8795" not in window and "127.0.0.1:8795" not in window.replace(" ", ""):
    sys.stderr.write("AASA handle exists but does not proxy to 127.0.0.1:8795. Refusing to edit it.\n")
    sys.exit(3)
PY

  printf '3. 安装二进制和 systemd 单元\n'
  if ! id shinake >/dev/null 2>&1; then
    useradd --system --home-dir "${OPT_DIR}" --create-home --shell /usr/sbin/nologin shinake
  fi
  install -d -o shinake -g shinake -m 755 "${OPT_DIR}"
  install -o shinake -g shinake -m 755 "${BIN}" "${OPT_DIR}/shinake-server"
  install -m 644 "${HERE}/shinake.service" "/etc/systemd/system/${UNIT_NAME}"
  systemctl daemon-reload
  systemctl enable "${UNIT_NAME}"
  systemctl restart "${UNIT_NAME}"
  sleep 0.4
  curl -fsS --max-time 3 "http://127.0.0.1:${BIND_PORT}/healthz" | grep -q '^ok' || die "8796 /healthz 没有返回 ok。单元已装上，Caddy 还没改。看 journalctl -u shinake -n 50"

  printf '4. 写入静态 AASA，并改 Caddy\n'
  mkdir -p "$(dirname "${AASA_PATH}")"
  install -m 644 "${AASA_SRC}" "${AASA_PATH}"
  python3 - "${CADDY_FILE}" "${SNIPPET}" <<'PY'
import pathlib, sys
caddy_path, snippet_path = sys.argv[1:]
text = pathlib.Path(caddy_path).read_text()
snippet = pathlib.Path(snippet_path).read_text().strip() + "\n"
marker = "handle /yuguan/ws"
if "handle /shinake/ws" not in text:
    at = text.find(marker)
    if at < 0:
        raise SystemExit("handle /yuguan/ws disappeared")
    text = text[:at] + snippet + "\n" + text[at:]

start = text.find("handle /.well-known/apple-app-site-association")
if start >= 0:
    brace = text.find("{", start)
    if brace < 0 or brace - start > 200:
        raise SystemExit("AASA handle has no opening brace")
    depth = 0
    end = None
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                break
    if end is None:
        raise SystemExit("AASA handle is unbalanced")
    block = text[start:end]
    if "8795" not in block or len(block) > 800:
        raise SystemExit("AASA handle is not the short yuguan proxy; left it untouched and aborting")
    text = text[:start] + text[end:]
pathlib.Path(caddy_path).write_text(text)
PY

  if ! caddy validate --config "${CADDY_FILE}"; then
    printf 'caddy validate 失败，正在恢复 Caddyfile 和 AASA。\n' >&2
    restore_from "${dir}"
    die "Caddy 配置无效，已按 ${dir} 回滚。食蛇单元仍在 127.0.0.1:${BIND_PORT}，没有对外路由。"
  fi
  if ! systemctl reload caddy; then
    printf 'caddy reload 失败，正在恢复。\n' >&2
    restore_from "${dir}"
    die "caddy reload 失败，已回滚文件。请再看 systemctl status caddy。"
  fi

  printf '5. 完成。备份在 %s\n' "${dir}"
  printf '回滚：sudo %s rollback %s\n' "$0" "${dir}"
  printf '语掼、8787、8790、8015 没有被重启。请用两台手机打开 https://vajra.one/shinake/join/<房间码> 验收。\n'
}

case "${ACTION}" in
  install) install_all ;;
  rollback) rollback "$@" ;;
  *) die "用法：$0 install | rollback [备份目录]" ;;
esac
