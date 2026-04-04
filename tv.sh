#!/bin/sh
# TVBoxOSC_final_fixed.sh
set -eu

echo "================================================================"
echo "                   📺 盒子订阅同步服务 "
echo "================================================================"
echo ""

SERVICE_NAME="tvboxosc"
SERVE_DIR="/opt"
PACKAGE_DIR_NAME="TVBoxOSC"
PACKAGE_DIR="$SERVE_DIR/$PACKAGE_DIR_NAME"
LIVE_FILE="$SERVE_DIR/tv.m3u"
API_REL_PATH="$PACKAGE_DIR_NAME/tvbox/api.json"
API_FILE="$SERVE_DIR/$API_REL_PATH"
INDEX_FILE="$SERVE_DIR/index.html"
SYNC_SCRIPT="/opt/tvboxosc_sync.sh"
SYNC_LOG="/var/log/tvboxosc_sync.log"
FIREWALL_NOTE="仅在选择开放 WAN 时创建端口转发规则"
LIVE_URL='https://codeberg.org/Jsnzkpg/Jsnzkpg/raw/branch/Jsnzkpg/Jsnzkpg1.m3u'
VOD_URL='https://raw.githubusercontent.com/PizazzGY/NewTVBox/main/%E5%8D%95%E7%BA%BF%E8%B7%AF.zip'
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

install_unzip_if_needed() {
    if command -v unzip >/dev/null 2>&1; then
        return 0
    fi
    info "未检测到 unzip，尝试安装..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 || true
        opkg install unzip >/dev/null 2>&1 || fail "安装 unzip 失败，请手动安装 unzip"
    elif command -v apk >/dev/null 2>&1; then
        apk add unzip >/dev/null 2>&1 || fail "安装 unzip 失败，请手动安装 unzip"
    else
        fail "系统没有 unzip，也没有可用包管理器安装它"
    fi
}

check_port_conflict() {
    if uci show uhttpd 2>/dev/null | grep -v "^uhttpd\.${SERVICE_NAME}\." | awk -F= -v p="$PORT" '
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
    info "清理旧 tvboxosc 服务..."
    uci -q delete uhttpd.$SERVICE_NAME || true
    uci commit uhttpd >/dev/null 2>&1 || true
    
    uci -q delete firewall.$SERVICE_NAME || true
    uci commit firewall >/dev/null 2>&1 || true
    
    touch /etc/crontabs/root
    # 修复：以同步脚本路径作为唯一特征进行清理
    grep -v "$SYNC_SCRIPT" /etc/crontabs/root > /etc/crontabs/root.tmp || true
    mv /etc/crontabs/root.tmp /etc/crontabs/root
    rm -f "$SYNC_SCRIPT"
    /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
}

fetch_file() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 -o "$out" "$url"
    else
        wget --timeout=300 --tries=1 -O "$out" "$url"
    fi
}

check_vod_content() {
    dir="$1"
    [ -f "$dir/$PACKAGE_DIR_NAME/tvbox/api.json" ]
}

write_index() {
    cat > "$INDEX_FILE" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>tvboxosc</title></head>
<body>
<h2>tvboxosc 已部署</h2>
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
    write_index
    if ! touch "$SYNC_LOG" 2>/dev/null; then
        info "日志文件预创建失败，后续将依赖 cron 重定向自动生成：$SYNC_LOG"
    fi
}

sync_subscriptions() {
    TMP_DIR="$(mktemp -d /tmp/tvboxosc.XXXXXX)"
    trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

    info "拉取直播订阅..."
    fetch_file "$LIVE_URL" "$TMP_DIR/live.m3u"
    [ -s "$TMP_DIR/live.m3u" ] || fail "直播订阅下载为空"
    grep -Eq '^#EXTM3U|https?://' "$TMP_DIR/live.m3u" || fail "直播订阅内容疑似无效"

    info "拉取点播订阅 ZIP..."
    fetch_file "$VOD_URL" "$TMP_DIR/vod.zip"
    [ -s "$TMP_DIR/vod.zip" ] || fail "点播订阅 ZIP 下载为空"
    unzip -tq "$TMP_DIR/vod.zip" >/dev/null 2>&1 || fail "点播订阅 ZIP 完整性校验失败"

    info "解压点播订阅..."
    mkdir -p "$TMP_DIR/vod"
    unzip -oq "$TMP_DIR/vod.zip" -d "$TMP_DIR/vod" || fail "点播订阅解压失败"
    check_vod_content "$TMP_DIR/vod" || fail "点播主文件缺失：$PACKAGE_DIR_NAME/tvbox/api.json"

    info "写入本地文件..."
    rm -rf "/opt/${PACKAGE_DIR_NAME}.new" "/opt/${PACKAGE_DIR_NAME}.old"
    mkdir -p "/opt/${PACKAGE_DIR_NAME}.new"
    cp -a "$TMP_DIR/vod/$PACKAGE_DIR_NAME/." "/opt/${PACKAGE_DIR_NAME}.new/"
    [ ! -d "$PACKAGE_DIR" ] || mv "$PACKAGE_DIR" "/opt/${PACKAGE_DIR_NAME}.old"
    mv "/opt/${PACKAGE_DIR_NAME}.new" "$PACKAGE_DIR" || { [ ! -d "/opt/${PACKAGE_DIR_NAME}.old" ] || mv "/opt/${PACKAGE_DIR_NAME}.old" "$PACKAGE_DIR"; fail "点播目录切换失败"; }
    rm -rf "/opt/${PACKAGE_DIR_NAME}.old"
    cp "$TMP_DIR/live.m3u" "$LIVE_FILE"
    [ -f "$API_FILE" ] || fail "正式目录缺少点播主文件：$API_REL_PATH"
    write_index
    info "点播主文件检测成功：$API_FILE"

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
    CRON_FILE="/etc/crontabs/root"
    [ ! -f "$CRON_FILE" ] && touch "$CRON_FILE"
    
    # 修复：原子化重建计划任务，去掉尾部注释，严格清洗空行
    grep -v "$SYNC_SCRIPT" "$CRON_FILE" \
        | grep -v '^[[:space:]]*$' \
        | sed 's/[[:space:]]*$//' \
        > "$CRON_FILE.tmp"
        
    for h in $HOURS; do
        # 严格使用 printf 保证行尾存在 \n，去除容易被丢弃的注释标签
        printf "0 %s * * * /bin/sh %s\n" "$h" "$SYNC_SCRIPT" >> "$CRON_FILE.tmp"
    done
    
    mv "$CRON_FILE.tmp" "$CRON_FILE"
    chmod 600 "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
}

write_sync_script() {
    cat > "$SYNC_SCRIPT" <<'EOF'
#!/bin/sh
set -eu

# 修复：全局霸王条款重定向！本脚本所有输出（含报错）强制写入日志文件
exec >> "/var/log/tvboxosc_sync.log" 2>&1

SERVE_DIR="/opt"
PACKAGE_DIR_NAME="TVBoxOSC"
PACKAGE_DIR="$SERVE_DIR/$PACKAGE_DIR_NAME"
LIVE_FILE="$SERVE_DIR/tv.m3u"
API_REL_PATH="$PACKAGE_DIR_NAME/tvbox/api.json"
API_FILE="$SERVE_DIR/$API_REL_PATH"
INDEX_FILE="$SERVE_DIR/index.html"
LIVE_URL='https://codeberg.org/Jsnzkpg/Jsnzkpg/raw/branch/Jsnzkpg/Jsnzkpg1.m3u'
VOD_URL='https://raw.githubusercontent.com/PizazzGY/NewTVBox/main/%E5%8D%95%E7%BA%BF%E8%B7%AF.zip'
info() { echo "[INFO] $*"; }
fetch_file() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 -o "$out" "$url"
    else
        wget --timeout=300 --tries=1 -O "$out" "$url"
    fi
}
check_vod_content() {
    dir="$1"
    [ -f "$dir/$PACKAGE_DIR_NAME/tvbox/api.json" ]
}
write_index() {
    cat > "$INDEX_FILE" <<EOT
<!doctype html>
<html><head><meta charset="utf-8"><title>tvboxosc</title></head>
<body>
<h2>tvboxosc 已部署</h2>
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
EOT
}
echo "================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务开始: 同步 TVBox 数据"
TMP_DIR="$(mktemp -d /tmp/tvboxosc.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
fetch_file "$LIVE_URL" "$TMP_DIR/live.m3u"
[ -s "$TMP_DIR/live.m3u" ] || { echo '[ERROR] 直播订阅下载为空'; exit 1; }
grep -Eq '^#EXTM3U|https?://' "$TMP_DIR/live.m3u" || { echo '[ERROR] 直播订阅内容疑似无效'; exit 1; }
fetch_file "$VOD_URL" "$TMP_DIR/vod.zip"
[ -s "$TMP_DIR/vod.zip" ] || { echo '[ERROR] 点播订阅 ZIP 下载为空'; exit 1; }
unzip -tq "$TMP_DIR/vod.zip" >/dev/null 2>&1 || { echo '[ERROR] 点播订阅 ZIP 完整性校验失败'; exit 1; }
mkdir -p "$TMP_DIR/vod"
unzip -oq "$TMP_DIR/vod.zip" -d "$TMP_DIR/vod" || { echo '[ERROR] 点播订阅解压失败'; exit 1; }
check_vod_content "$TMP_DIR/vod" || { echo '[ERROR] 点播主文件缺失：TVBoxOSC/tvbox/api.json'; exit 1; }
rm -rf "/opt/${PACKAGE_DIR_NAME}.new" "/opt/${PACKAGE_DIR_NAME}.old"
mkdir -p "/opt/${PACKAGE_DIR_NAME}.new"
cp -a "$TMP_DIR/vod/$PACKAGE_DIR_NAME/." "/opt/${PACKAGE_DIR_NAME}.new/"
[ ! -d "$PACKAGE_DIR" ] || mv "$PACKAGE_DIR" "/opt/${PACKAGE_DIR_NAME}.old"
mv "/opt/${PACKAGE_DIR_NAME}.new" "$PACKAGE_DIR" || { [ ! -d "/opt/${PACKAGE_DIR_NAME}.old" ] || mv "/opt/${PACKAGE_DIR_NAME}.old" "$PACKAGE_DIR"; echo '[ERROR] 点播目录切换失败'; exit 1; }
rm -rf "/opt/${PACKAGE_DIR_NAME}.old"
cp "$TMP_DIR/live.m3u" "$LIVE_FILE"
[ -f "$API_FILE" ] || { echo '[ERROR] 正式目录缺少点播主文件'; exit 1; }
write_index
info "点播主文件检测成功：$API_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务结束: 成功更新并替换数据"
EOF
    chmod +x "$SYNC_SCRIPT"
}

show_result() {
    LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo '路由器LAN_IP')
    echo
    echo "部署完成"
    echo "服务名称: $SERVICE_NAME"
    echo "服务根目录: $SERVE_DIR"
    echo "点播目录: $PACKAGE_DIR"
    echo "访问端口: $PORT"
    echo "同步时间: $HOURS"
    echo "WAN开放: $WAN_OPEN"
    echo "同步日志: $SYNC_LOG"
    echo "防火墙说明: $FIREWALL_NOTE"
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
    install_unzip_if_needed
    check_port_conflict
    cleanup_old_service
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
echo "               📺 盒子订阅同步服务 部署完成！"
echo "================================================================"