#!/bin/sh
# Livis 主机端一键引导
#
#   curl -fsSL https://livis.fastaibest.xyz/install.sh | sh
#
# 干四件事：装 openhook（agent 事件守护进程）→ 配 Claude Code hooks →
# 常驻（systemd user / launchd）→ 扫码配对。可选依赖 mosh / herdr / qrencode 会问你要不要装。
#
# 全程幂等：重复跑只会补齐缺的部分，不会重复写 hooks、不会重复建服务。
#
# 环境变量（非交互场景用）：
#   LIVIS_YES=1        全部按默认值走，不提问（等价 --yes）
#   LIVIS_NO_PAIR=1    跳过最后的配对
#   LIVIS_PREFIX=...   openhook 安装目录（默认 ~/.local/bin）
#   LIVIS_HOST=...     配对二维码里写的地址（默认自动探测本机 IP）
#   LIVIS_SSH_PORT=... 默认 22
set -eu

REPO_SLUG="lrsyddrl/livis-releases"
DL_BASE="https://github.com/$REPO_SLUG/releases/latest/download"
PREFIX="${LIVIS_PREFIX:-$HOME/.local/bin}"
BIN="$PREFIX/openhook"
ADDR="127.0.0.1:7391"
YES="${LIVIS_YES:-}"
NO_PAIR="${LIVIS_NO_PAIR:-}"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    --no-pair) NO_PAIR=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
  esac
done

# ---------- 输出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m')
else
  B=''; D=''; R=''
fi
step()  { printf '\n%s==>%s %s%s\n' "$B" "$R" "$B" "$1$R"; }
info()  { printf '    %s\n' "$1"; }
warn()  { printf '    %s!%s %s\n' "$B" "$R" "$1" >&2; }
dim()   { printf '    %s%s%s\n' "$D" "$1" "$R"; }
die()   { printf '\n%s✗%s %s\n' "$B" "$R" "$1" >&2; exit 1; }

# ---------- 交互 ----------
# curl | sh 时 stdin 是脚本本身，read 读不到用户输入——必须从 /dev/tty 读。
# 没有 tty（CI、nohup）就按默认值走，绝不卡住。
TTY=''
[ -e /dev/tty ] && [ -r /dev/tty ] && TTY=/dev/tty

# ask "问题" "Y" -> 默认 yes；ask "问题" "N" -> 默认 no
ask() {
  _q="$1"; _def="$2"
  if [ -n "$YES" ] || [ -z "$TTY" ]; then
    [ "$_def" = "Y" ] && return 0 || return 1
  fi
  if [ "$_def" = "Y" ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
  printf '    %s %s ' "$_q" "$_hint"
  read -r _a < "$TTY" || _a=''
  case "${_a:-$_def}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- 平台探测 ----------
step "检查环境"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
  linux|darwin) ;;
  *) die "只支持 Linux 和 macOS，当前是 $OS" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构 $(uname -m)（只有 amd64 / arm64 的构建）" ;;
esac
command -v curl >/dev/null 2>&1 || die "缺 curl，先装上再跑"
command -v ssh-keygen >/dev/null 2>&1 || die "缺 ssh-keygen（openssh 客户端），先装上再跑"
info "$OS/$ARCH · 用户 $(id -un)"

# 包管理器（装可选依赖时用）
PKG=''; PKG_INSTALL=''
if command -v brew >/dev/null 2>&1;    then PKG=brew;   PKG_INSTALL="brew install"
elif command -v apt-get >/dev/null 2>&1; then PKG=apt;  PKG_INSTALL="sudo apt-get install -y"
elif command -v dnf >/dev/null 2>&1;   then PKG=dnf;    PKG_INSTALL="sudo dnf install -y"
elif command -v pacman >/dev/null 2>&1; then PKG=pacman; PKG_INSTALL="sudo pacman -S --noconfirm"
elif command -v apk >/dev/null 2>&1;   then PKG=apk;    PKG_INSTALL="sudo apk add"
fi
[ -n "$PKG" ] && dim "包管理器：$PKG" || dim "没找到已知包管理器，可选依赖需要你自己装"

# 装一个包，装不上不致命
try_install() {
  _pkg="$1"
  [ -z "$PKG_INSTALL" ] && { warn "不知道怎么装 $_pkg，跳过"; return 1; }
  info "安装 $_pkg …"
  # shellcheck disable=SC2086
  if [ "$PKG" = apt ]; then sudo apt-get update -qq >/dev/null 2>&1 || true; fi
  $PKG_INSTALL "$_pkg" >/dev/null 2>&1 || { warn "$_pkg 安装失败，跳过（不影响主流程）"; return 1; }
  return 0
}

# ---------- 1. openhook ----------
step "1/4  安装 openhook"
mkdir -p "$PREFIX"
NEED_DL=1
if [ -x "$BIN" ]; then
  info "已存在：$BIN"
  ask "重新下载覆盖为最新版？" "Y" || NEED_DL=''
fi
if [ -n "$NEED_DL" ]; then
  URL="$DL_BASE/openhook-$OS-$ARCH"
  info "下载 openhook-$OS-$ARCH …"
  TMP="$BIN.download.$$"
  curl -fsSL "$URL" -o "$TMP" || die "下载失败：$URL"
  chmod +x "$TMP"
  mv "$TMP" "$BIN"
  info "已装到 $BIN"
fi
# 装完立刻验证能跑，别等到后面才发现下错了架构。
# openhook 没有 --help，任何调用都以 2 退出——只有 126/127 才是真的执行不了。
"$BIN" >/dev/null 2>&1 || _rc=$?
case "${_rc:-0}" in
  126|127) die "openhook 无法执行（架构不匹配或文件损坏）：$BIN" ;;
esac

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    warn "$PREFIX 不在 PATH 里"
    dim "加到你的 shell 配置：export PATH=\"\$PATH:$PREFIX\""
    ;;
esac

# ---------- 2. Claude Code hooks ----------
step "2/4  配置 Claude Code hooks"
SETTINGS="$HOME/.claude/settings.json"
if ! command -v jq >/dev/null 2>&1; then
  info "合并 settings.json 需要 jq"
  if ask "现在安装 jq？" "Y"; then try_install jq || true; fi
fi

if command -v jq >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  # 备份一次再动，settings.json 里可能有用户自己的配置
  cp "$SETTINGS" "$SETTINGS.livis-bak" 2>/dev/null || true
  TMPJ=$(mktemp)
  # 已经有 openhook 的 hook 就不重复加（幂等）
  jq --arg bin "$BIN" '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    .hooks.Notification //= [] |
    if ([.hooks.PreToolUse[].hooks[]?.command] | any(contains("openhook"))) then .
    else .hooks.PreToolUse += [{"matcher": "", "hooks": [{"type": "command", "command": ($bin + " hook pretooluse"), "timeout": 60}]}]
    end |
    if ([.hooks.Notification[].hooks[]?.command] | any(contains("openhook"))) then .
    else .hooks.Notification += [{"matcher": "", "hooks": [{"type": "command", "command": ($bin + " hook notification")}]}]
    end
  ' "$SETTINGS" > "$TMPJ" && mv "$TMPJ" "$SETTINGS"
  info "已写入 $SETTINGS（原文件备份为 settings.json.livis-bak）"
else
  warn "没有 jq，请手工把下面这段合进 $SETTINGS："
  cat <<EOF
{
  "hooks": {
    "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "$BIN hook pretooluse", "timeout": 60}]}],
    "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "$BIN hook notification"}]}]
  }
}
EOF
fi

# ---------- 3. 常驻 ----------
step "3/4  让 openhook 常驻"
STARTED=''
if [ "$OS" = linux ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT="$HOME/.config/systemd/user/openhook.service"
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<EOF
[Unit]
Description=Livis agent hook daemon

[Service]
ExecStart=$BIN serve --addr $ADDR
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now openhook.service >/dev/null 2>&1 && STARTED="systemd user service"
  # 没开 linger 的话，SSH 断开后 user service 会被杀掉
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes'; then
      if ask "开启 linger（否则退出登录后 openhook 会被系统杀掉）？" "Y"; then
        sudo loginctl enable-linger "$(id -un)" >/dev/null 2>&1 && info "已开启 linger" || warn "linger 开启失败（需要 sudo）"
      fi
    fi
  fi
elif [ "$OS" = darwin ]; then
  PLIST="$HOME/Library/LaunchAgents/dev.livis.openhook.plist"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.livis.openhook</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>serve</string><string>--addr</string><string>$ADDR</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  launchctl load "$PLIST" >/dev/null 2>&1 && STARTED="launchd agent"
fi

if [ -n "$STARTED" ]; then
  info "已作为 $STARTED 启动并设为开机自启"
else
  warn "没有可用的服务管理器，需要你自己常驻："
  dim "$BIN serve --addr $ADDR &"
fi

# 实测端口是否真的起来了，而不是只看服务状态。
# 用只读的 /servers 探测：往 /hook 打会真的产生一条 agent 事件推到手机上，
# 装个软件不该在用户收件箱里留下垃圾。
sleep 1
if curl -fsS -m 3 "http://$ADDR/servers" >/dev/null 2>&1; then
  info "自检通过：openhook 正在 $ADDR 上服务"
else
  warn "openhook 端口没响应，稍后可用 '$BIN serve --addr $ADDR' 手动排查"
fi

# ---------- 可选依赖 ----------
step "可选组件"
if command -v mosh-server >/dev/null 2>&1; then
  info "mosh 已装（弱网漫游可用）"
else
  info "mosh：手机切 WiFi / 进电梯不掉线，强烈建议装"
  if ask "安装 mosh？" "Y"; then try_install mosh && info "mosh 装好了" || true; fi
fi

if command -v herdr >/dev/null 2>&1; then
  info "herdr 已装"
elif command -v tmux >/dev/null 2>&1 || command -v zellij >/dev/null 2>&1; then
  info "已有 tmux/zellij，可直接用；herdr 是更适合 agent 的选择"
  if ask "另外装 herdr？" "N"; then
    curl -fsSL https://herdr.dev/install.sh | sh && info "herdr 装好了" || warn "herdr 安装失败，跳过"
  fi
else
  info "没有检测到多路复用器。挂上之后手机断线才能接回同一个会话"
  if ask "安装 herdr（推荐）？" "Y"; then
    curl -fsSL https://herdr.dev/install.sh | sh && info "herdr 装好了" || warn "herdr 安装失败，可改用 tmux"
  fi
fi

if ! command -v qrencode >/dev/null 2>&1; then
  info "qrencode：能在终端里直接画出配对二维码"
  if ask "安装 qrencode？" "Y"; then try_install qrencode || true; fi
fi

# ---------- 4. 配对 ----------
if [ -n "$NO_PAIR" ]; then
  step "4/4  配对（已跳过）"
  dim "以后随时可以重跑本脚本完成配对"
else
  step "4/4  与手机配对"

  # sshd 没起来的话配对了也连不上，先看一眼
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE '[:.]22\b' || warn "本机 22 端口没在监听，确认 sshd 已启动"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep LISTEN | grep -qE '[.:]22 ' || warn "本机 22 端口没在监听（macOS 需在「系统设置 → 通用 → 共享」里打开远程登录）"
  fi

  PORT="${LIVIS_SSH_PORT:-22}"
  USER_NAME="${LIVIS_USER:-$(id -un)}"
  HOST="${LIVIS_HOST:-}"
  if [ -z "$HOST" ]; then
    # hostname -I 是 Linux 专有，macOS 得换别的路子
    if [ "$OS" = darwin ]; then
      for i in en0 en1 en2; do
        HOST=$(ipconfig getifaddr "$i" 2>/dev/null) && [ -n "$HOST" ] && break
      done
      [ -z "$HOST" ] && HOST=$(ifconfig 2>/dev/null | awk '/inet /&&$2!="127.0.0.1"{print $2; exit}')
    else
      HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
      [ -z "$HOST" ] && HOST=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
    fi
    HOST="${HOST:-127.0.0.1}"
  fi

  KEY=$(mktemp -u "${TMPDIR:-/tmp}/livis-pair.XXXXXX")
  rm -f "$KEY"
  ssh-keygen -t ed25519 -f "$KEY" -N '' -C livis-pair-temp -q

  AUTH="${LIVIS_AUTH_KEYS:-$HOME/.ssh/authorized_keys}"
  mkdir -p "$(dirname "$AUTH")"
  chmod 700 "$(dirname "$AUTH")" 2>/dev/null || true
  touch "$AUTH"
  chmod 600 "$AUTH"
  cat "$KEY.pub" >> "$AUTH"

  B64KEY=$(base64 -w0 "$KEY" 2>/dev/null || base64 "$KEY" | tr -d '\n')
  rm -f "$KEY" "$KEY.pub"

  if [ -n "${LIVIS_AUTH_KEYS:-}" ]; then
    PAYLOAD=$(printf '{"v":1,"host":"%s","port":%s,"user":"%s","key_b64":"%s","auth_keys":"%s"}' "$HOST" "$PORT" "$USER_NAME" "$B64KEY" "$AUTH")
  else
    PAYLOAD=$(printf '{"v":1,"host":"%s","port":%s,"user":"%s","key_b64":"%s"}' "$HOST" "$PORT" "$USER_NAME" "$B64KEY")
  fi

  info "配对地址：$USER_NAME@$HOST:$PORT"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$PAYLOAD"
    info "在 Livis 里点「添加主机 → 扫码配对」，扫上面这个码"
  else
    info "没装 qrencode，把下面这行 JSON 粘到 App 的「粘贴配对 JSON」里："
    echo
    echo "$PAYLOAD"
  fi
  echo
  warn "二维码里含一把临时私钥，别截图外发；手机连上后会自动从 authorized_keys 里删掉它"
fi

step "完成"
info "openhook：$BIN"
[ -n "$STARTED" ] && info "常驻方式：$STARTED"
dim "手机连上本机后，agent 的审批请求会推到 Livis 的收件箱"
dim "官网 https://livis.fastaibest.xyz"
