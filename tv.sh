#!/bin/sh
# TVBoxOSC_v5_Independent.sh
# 极简独立版：直播与点播双轨解绑，互不影响，一方失败不会阻断另一方
set -u

echo "================================================================"
echo "                   📺 盒子订阅同步服务 (双轨独立更新版) "
echo "================================================================"
echo ""

SERVICE_NAME="osc_vod"
SERVE_DIR="/opt"
PACKAGE_DIR_NAME="TVBoxOSC"
PACKAGE_DIR="$SERVE_DIR/$PACKAGE_DIR_NAME"
LIVE_FILE="$SERVE_DIR/tv.m3u"
API_REL_PATH="$PACKAGE_DIR_NAME/tvbox/api.json"
API_FILE="$SERVE_DIR/$API_REL_PATH"
INDEX_FILE="$SERVE_DIR/index.html"
SYNC_SCRIPT="/opt/osc_sync.sh"
SYNC_LOG="/var/log/osc_sync.log"

FIREWALL_NOTE="仅在选择开放 WAN 时创建端口转发规则"
# 最新双线直连源
LIVE_URL='https://live.445569.xyz/live.m3u'
VOD_URL='https://9877.kstore.space/one.json'

DEFAULT_PORT="7799"
DEFAULT_HOURS="1 17"
DEFAULT_WAN_OPEN="n"

info() { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"; }

ask_port() {
    printf '请输入访问端口 [默认 %s]: ' "$DEFAULT_PORT"
    read -r PORT
    [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
    case "$PORT" in ''|*[!0-9]*) fail "端口必须是数字";; esac
    [ "$PORT" -ge 1 ] 2>/dev/null && [ "$PORT" -le 65535 ] 2>/dev/null || fail "端口范围必须在 1-65535"
}

ask_hours() {
    printf '请输入同步小时，空格分隔 [默认 "%s"]: ' "$DEFAULT_HOURS"
    read -r HOURS
    [ -n "$HOURS" ] || HOURS="$DEFAULT_HOURS"
    CLEAN=""
    for h in $HOURS; do
        case "$h" in ''|*[!0-9]*) fail "同步小时必须是 0-23 的数字";; esac
        [ "$h" -ge 0 ] 2>/dev/null && [ "$h" -le 23 ] 2>/dev/null || fail "同步小时必须是 0-23"
        case " $CLEAN " in *" $h "*) ;; *) CLEAN="$CLEAN $h";; esac
    done
    HOURS=$(echo "$CLEAN" | xargs)
    [ -n "$HOURS" ] || fail "同步小时不能为空"
}

ask_wan_open() {
    printf '是否开放 WAN 访问？[y/N]: '
    read -r WAN_OPEN
    [ -n "$WAN_OPEN" ] || WAN_OPEN="$DEFAULT_WAN_OPEN"
    case "$WAN_OPEN" in y|Y) WAN_OPEN='y' ;; n|N) WAN_OPEN='n' ;; *) fail "请输入 y 或 n" ;; esac
}

check_port_conflict() {
    if uci show uhttpd 2>/dev/null | grep -v "^uhttpd\.${SERVICE_NAME}\." | grep -v "^uhttpd\.tvboxosc\." | awk -F= -v p="$PORT" '
        /listen_http=/ {
            gsub(/\047|\"/, "", $2)
            n=split($2, a, /[[:space:]]+/)
            for (i=1; i<=n; i++) if (a[i] ~ (":" p "$")) found=1
        }
        END { exit(found ? 0 : 1) }
    '; then
        fail "端口 $PORT 已被其他 uhttpd 配置占用，请换一个端口"
    fi
}

cleanup_old_service() {
    info "清理历史服务配置，释放端口..."
    uci -q delete uhttpd.$SERVICE_NAME || true
    uci -q delete uhttpd.tvboxosc || true
    uci commit uhttpd >/dev/null 2>&1 || true
    
    uci -q delete firewall.$SERVICE_NAME || true
    uci -q delete firewall.tvboxosc || true
    uci commit firewall >/dev/null 2>&1 || true
    
    crontab -l 2>/dev/null | grep -v "$SERVICE_NAME" | grep -v "$SYNC_SCRIPT" | grep -v "tvboxosc_sync.sh" > /tmp/_cron || true
    crontab /tmp/_cron 2>/dev/null || true
    rm -f /tmp/_cron
    
    rm -f "$SYNC_SCRIPT"
    rm -f "/opt/tvboxosc_sync.sh" 2>/dev/null || true
    /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
}

fetch_file() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 \
            --proto '=https' --tlsv1.2 \
            -o "$out" "$url"
    else
        case "$url" in https://*) ;; *) echo "[ERROR] 非HTTPS URL被拒绝: $url" >&2; return 1 ;; esac
        wget --timeout=300 --tries=1 -O "$out" "$url"
    fi
}

write_index() {
    cat > "$INDEX_FILE" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>osc_vod</title></head>
<body>
<h2>osc_vod 双轨极简版已部署</h2>
<p>直播订阅：<a id="live_link" href="/tv.m3u">/tv.m3u</a></p>
<p>点播订阅：<a id="vod_link" href="/$API_REL_PATH">/$API_REL_PATH</a></p>
<noscript>
<p>直播订阅：/tv.m3u</p>
<p>点播订阅：/$API_REL_PATH</p>
</noscript>
<script>
(function(){
  var base = window.location.protocol + '//' + window.location.host;
  var live = base + '/tv.m3u';
  var vod = base + '/$API_REL_PATH';
  var a = document.getElementById('live_link');
  var b = document.getElementById('vod_link');
  a.href = live; a.textContent = live;
  b.href = vod; b.textContent = vod;
})();
</script>
</body></html>
EOF
}

prepare_dirs() {
    mkdir -p "$SERVE_DIR"
    mkdir -p "$SERVE_DIR/$PACKAGE_DIR_NAME/tvbox"
    write_index
    if ! touch "$SYNC_LOG" 2>/dev/null; then
        info "日志文件预创建失败，后续将依赖 cron 重定向自动生成：$SYNC_LOG"
    fi
}

sync_subscriptions() {
    TMP_DIR="$(mktemp -d /tmp/tvboxosc.XXXXXX)"
    trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

    # 独立模块 1：直播拉取
    info "拉取直播订阅..."
    if fetch_file "$LIVE_URL" "$TMP_DIR/live.m3u" && [ -s "$TMP_DIR/live.m3u" ] && grep -Eq '^#EXTM3U|https?://' "$TMP_DIR/live.m3u"; then
        cp "$TMP_DIR/live.m3u" "$LIVE_FILE"
        info "直播订阅更新成功"
    else
        echo "[WARNING] 直播源拉取或校验失败，继续保留旧版直播数据" >&2
    fi

    # 独立模块 2：点播拉取
    info "拉取点播订阅..."
    if fetch_file "$VOD_URL" "$TMP_DIR/api.json" && [ -s "$TMP_DIR/api.json" ]; then
        
        # 🌟 智能魔法：自动截取当前 VOD_URL 的基础目录路径
        BASE_URL="${VOD_URL%/*}/"
        # 🌟 动态替换：把所有的 "./" 自动替换成提取出的真实绝对路径
        sed -i "s#\"\./#\"$BASE_URL#g" "$TMP_DIR/api.json"
        
        cp "$TMP_DIR/api.json" "$API_FILE"
        info "点播订阅更新成功(已动态修复相对路径)"
    else
        echo "[WARNING] 点播源拉取失败，继续保留旧版点播数据" >&2
    fi
    
    write_index
    rm -rf "$TMP_DIR"
    trap - EXIT INT TERM
}

setup_uhttpd() {
    uci -q delete uhttpd.$SERVICE_NAME || true
    uci set uhttpd.$SERVICE_NAME='uhttpd'
    uci set uhttpd.$SERVICE_NAME.listen_http="0.0.0.0:$PORT"
    uci add_list uhttpd.$SERVICE_NAME.listen_http="[::]:$PORT"
    uci set uhttpd.$SERVICE_NAME.home="$SERVE_DIR"
    uci set uhttpd.$SERVICE_NAME.index_page='index.html'
    uci set uhttpd.$SERVICE_NAME.no_dirlists='1'
    uci set uhttpd.$SERVICE_NAME.max_requests='16'
    uci commit uhttpd
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || fail "uhttpd 重载失败"
}

setup_firewall() {
    uci -q delete firewall.$SERVICE_NAME || true
    
    if [ "$WAN_OPEN" = 'y' ]; then
        CURRENT_LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || echo '192.168.1.1')
        uci set firewall.$SERVICE_NAME='redirect'
        uci set firewall.$SERVICE_NAME.name="$SERVICE_NAME"
        uci set firewall.$SERVICE_NAME.src='wan'
        uci set firewall.$SERVICE_NAME.src_dport="$PORT"
        uci set firewall.$SERVICE_NAME.dest='lan'
        uci set firewall.$SERVICE_NAME.dest_ip="$CURRENT_LAN_IP"
        uci set firewall.$SERVICE_NAME.dest_port="$PORT"
        uci set firewall.$SERVICE_NAME.proto='tcp'
        uci set firewall.$SERVICE_NAME.target='DNAT'
        uci commit firewall
        
        if /etc/init.d/firewall reload >/dev/null 2>&1; then
            info "防火墙规则已更新 (已配置端口转发)"
        else
            info "防火墙 reload 返回非零（规则已写入 UCI）"
        fi
    else
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
    fi
}

setup_cron() {
    crontab -l 2>/dev/null | grep -v "$SERVICE_NAME" | grep -v "$SYNC_SCRIPT" > /tmp/_cron || true
    
    for h in $HOURS; do
        echo "0 $h * * * /bin/sh $SYNC_SCRIPT" >> /tmp/_cron
    done
    
    crontab /tmp/_cron && rm -f /tmp/_cron
    /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
    info "计划任务已写入: root crontab"
}

write_sync_script() {
    cat > "$SYNC_SCRIPT" <<'EOF'
#!/bin/sh
set -u

exec >> "/var/log/osc_sync.log" 2>&1

SERVE_DIR="/opt"
PACKAGE_DIR_NAME="TVBoxOSC"
PACKAGE_DIR="$SERVE_DIR/$PACKAGE_DIR_NAME"
LIVE_FILE="$SERVE_DIR/tv.m3u"
API_REL_PATH="$PACKAGE_DIR_NAME/tvbox/api.json"
API_FILE="$SERVE_DIR/$API_REL_PATH"
INDEX_FILE="$SERVE_DIR/index.html"

LIVE_URL='https://live.445569.xyz/live.m3u'
VOD_URL='https://9877.kstore.space/one.json'

info() { echo "[INFO] $*"; }
fetch_file() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 \
            --proto '=https' --tlsv1.2 \
            -o "$out" "$url"
    else
        case "$url" in https://*) ;; *) echo "[ERROR] 非HTTPS URL被拒绝: $url" >&2; return 1 ;; esac
        wget --timeout=300 --tries=1 -O "$out" "$url"
    fi
}

echo "================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务开始: 同步极简版 TVBox 数据"
TMP_DIR="$(mktemp -d /tmp/tvboxosc.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$SERVE_DIR/$PACKAGE_DIR_NAME/tvbox"

# 独立拉取：直播源
if fetch_file "$LIVE_URL" "$TMP_DIR/live.m3u" && [ -s "$TMP_DIR/live.m3u" ] && grep -Eq '^#EXTM3U|https?://' "$TMP_DIR/live.m3u"; then
    cp "$TMP_DIR/live.m3u" "$LIVE_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] 直播订阅更新成功"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] 直播源拉取或校验失败，保留旧版数据"
fi

# 独立拉取：点播源
if fetch_file "$VOD_URL" "$TMP_DIR/api.json" && [ -s "$TMP_DIR/api.json" ]; then
    
    # 🌟 智能魔法：自动截取当前 VOD_URL 的基础目录路径
    BASE_URL="${VOD_URL%/*}/"
    # 🌟 动态替换：把所有的 "./" 自动替换成提取出的真实绝对路径
    sed -i "s#\"\./#\"$BASE_URL#g" "$TMP_DIR/api.json"
    
    cp "$TMP_DIR/api.json" "$API_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] 点播订阅更新成功(已动态修复相对路径)"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] 点播源拉取失败，保留旧版数据"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务结束: 双轨更新流程执行完毕"
rm -rf "$TMP_DIR"
trap - EXIT INT TERM
EOF
    chmod 755 "$SYNC_SCRIPT"
}

show_result() {
    LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo '路由器LAN_IP')
    echo
    echo "部署完成"
    echo "服务名称: $SERVICE_NAME"
    echo "访问端口: $PORT"
    echo "同步时间: $HOURS"
    echo "同步日志: $SYNC_LOG"
    echo "直播订阅: http://$LAN_IP:$PORT/tv.m3u"
    echo "点播订阅: http://$LAN_IP:$PORT/$API_REL_PATH"
    echo
}

main() {
    [ "$(id -u)" = "0" ] || fail "请用 root 运行"
    need_cmd uci
    need_cmd grep
    need_cmd cp
    need_cmd mv
    need_cmd rm
    need_cmd mkdir
    need_cmd xargs
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "需要 curl 或 wget"
    
    ask_port
    ask_hours
    ask_wan_open

    cleanup_old_service
    check_port_conflict
    
    prepare_dirs
    write_sync_script
    sync_subscriptions
    setup_uhttpd
    setup_firewall
    setup_cron
    show_result
}

main "$@"

echo ""
echo "================================================================"
echo "               📺 盒子订阅同步服务 (极简双轨版) 部署完成！"
echo "================================================================"
