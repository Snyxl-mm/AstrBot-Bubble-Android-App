#!/usr/bin/env bash
# SnowLuma controller for AstrBot Android (proot Ubuntu rootfs).
#
# Managed by the AstrBot Bubble app, but every subcommand is safe to run by
# hand from the app terminal:
#
#   bash snowluma.sh install     # deps + download + unpack + config
#   bash snowluma.sh start       # Xvfb + fluxbox + x11vnc + noVNC + SnowLuma
#   bash snowluma.sh stop
#   bash snowluma.sh restart
#   bash snowluma.sh status      # key=value lines, parsed by the app
#   bash snowluma.sh qq          # launch a dedicated QQ instance (scan login)
#   bash snowluma.sh vnc         # restart only the noVNC side
#   bash snowluma.sh uninstall [--clean-data]
#
# Ports (mirroring SnowLuma upstream defaults plus the noVNC side):
#   5099  WebUI      (config/runtime.json -> webuiPort)
#   6081  noVNC      (QQ window, used for QR scan)
#   5900  x11vnc     (noVNC 后端，仅 loopback)
#   3001  OneBot WS  /  3000 OneBot HTTP (per-UIN, created after QQ login)
#
# SNOWLUMA_BIND_HOST 默认 0.0.0.0（与 SnowLuma 官方默认一致，局域网可访问）；
# 想只允许手机本机访问就设成 127.0.0.1。
# Environment overrides: SNOWLUMA_VERSION, SNOWLUMA_DIR, SNOWLUMA_RUNTIME_DIR,
# SNOWLUMA_BIND_HOST,
# SNOWLUMA_WEBUI_PORT, SNOWLUMA_VNC_PORT, SNOWLUMA_ONEBOT_WS_PORT,
# SNOWLUMA_ONEBOT_HTTP_PORT, SNOWLUMA_DISPLAY_NUM, SNOWLUMA_GITHUB_PROXY,
# SNOWLUMA_TARBALL (offline install from a local tarball),
# SNOWLUMA_QQ_HOME (per-instance QQ HOME), SNOWLUMA_HOOK_MODE.

set -o pipefail

SL_VERSION="${SNOWLUMA_VERSION:-2.0.3}"
SL_HOME="${SNOWLUMA_DIR:-$HOME/snowluma}"
SL_RT="${SNOWLUMA_RUNTIME_DIR:-$HOME/.config/astrbot-android/snowluma}"
SL_INSTANCE_HOME="${SNOWLUMA_QQ_HOME:-$HOME/snowluma_instances/default_home}"
SL_BIND_HOST="${SNOWLUMA_BIND_HOST:-0.0.0.0}"
SL_WEBUI_PORT="${SNOWLUMA_WEBUI_PORT:-5099}"
SL_VNC_PORT="${SNOWLUMA_VNC_PORT:-6081}"
SL_VNCSERVER_PORT="${SNOWLUMA_VNCSERVER_PORT:-5900}"
SL_ONEBOT_WS_PORT="${SNOWLUMA_ONEBOT_WS_PORT:-3001}"
SL_ONEBOT_HTTP_PORT="${SNOWLUMA_ONEBOT_HTTP_PORT:-3000}"
# AstrBot 的 aiocqhttp 适配器只做「反向 WS 服务端」（默认 6199），协议端必须主动连它。
SL_ASTRBOT_WS_PORT="${SNOWLUMA_ASTRBOT_WS_PORT:-6199}"
SL_ASTRBOT_WS_URL="${SNOWLUMA_ASTRBOT_WS_URL:-ws://127.0.0.1:${SL_ASTRBOT_WS_PORT}/ws}"
SL_DISPLAY_NUM="${SNOWLUMA_DISPLAY_NUM:-21}"
SL_SCREEN="${SNOWLUMA_SCREEN:-1280x720x24}"
SL_PROXY_CFG="${SNOWLUMA_GITHUB_PROXY:-auto}"
SL_TARBALL="${SNOWLUMA_TARBALL:-}"
SL_ARCHIVE=""
SL_HOOK_MODE="${SNOWLUMA_HOOK_MODE:-auto}"
SL_RUN_DIR="$SL_RT/run"
SL_LOG_DIR="$SL_RT/logs"
SL_NOVNC_WEB="/usr/share/novnc"
SL_QQ_BIN="${SNOWLUMA_QQ_BIN:-}"
export TMPDIR="${TMPDIR:-/tmp}"

target_proxy=""

log() { printf '[snowluma] %s\n' "$*"; }
warn() { printf '[snowluma] WARNING: %s\n' "$*" >&2; }
die() { printf '[snowluma] ERROR: %s\n' "$*" >&2; exit 1; }

need_dirs() {
  mkdir -p "$SL_RT" "$SL_LOG_DIR" "$SL_RUN_DIR" "$SL_RT/pids"
}

pid_file() { printf '%s/pids/%s.pid' "$SL_RT" "$1"; }

pid_of() {
  local file
  file="$(pid_file "$1")"
  [ -s "$file" ] || return 1
  cat "$file"
}

is_running() {
  local pid
  pid="$(pid_of "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

record_pid() {
  printf '%s\n' "$2" > "$(pid_file "$1")"
}

stop_pid() {
  local name="$1" pid
  pid="$(pid_of "$name" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$(pid_file "$name")"
}

# ---------------------------------------------------------------- mirrors ----
# Same proxy list and probe as the AstrBot shared installer, so a working
# "加速器" setting behaves identically for both stacks.
resolve_proxy() {
  local candidate status
  case "$SL_PROXY_CFG" in
    direct|'')
      target_proxy=""
      return 0
      ;;
    https://*|http://*)
      target_proxy="${SL_PROXY_CFG%/}"
      log "使用自定义 GitHub 代理: $target_proxy"
      return 0
      ;;
    auto) ;;
    *)
      warn "忽略无效的代理设置: $SL_PROXY_CFG"
      ;;
  esac

  for candidate in \
    https://ghfast.top \
    https://gh-proxy.com \
    https://ghproxy.net \
    https://ghproxy.cc \
    https://gh.dpik.top \
    https://gh.monlor.com \
    https://gh.chjina.com \
    https://github.boki.moe \
    https://gh.jasonzeng.dev \
    https://gh.geekertao.top \
    https://gh.nxnow.top \
    https://down.npee.cn; do
    status="$(curl -fL --connect-timeout 8 --max-time 20 -o /dev/null -s -w '%{http_code}' \
      "$candidate/https://raw.githubusercontent.com/astral-sh/uv/main/README.md" || true)"
    if [ "$status" = "200" ]; then
      target_proxy="$candidate"
      log "使用 GitHub 代理: $target_proxy"
      return 0
    fi
  done
  log "没有代理响应，尝试直连"
}

github_url() {
  if [ -n "${target_proxy:-}" ]; then
    printf '%s/%s\n' "${target_proxy%/}" "$1"
  else
    printf '%s\n' "$1"
  fi
}

# 下载用：按优先顺序列出代理（空行代表直连）。显式指定 URL 时只用它 + 直连兜底。
proxy_candidates() {
  case "$SL_PROXY_CFG" in
    direct|'') printf '%s\n' '' ;;
    https://*|http://*)
      printf '%s\n' "${SL_PROXY_CFG%/}"
      printf '%s\n' ''
      ;;
    *)
      [ -n "${target_proxy:-}" ] && printf '%s\n' "${target_proxy%/}"
      for candidate in \
        https://ghfast.top \
        https://gh-proxy.com \
        https://ghproxy.net \
        https://ghproxy.cc \
        https://gh.dpik.top \
        https://gh.monlor.com \
        https://gh.jina.ai \
        https://github.boki.moe \
        https://gh.nxnow.top \
        https://down.npee.cn; do
        [ "$candidate" = "${target_proxy:-}" ] && continue
        printf '%s\n' "$candidate"
      done
      printf '%s\n' ''
      ;;
  esac
}

arch_tag() {
  case "$(uname -m)" in
    aarch64|arm64) printf 'arm64' ;;
    x86_64|amd64) printf 'x64' ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

# ------------------------------------------------------------------ deps ----
install_deps() {
  local missing=() pkg
  for pkg in Xvfb fluxbox x11vnc websockify; do
    command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [ -d "$SL_NOVNC_WEB" ] || missing+=(novnc)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v dbus-launch >/dev/null 2>&1 || missing+=(dbus-x11)
  # QQ 界面是中文，缺 CJK 字体时整屏变方块，扫码都没法扫
  if ! fc-list :lang=zh 2>/dev/null | grep -q .; then
    missing+=(fonts-noto-cjk)
  fi

  if [ ${#missing[@]} -eq 0 ]; then
    log "依赖已就绪"
    return 0
  fi

  log "安装依赖: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::ForceIPv4=true update || warn "apt-get update 失败，继续尝试安装"
  apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends \
    xvfb fluxbox x11vnc novnc websockify curl dbus-x11 fonts-noto-cjk || return 1

  for pkg in Xvfb fluxbox x11vnc websockify; do
    command -v "$pkg" >/dev/null 2>&1 || { warn "依赖安装后仍缺少 $pkg"; return 1; }
  done
  [ -d "$SL_NOVNC_WEB" ] || { warn "noVNC 静态文件缺失: $SL_NOVNC_WEB"; return 1; }
  log "依赖安装完成"
}

# -------------------------------------------------------------- download ----
download_release() {
  local tag archive tmp url
  tag="$(arch_tag)"
  archive="SnowLuma-v${SL_VERSION}-linux-${tag}.tar.gz"
  tmp="$SL_RT/dl"
  mkdir -p "$tmp"

  if [ -n "$SL_TARBALL" ] && [ -f "$SL_TARBALL" ]; then
    log "使用本地安装包: $SL_TARBALL"
    cp -f "$SL_TARBALL" "$tmp/$archive" || return 1
    SL_ARCHIVE="$tmp/$archive"
    return 0
  fi

  if [ -s "$tmp/$archive" ] && tar -tzf "$tmp/$archive" >/dev/null 2>&1; then
    log "复用已下载安装包: $archive"
    SL_ARCHIVE="$tmp/$archive"
    return 0
  fi

  resolve_proxy
  local upstream="https://github.com/SnowLuma/SnowLuma/releases/download/v${SL_VERSION}/${archive}"
  local proxy url rc=1
  log "下载 $archive（约 49 MB，带进度条；卡住会自动换源续传）"
  while IFS= read -r proxy; do
    if [ -n "$proxy" ]; then
      url="$proxy/$upstream"
      log "源: $proxy"
    else
      url="$upstream"
      log "源: 直连"
    fi
    # -C - 续传；--speed-limit/--speed-time：30 秒内低于 10KB/s 判定断流，自动换下一个源
    if curl -fL --progress-bar -C - \
        --connect-timeout 15 --max-time 3600 \
        --speed-limit 10240 --speed-time 30 \
        -o "$tmp/$archive.part" "$url"; then
      rc=0
      break
    fi
    warn "该源失败或过慢，换下一个"
  done <<< "$(proxy_candidates)"

  if [ "$rc" -ne 0 ]; then
    warn "所有源都失败。可手动下载后放到 $tmp/$archive 再重跑 install："
    warn "  curl -fL --progress-bar -C - -o '$tmp/$archive.part' '<代理>/$upstream'"
    return 1
  fi
  mv -f "$tmp/$archive.part" "$tmp/$archive" || return 1
  SL_ARCHIVE="$tmp/$archive"
}

# ---------------------------------------------------------------- install ----
install_snowluma() {
  local staging
  SL_ARCHIVE=""
  need_dirs
  install_deps || return 1
  ensure_linuxqq || warn "LinuxQQ 未就绪，扫码登录会失败（可稍后重跑 install）"
  download_release || return 1
  [ -n "$SL_ARCHIVE" ] || { warn "未取得安装包"; return 1; }

  log "解压安装包"
  staging="$(mktemp -d "$SL_RT/unpack.XXXXXX")" || return 1
  if ! tar -xzf "$SL_ARCHIVE" -C "$staging"; then
    rm -rf "$staging"
    return 1
  fi
  [ -f "$staging/index.mjs" ] || { rm -rf "$staging"; die "安装包结构异常: 缺少 index.mjs"; }

  mkdir -p "$SL_HOME"
  # Keep user data (config/, logs/) across reinstall/upgrade.
  local keep
  keep="$(mktemp -d "$SL_RT/keep.XXXXXX")"
  [ -d "$SL_HOME/config" ] && cp -a "$SL_HOME/config" "$keep/config" 2>/dev/null || true
  [ -d "$SL_HOME/logs" ] && cp -a "$SL_HOME/logs" "$keep/logs" 2>/dev/null || true

  rm -rf "$SL_HOME.new"
  mv "$staging" "$SL_HOME.new" || return 1
  rm -rf "$SL_HOME"
  mv "$SL_HOME.new" "$SL_HOME" || return 1
  [ -d "$keep/config" ] && { rm -rf "$SL_HOME/config"; cp -a "$keep/config" "$SL_HOME/config"; }
  [ -d "$keep/logs" ] && { rm -rf "$SL_HOME/logs"; cp -a "$keep/logs" "$SL_HOME/logs"; }
  rm -rf "$keep"

  chmod +x "$SL_HOME/launcher.sh" "$SL_HOME/node" 2>/dev/null || true
  write_config
  freeze_qq_hot_update
  grant_ptrace
  log "SnowLuma v${SL_VERSION} 安装完成: $SL_HOME"
}

write_config() {
  mkdir -p "$SL_HOME/config"
  SNOW_BIND_HOST="$SL_BIND_HOST" SNOW_ASTRBOT_WS_URL="$SL_ASTRBOT_WS_URL" \
    SNOW_WEBUI_PORT="$SL_WEBUI_PORT" SNOW_WS_PORT="$SL_ONEBOT_WS_PORT" \
    SNOW_HTTP_PORT="$SL_ONEBOT_HTTP_PORT" SNOW_TOKEN_FILE="$SL_RT/onebot-token" \
    SNOW_CONFIG_DIR="$SL_HOME/config" "$SL_HOME/node" -e '
const fs = require("fs");
const path = require("path");
const dir = process.env.SNOW_CONFIG_DIR;
const runtimePath = path.join(dir, "runtime.json");
const onebotPath = path.join(dir, "onebot.json");

let runtime = {};
try { runtime = JSON.parse(fs.readFileSync(runtimePath, "utf8")); } catch {}
runtime.webuiPort = Number(process.env.SNOW_WEBUI_PORT);
runtime.webuiHost = process.env.SNOW_BIND_HOST || runtime.webuiHost || "0.0.0.0";
runtime.hookAutoLoad = true;
fs.writeFileSync(runtimePath, JSON.stringify(runtime, null, 2));

let token = "";
try { token = fs.readFileSync(process.env.SNOW_TOKEN_FILE, "utf8").trim(); } catch {}
if (!token) {
  token = require("crypto").randomBytes(24).toString("hex");
  fs.writeFileSync(process.env.SNOW_TOKEN_FILE, token);
}

const bind = process.env.SNOW_BIND_HOST || "0.0.0.0";
const wantHttpPort = Number(process.env.SNOW_HTTP_PORT);
const wantWsPort = Number(process.env.SNOW_WS_PORT);

const adapter = (name, port) => ({
  name,
  enabled: true,
  host: bind,
  port: Number(port),
  path: "/",
  accessToken: token,
  messageFormat: "array",
  reportSelfMessage: false,
});

const astrbotUrl = process.env.SNOW_ASTRBOT_WS_URL || "ws://127.0.0.1:6199/ws";
const wsClient = {
  name: "astrbot",
  enabled: true,
  url: astrbotUrl,
  role: "Universal",
  accessToken: "",
  messageFormat: "array",
  reportSelfMessage: false,
  reconnectIntervalMs: 5000,
};
let onebot = null;
try { onebot = JSON.parse(fs.readFileSync(onebotPath, "utf8")); } catch {}

if (!onebot) {
  onebot = {
    networks: {
      httpServers: [adapter("http-default", wantHttpPort)],
      httpClients: [],
      wsServers: [{ ...adapter("ws-default", wantWsPort), role: "Universal" }],
      wsClients: [wsClient],
    },
    musicSignUrl: "",
  };
} else {
  // 已存在：只对齐监听地址/端口，保留用户原有 token、上报端点与其他设置
  const nets = onebot.networks || (onebot.networks = {});
  for (const list of [nets.httpServers, nets.wsServers]) {
    for (const item of list || []) {
      if (item && typeof item === "object") item.host = bind;
    }
  }
  const http0 = (nets.httpServers || [])[0];
  if (http0) http0.port = wantHttpPort;
  const ws0 = (nets.wsServers || [])[0];
  if (ws0) ws0.port = wantWsPort;

  if (!Array.isArray(nets.wsClients)) nets.wsClients = [];
  const mine = nets.wsClients.find((c) => c && c.name === "astrbot");
  if (mine) {
    mine.url = astrbotUrl;
    mine.enabled = true;
  } else {
    nets.wsClients.push({ ...wsClient });
  }
}
fs.writeFileSync(onebotPath, JSON.stringify(onebot, null, 2));

// 账号级配置（config/onebot_<uin>.json）会覆盖全局默认，登录后由 SnowLuma 生成，
// 这里一并把监听地址/端口对齐，改 bind host 或端口后重启即可全部生效。
const accountFiles = fs.readdirSync(dir).filter(
  (f) => /^onebot_\d+\.json$/.test(f),
);
for (const f of accountFiles) {
  const fp = path.join(dir, f);
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(fp, "utf8")); } catch { continue; }
  const nets = cfg.networks || {};
  for (const list of [nets.httpServers, nets.wsServers]) {
    for (const item of list || []) {
      if (item && typeof item === "object") item.host = bind;
    }
  }
  const h0 = (nets.httpServers || [])[0];
  if (h0) h0.port = wantHttpPort;
  const w0 = (nets.wsServers || [])[0];
  if (w0) w0.port = wantWsPort;
  if (!Array.isArray(nets.wsClients)) nets.wsClients = [];
  const mineAcc = nets.wsClients.find((c) => c && c.name === "astrbot");
  if (mineAcc) {
    mineAcc.url = astrbotUrl;
    mineAcc.enabled = true;
  } else {
    nets.wsClients.push({ ...wsClient });
  }
  fs.writeFileSync(fp, JSON.stringify(cfg, null, 2));
  console.log("patched account config: " + f);
}
console.log("onebot bind=" + bind + " http=" + wantHttpPort + " ws=" + wantWsPort);
' || { warn "写入 SnowLuma 配置失败"; return 1; }
  log "监听 $SL_BIND_HOST — WebUI $SL_WEBUI_PORT / OneBot WS $SL_ONEBOT_WS_PORT / HTTP $SL_ONEBOT_HTTP_PORT"
  log "反向连接 AstrBot: $SL_ASTRBOT_WS_URL"
}

# QQ silently hot-patches itself, which breaks version-matched native hooks.
freeze_qq_hot_update() {
  local hosts=/etc/hosts
  [ -w "$hosts" ] || { warn "$hosts 不可写，跳过 QQ 热更新冻结"; return 0; }
  if grep -q 'qqpatch.gtimg.cn' "$hosts" 2>/dev/null; then
    return 0
  fi
  printf '0.0.0.0 qqpatch.gtimg.cn\n' >> "$hosts" && log "已冻结 QQ 静默热更新"
}

# ptrace injection needs cap_sys_ptrace on the node binary. Inside proot this
# is usually denied; keep going and rely on the fallback hook paths.
grant_ptrace() {
  local node_bin="$SL_HOME/node"
  [ -x "$node_bin" ] || return 0
  if command -v setcap >/dev/null 2>&1; then
    if setcap cap_sys_ptrace=ep "$node_bin" 2>/dev/null; then
      log "已授予 cap_sys_ptrace: $node_bin"
    else
      warn "setcap 失败（proot 下常见），ptrace 注入可能不可用"
    fi
  fi
}

# ------------------------------------------------------------------ LinuxQQ --
# SnowLuma 要 hook 真实的 QQ 客户端，所以 QQ 必须在本机可用。
# 逻辑移植自 AstrBot 共享安装脚本：官方配置解析 → 签名 URL 回退 → deb 校验。
linuxqq_ready() {
  if command -v qq >/dev/null 2>&1 || [ -x /opt/QQ/qq ]; then
    return 0
  fi
  dpkg-query -W -f='${Status}\n' linuxqq 2>/dev/null | grep -qx 'install ok installed'
}

linuxqq_download_url() {
  local config_url="https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js"
  local config="$TMPDIR/linuxqq-config.js"
  local normalized="$TMPDIR/linuxqq-config-normalized.js"
  local url="${SNOWLUMA_LINUXQQ_URL:-}"

  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi
  curl -fL --connect-timeout 15 --max-time 60 "$config_url" -o "$config" || return 1
  sed 's#\\/#/#g' "$config" > "$normalized"
  url="$(grep -Eo "(https?:)?//[^\"'[:space:]]+" "$normalized" \
        | grep -Ei '(arm64|aarch64)[^[:space:]]*\.deb([?#][^[:space:]]*)?' | head -n 1)"
  case "$url" in
    //*) url="https:$url" ;;
  esac
  case "$url" in
    https://*.deb|https://*.deb\?*) printf '%s\n' "$url" ;;
    *) return 1 ;;
  esac
}

get_linuxqq_signed_url() {
  local bare_url="$1"
  local response="$TMPDIR/linuxqq-sign.json"
  local normalized="$TMPDIR/linuxqq-sign-normalized.json"
  SNOWLUMA_LINUXQQ_SIGNED_URL=""
  if ! curl -fL --connect-timeout 15 --max-time 30 \
    -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
    -e 'https://im.qq.com/' \
    -H 'Accept: application/json, text/plain, */*' \
    -H 'Content-Type: application/json' \
    -H 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}' \
    --data "$(printf '{\"url\":\"%s\"}' "$bare_url")" \
    'https://im.qq.com/http2rpc/gotrpc/noauth/trpc.qqntv2.urlsign.UrlSign/GetSign' \
    -o "$response"; then
    return 1
  fi
  sed 's#\\/#/#g; s#\\u0026#\&#g; s#\\u003d#=#g' "$response" > "$normalized"
  SNOWLUMA_LINUXQQ_SIGNED_URL="$(grep -Eo '"url"[[:space:]]*:[[:space:]]*"[^"]+"' "$normalized" \
    | head -n 1 | sed -E 's/^"url"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  case "$SNOWLUMA_LINUXQQ_SIGNED_URL" in
    https://*.deb|https://*.deb\?*) return 0 ;;
    *) SNOWLUMA_LINUXQQ_SIGNED_URL=""; return 1 ;;
  esac
}

validate_linuxqq_deb() {
  local file="$1" arch pkg
  [ -s "$file" ] || return 1
  dpkg-deb --info "$file" >/dev/null 2>&1 || return 1
  arch="$(dpkg-deb -f "$file" Architecture 2>/dev/null)"
  pkg="$(dpkg-deb -f "$file" Package 2>/dev/null)"
  case "$arch" in arm64|aarch64) ;; *) return 1 ;; esac
  [ "$pkg" = "linuxqq" ]
}

download_qq_file() {
  curl -fL --progress-bar -C - --connect-timeout 20 --max-time 900 \
    -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
    -e 'https://im.qq.com/' "$1" -o "$2"
}

# 等待态：已装则直接返回；否则装依赖 + 下 deb + dpkg 安装
ensure_linuxqq() {
  local deb="$SL_RT/linuxqq.deb" part="$SL_RT/linuxqq.deb.part"
  local url sound_package

  if linuxqq_ready; then
    log "LinuxQQ 已就绪"
    return 0
  fi

  log "安装 LinuxQQ（SnowLuma 需要真实 QQ 客户端）"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::ForceIPv4=true update || warn "apt-get update 失败，继续尝试"
  if apt-cache show libasound2t64 >/dev/null 2>&1; then
    sound_package=libasound2t64
  else
    sound_package=libasound2
  fi
  apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends \
    libnss3 libnspr4 libgbm1 libxshmfence1 libxdamage1 libdrm2 \
    libxkbcommon0 fontconfig dbus-x11 xvfb "$sound_package" || return 1
  # noble 起是 libgtk-3-0t64，老版本是 libgtk-3-0；都失败也只告警（QQ 多半仍能跑）
  apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends libgtk-3-0 \
    || apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends libgtk-3-0t64 \
    || warn "libgtk-3 未安装，QQ 可能无法显示界面"

  rm -f "$part"

  # 1) 本地已有安装包（用户手动放 /sdcard/Download 也能直接复用）
  local candidate
  for candidate in "${SNOWLUMA_LINUXQQ_FILE:-}" "$HOME"/*.deb /sdcard/Download/*.deb /storage/emulated/0/Download/*.deb; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    validate_linuxqq_deb "$candidate" || continue
    log "复用本地安装包: $candidate"
    cp -f "$candidate" "$part"
    break
  done

  # 2) 上游镜像（AstrBot 官方脚本仓把 QQ deb 托管在 release 里，国内可走代理）
  if [ ! -s "$part" ]; then
    resolve_proxy
    local mirror
    mirror="$(github_url 'https://github.com/MuFengDR/AstrBot-Android-Scripts/releases/latest/download/linuxqq-arm64.deb')"
    log "下载 LinuxQQ（上游镜像，约 200 MB，带进度条；断流会自动续传）"
    if ! download_qq_file "$mirror" "$part" || ! validate_linuxqq_deb "$part"; then
      warn "上游镜像失败，回退官方直链"
      rm -f "$part"
    fi
  fi

  # 3) 官方直链 → 签名 URL 回退
  if [ ! -s "$part" ]; then
    if ! url="$(linuxqq_download_url)"; then
      warn "未能解析 LinuxQQ arm64 安装包地址"
      return 1
    fi
    log "下载 LinuxQQ: $(basename "${url%%\?*}")"
    if ! download_qq_file "$url" "$part" || ! validate_linuxqq_deb "$part"; then
      log "官方直链失败（常见 403），尝试签名 URL 回退"
      if ! get_linuxqq_signed_url "$url" || ! download_qq_file "$SNOWLUMA_LINUXQQ_SIGNED_URL" "$part"; then
        rm -f "$part"
        warn "LinuxQQ 下载失败。可手动下载 deb 放到 /sdcard/Download/ 后重跑 install"
        return 1
      fi
    fi
  fi
  validate_linuxqq_deb "$part" || { rm -f "$part"; warn "LinuxQQ 安装包校验失败"; return 1; }
  mv -f "$part" "$deb"
  apt-get -o Acquire::ForceIPv4=true install -y --allow-downgrades "$deb" || return 1
  rm -f "$deb"
  linuxqq_ready || { warn "LinuxQQ 安装后仍不可用"; return 1; }
  log "LinuxQQ 安装完成"
}

# ------------------------------------------------------------------ start ----
port_open() {
  local port="$1"
  curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null
}

# 给 fluxbox 指定 CJK 字体。注意：部分 fluxbox 构建只认 X core 字体（不含中文），
# 此时窗口标题栏仍可能显示方块 —— 只影响标题外观，QQ 界面内容（fontconfig 渲染）正常。
ensure_fluxbox_font() {
  local dir="$HOME/.fluxbox"
  local init="$dir/init"
  mkdir -p "$dir"
  if [ ! -f "$init" ]; then
    printf '%s\n' \
      'session.screen0.window.font: Noto Sans CJK SC-10' \
      'session.screen0.toolbar.font: Noto Sans CJK SC-10' \
      'session.screen0.menu.font: Noto Sans CJK SC-10' \
      'session.screen0.toolbar.visible: true' \
      > "$init"
    return 0
  fi
  # 保证文件以换行结尾，否则新键会拼到上一行末尾（fluxbox 默认 init 常缺尾换行）
  if [ -s "$init" ] && [ -n "$(tail -c1 "$init")" ]; then
    printf '\n' >> "$init"
  fi
  local key
  for key in window toolbar menu; do
    if grep -q "session.screen0.${key}.font" "$init"; then
      sed -i -E "s#^session\.screen0\.${key}\.font:.*#session.screen0.${key}.font: Noto Sans CJK SC-10#" "$init"
    else
      printf 'session.screen0.%s.font: Noto Sans CJK SC-10\n' "$key" >> "$init"
    fi
  done
}

start_xvfb() {
  local lock="/tmp/.X${SL_DISPLAY_NUM}-lock"
  mkdir -p /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix 2>/dev/null || true
  if [ -S "/tmp/.X11-unix/X${SL_DISPLAY_NUM}" ]; then
    log "Xvfb :${SL_DISPLAY_NUM} 已在运行"
  else
    rm -f "$lock" "/tmp/.X11-unix/X${SL_DISPLAY_NUM}" 2>/dev/null || true
    nohup Xvfb ":${SL_DISPLAY_NUM}" -screen 0 "$SL_SCREEN" +extension GLX +render \
      > "$SL_LOG_DIR/xvfb.log" 2>&1 &
    record_pid xvfb "$!"
    local i
    for i in $(seq 1 50); do
      [ -S "/tmp/.X11-unix/X${SL_DISPLAY_NUM}" ] && break
      sleep 0.1
    done
    [ -S "/tmp/.X11-unix/X${SL_DISPLAY_NUM}" ] || { warn "Xvfb 启动失败"; cat "$SL_LOG_DIR/xvfb.log" 2>/dev/null; return 1; }
  fi
  export DISPLAY=":${SL_DISPLAY_NUM}"

  ensure_fluxbox_font
  if ! is_running fluxbox; then
    nohup fluxbox > "$SL_LOG_DIR/fluxbox.log" 2>&1 &
    record_pid fluxbox "$!"
    sleep 0.5
  fi
  return 0
}

start_vnc() {
  export DISPLAY=":${SL_DISPLAY_NUM}"
  if ! is_running x11vnc; then
    mkdir -p "$HOME/.vnc"
    [ -f "$HOME/.vnc/passwd" ] || x11vnc -storepasswd snowluma "$HOME/.vnc/passwd" >/dev/null 2>&1
    nohup x11vnc -display ":$SL_DISPLAY_NUM" -noshm -rfbauth "$HOME/.vnc/passwd" \
      -forever -shared -listen 127.0.0.1 -rfbport "$SL_VNCSERVER_PORT" \
      -o "$SL_LOG_DIR/x11vnc.log" \
      > /dev/null 2>&1 &
    record_pid x11vnc "$!"
    sleep 2
  fi

  if ! is_running novnc; then
    if [ -x "$SL_NOVNC_WEB/utils/novnc_proxy" ]; then
      nohup "$SL_NOVNC_WEB/utils/novnc_proxy" --vnc "127.0.0.1:${SL_VNCSERVER_PORT}" \
        --listen "$SL_VNC_PORT" > "$SL_LOG_DIR/novnc.log" 2>&1 &
    else
      nohup websockify --web "$SL_NOVNC_WEB" "$SL_VNC_PORT" "127.0.0.1:${SL_VNCSERVER_PORT}" \
        > "$SL_LOG_DIR/novnc.log" 2>&1 &
    fi
    record_pid novnc "$!"
    sleep 2
  fi
  return 0
}

start_snowluma() {
  local i
  if is_running snowluma; then
    log "SnowLuma 已在运行 (pid $(pid_of snowluma))"
    return 0
  fi
  [ -f "$SL_HOME/index.mjs" ] || { warn "SnowLuma 未安装"; return 1; }

  # The container has no desktop; SnowLuma shells out to xdg-open in web mode.
  mkdir -p "$HOME/.local/bin"
  if [ ! -x "$HOME/.local/bin/xdg-open" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/xdg-open"
    chmod 755 "$HOME/.local/bin/xdg-open"
  fi

  log "启动 SnowLuma (WebUI :$SL_WEBUI_PORT)"
  ( cd "$SL_HOME" && exec env \
    SNOWLUMA_HOOK_RUNTIME_DIR="$SL_RUN_DIR" \
    XDG_RUNTIME_DIR="$SL_RUN_DIR" \
    "$SL_HOME/launcher.sh" ) > "$SL_LOG_DIR/snowluma.log" 2>&1 &
  record_pid snowluma "$!"

  for i in $(seq 1 30); do
    if port_open "$SL_WEBUI_PORT"; then
      log "SnowLuma 已启动"
      return 0
    fi
    is_running snowluma || break
    sleep 1
  done
  warn "SnowLuma WebUI 未在 $SL_WEBUI_PORT 响应，日志:"
  tail -n 25 "$SL_LOG_DIR/snowluma.log" 2>/dev/null || true
  return 1
}

cmd_start() {
  need_dirs
  [ -f "$SL_HOME/index.mjs" ] || die "SnowLuma 未安装，先运行: bash $0 install"
  start_xvfb || return 1
  start_vnc || return 1
  start_snowluma || return 1
  log "WebUI   : http://127.0.0.1:$SL_WEBUI_PORT/"
  log "扫码    : http://127.0.0.1:$SL_VNC_PORT/vnc.html"
  log "OneBot  : ws://127.0.0.1:$SL_ONEBOT_WS_PORT/ （登录后每账号独立实例）"
  return 0
}

cmd_stop() {
  stop_pid snowluma
  stop_pid novnc
  stop_pid x11vnc
  stop_pid fluxbox
  stop_pid xvfb
  rm -f "/tmp/.X${SL_DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${SL_DISPLAY_NUM}" 2>/dev/null || true
  log "SnowLuma 已停止"
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_vnc() {
  need_dirs
  start_xvfb || return 1
  start_vnc || return 1
  log "扫码页面: http://127.0.0.1:$SL_VNC_PORT/vnc.html"
}

# Dedicated QQ instance: SnowLuma hooks a real QQ process, and QQ has a
# single-instance lock, so it must not share HOME with the NapCat instances.
cmd_qq() {
  need_dirs
  local qq_bin token mode
  qq_bin="${SL_QQ_BIN:-}"
  if [ -z "$qq_bin" ]; then
    for candidate in /opt/QQ/qq /usr/bin/qq /usr/local/bin/qq; do
      [ -x "$candidate" ] && { qq_bin="$candidate"; break; }
    done
  fi
  if [ -z "$qq_bin" ]; then
    log "未找到 LinuxQQ，先尝试安装"
    ensure_linuxqq || die "LinuxQQ 安装失败，可重跑: bash /root/snowluma.sh install"
    for candidate in /opt/QQ/qq /usr/bin/qq /usr/local/bin/qq; do
      [ -x "$candidate" ] && { qq_bin="$candidate"; break; }
    done
    qq_bin="${qq_bin:-$(command -v qq || true)}"
    [ -n "$qq_bin" ] || die "LinuxQQ 安装后仍找不到可执行文件"
  fi

  start_xvfb || return 1
  export DISPLAY=":${SL_DISPLAY_NUM}"
  mkdir -p "$SL_INSTANCE_HOME/.config" "$SL_INSTANCE_HOME/.cache" "$SL_INSTANCE_HOME/.local/share"

  mode="$SL_HOOK_MODE"
  [ "$mode" = "auto" ] && mode="inject"  # upstream path; "preload" is experimental

  log "启动 QQ 实例: HOME=$SL_INSTANCE_HOME DISPLAY=:$SL_DISPLAY_NUM 注入模式=$mode"
  if [ "$mode" = "preload" ]; then
    local so="$SL_HOME/native/snowluma-linux-arm64.so"
    ( cd "$SL_INSTANCE_HOME" && exec env \
      HOME="$SL_INSTANCE_HOME" \
      XDG_CONFIG_HOME="$SL_INSTANCE_HOME/.config" \
      XDG_CACHE_HOME="$SL_INSTANCE_HOME/.cache" \
      XDG_DATA_HOME="$SL_INSTANCE_HOME/.local/share" \
      SNOWLUMA_HOOK_RUNTIME_DIR="$SL_RUN_DIR" \
      XDG_RUNTIME_DIR="$SL_RUN_DIR" \
      SNOWLUMA_HOOK_STUB_START=1 \
      SNOWLUMA_HOOK_SERVICE_MODE=1 \
      LD_PRELOAD="$so" \
      "$qq_bin" --no-sandbox --disable-gpu ) >> "$SL_LOG_DIR/qq.log" 2>&1 &
    record_pid qq "$!"
  else
    ( cd "$SL_INSTANCE_HOME" && exec env \
      HOME="$SL_INSTANCE_HOME" \
      XDG_CONFIG_HOME="$SL_INSTANCE_HOME/.config" \
      XDG_CACHE_HOME="$SL_INSTANCE_HOME/.cache" \
      XDG_DATA_HOME="$SL_INSTANCE_HOME/.local/share" \
      SNOWLUMA_HOOK_RUNTIME_DIR="$SL_RUN_DIR" \
      XDG_RUNTIME_DIR="$SL_RUN_DIR" \
      "$qq_bin" --no-sandbox --disable-gpu ) >> "$SL_LOG_DIR/qq.log" 2>&1 &
    record_pid qq "$!"
  fi
  log "QQ 已拉起，扫码请打开 http://127.0.0.1:$SL_VNC_PORT/vnc.html"
}

cmd_status() {
  need_dirs
  local installed=0 running=0 qq_up=0 token
  [ -f "$SL_HOME/index.mjs" ] && installed=1
  is_running snowluma && running=1
  is_running qq && qq_up=1
  token="$(cat "$SL_RT/onebot-token" 2>/dev/null || true)"
  printf 'installed=%s\n' "$installed"
  printf 'running=%s\n' "$running"
  printf 'qq_running=%s\n' "$qq_up"
  printf 'linuxqq_ready=%s\n' "$(linuxqq_ready && echo 1 || echo 0)"
  printf 'version=%s\n' "$SL_VERSION"
  printf 'home=%s\n' "$SL_HOME"
  printf 'bind_host=%s\n' "$SL_BIND_HOST"
  printf 'webui_port=%s\n' "$SL_WEBUI_PORT"
  printf 'vnc_port=%s\n' "$SL_VNC_PORT"
  printf 'onebot_ws_port=%s\n' "$SL_ONEBOT_WS_PORT"
  printf 'onebot_http_port=%s\n' "$SL_ONEBOT_HTTP_PORT"
  printf 'webui_url=%s\n' "http://127.0.0.1:$SL_WEBUI_PORT/"
  printf 'vnc_url=%s\n' "http://127.0.0.1:$SL_VNC_PORT/vnc.html"
  printf 'onebot_url=%s\n' "ws://127.0.0.1:$SL_ONEBOT_WS_PORT/"
  printf 'astrbot_ws_url=%s\n' "$SL_ASTRBOT_WS_URL"
  printf 'onebot_token=%s\n' "$token"
  printf 'display=%s\n' ":$SL_DISPLAY_NUM"
  printf 'pid=%s\n' "$(pid_of snowluma 2>/dev/null || echo 0)"
}

cmd_logs() {
  need_dirs
  tail -n "${2:-60}" "$SL_LOG_DIR/snowluma.log" 2>/dev/null || die "暂无日志"
}

cmd_uninstall() {
  cmd_stop
  stop_pid qq
  rm -rf "$SL_HOME"
  if [ "${1:-}" = "--clean-data" ]; then
    rm -rf "$SL_RT"
  fi
  log "SnowLuma 已卸载${1:+（含数据）}"
}

usage() {
  cat <<'EOF'
Usage: snowluma.sh <command>

  install              安装/升级 SnowLuma（依赖 + 官方 arm64 包 + 配置）
  start                启动 Xvfb + fluxbox + x11vnc + noVNC + SnowLuma
  stop                 停止全部进程
  restart              重启
  status               key=value 状态输出
  qq                   启动独立 QQ 实例（登录扫码用）
  vnc                  只重启扫码（noVNC）部分
  logs [n]             查看 SnowLuma 日志
  uninstall [--clean-data]
EOF
}

main() {
  need_dirs
  case "${1:-}" in
    install) install_snowluma ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    qq) cmd_qq ;;
    vnc) cmd_vnc ;;
    logs) cmd_logs "$@" ;;
    uninstall) shift; cmd_uninstall "${1:-}" ;;
    help|--help|-h|'') usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
