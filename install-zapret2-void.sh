#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

VERSION=v1.0.5.2
ARCHIVE_NAME="zapret2-${VERSION}.tar.gz"
ARCHIVE_URL="https://github.com/bol-van/zapret2/releases/download/${VERSION}/${ARCHIVE_NAME}"
CHECKSUM_URL="https://github.com/bol-van/zapret2/releases/download/${VERSION}/sha256sum.txt"
ARCHIVE_SHA256=fb3bcf69e7d86b9fa2d60bd53c956ac06d9dcc3adf9392afd84865f1d94b1158
DNS_PROXY_VERSION=2.1.18
DNS_PROXY_ARCHIVE_NAME="dnscrypt-proxy-linux_x86_64-${DNS_PROXY_VERSION}.tar.gz"
DNS_PROXY_ARCHIVE_URL="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNS_PROXY_VERSION}/${DNS_PROXY_ARCHIVE_NAME}"
DNS_PROXY_ARCHIVE_SHA256=c8c8acb35b0f6619bfe8e4eed0c192672f8fd1964f467a42881905814e261c3e
DNS_PROXY_BIN=/usr/bin/dnscrypt-proxy
DNS_PROXY_USER=dnscrypt-proxy
DNS_PROXY_CONFIG=/etc/dnscrypt-proxy.toml
DNS_PROXY_SERVICE_DIR=/etc/sv/dnscrypt-proxy
DNS_PROXY_SERVICE_LINK=/var/service/dnscrypt-proxy
DNS_PROXY_CACHE_DIR=/var/cache/dnscrypt-proxy
DNS_PROXY_LOG=/var/log/dnscrypt-proxy.log
TARGET=/opt/zapret2
SERVICE_DIR=/etc/sv/zapret2
SERVICE_LINK=/var/service/zapret2
NFT_SERVICE_DIR=/etc/sv/nftables
NFTABLES_CONF=/etc/nftables.conf
MODULES_CONF=/etc/modules-load.d/zapret2.conf
BACKUP_ROOT=/etc/void-backup
LOCK_FILE=/run/lock/install-zapret2-void.lock
WS_USER=tpws
IFACE_WAN=eno1
CHECK_ONLY=0
FORCE=0
TMP_DIR=
STAGE_DIR=
BACKUP_DIR=
CHANGED=0
ROLLBACK_DONE=0
NEW_TARGET_INSTALLED=0
OLD_TARGET_PRESENT=0
OLD_TARGET_MOVED=0
OLD_SERVICE_DIR_PRESENT=0
OLD_SERVICE_DIR_MOVED=0
SERVICE_DIR_REPLACED=0
OLD_SERVICE_LINK_PRESENT=0
OLD_SERVICE_LINK_TARGET=
OLD_MODULES_PRESENT=0
USER_CREATED=0
DNS_USER_CREATED=0
DNS_SERVICE_WAS_UP=0
ZAPRET_WAS_UP=0
OLD_DNS_SERVICE_DIR_PRESENT=0
OLD_DNS_SERVICE_DIR_MOVED=0
DNS_SERVICE_DIR_REPLACED=0
OLD_DNS_SERVICE_LINK_PRESENT=0
OLD_DNS_SERVICE_LINK_TARGET=
OLD_DNS_CONFIG_PRESENT=0
OLD_DNS_BIN_PRESENT=0
DNS_CONFIG_REPLACED=0
DNS_BIN_REPLACED=0
NM_CONNECTION_UUID=
OLD_NM_DNS=
OLD_NM_IGNORE=
NFTABLES_WAS_UP=0
EXPECTED_RUN=
EXPECTED_FINISH=
EXPECTED_ZAPRET_RUN=
EXPECTED_ZAPRET_FINISH=
EXPECTED_DNS_RUN=
DNS_ARCHIVE_DIR=
DNS_BIN_STAGE=

log() {
    printf '[zapret2-void] %s\n' "$*"
}

warn() {
    printf '[zapret2-void] WARNING: %s\n' "$*" >&2
}

cleanup_user() {
    if [ "$USER_CREATED" -eq 1 ]; then
        userdel "$WS_USER" >/dev/null 2>&1 || true
        USER_CREATED=0
    fi
    if [ "$DNS_USER_CREATED" -eq 1 ]; then
        userdel "$DNS_PROXY_USER" >/dev/null 2>&1 || true
        DNS_USER_CREATED=0
    fi
}

die() {
    log "ERROR: $*" >&2
    if [ "$CHANGED" -eq 1 ] && [ "$ROLLBACK_DONE" -eq 0 ]; then
        rollback
    else
        cleanup_user
    fi
    exit 1
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
}

on_error() {
    local rc=$?
    trap - ERR
    if [ "$CHANGED" -eq 1 ] && [ "$ROLLBACK_DONE" -eq 0 ]; then
        rollback
    else
        cleanup_user
    fi
    exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

usage() {
    printf '%s\n' \
        'Usage: install-zapret2-void.sh [--check] [--force]' \
        '' \
        '  --check  Kiểm tra cấu hình đang chạy, không thay đổi hệ thống' \
        '  --force  Cho phép thay thế các script nftables không do trình cài đặt quản lý'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check)
                CHECK_ONLY=1
                ;;
            --force)
                FORCE=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "tham số không hợp lệ: $1"
                ;;
        esac
        shift
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "thiếu lệnh cần thiết: $1"
}

check_root() {
    [ "$(id -u)" -eq 0 ] || die 'phải chạy bằng quyền root'
}

check_system() {
    local os_id=
    if [ -r /etc/os-release ]; then
        os_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
    fi
    [ "$os_id" = void ] || die "không phải Void Linux: ${os_id:-unknown}"
    [ "$(uname -m)" = x86_64 ] || die 'bản phát hành này chỉ dành cho x86_64'
    [ -x /etc/runit/1 ] || die 'không tìm thấy Void runit stage 1'
    [ "$(ps -p 1 -o comm= | tr -d ' ')" = runit ] || die 'PID 1 không phải runit'
    [ -r "$NFTABLES_CONF" ] || die "không đọc được $NFTABLES_CONF"
    [ -x "$NFT_SERVICE_DIR/run" ] || die "không có $NFT_SERVICE_DIR/run"
    [ -e /var/service/nftables ] || die 'dịch vụ nftables chưa được bật'
    [ -e /opt ] || die 'không có /opt'
    ip link show "$IFACE_WAN" >/dev/null 2>&1 || die "interface WAN không tồn tại: $IFACE_WAN"
    for cmd in awk bash cat chpst chmod chown cmp cp curl date flock getent id install ip mkdir mktemp modprobe modinfo mv nmcli pgrep ps readlink rm runit sha256sum sh sleep ss sv tar tr useradd; do
        require_cmd "$cmd"
    done
    modinfo nft_queue >/dev/null 2>&1 || die 'kernel không có module nft_queue'
    modinfo nfnetlink_queue >/dev/null 2>&1 || die 'kernel không có module nfnetlink_queue'
    NM_CONNECTION_UUID=$(nmcli -g GENERAL.CON-UUID device show "$IFACE_WAN" 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s' "$line"
        break
    done)
    [ -n "$NM_CONNECTION_UUID" ] || die "không xác định được NetworkManager connection của $IFACE_WAN"
    OLD_NM_DNS=$(nmcli -g ipv4.dns connection show uuid "$NM_CONNECTION_UUID" 2>/dev/null || true)
    OLD_NM_IGNORE=$(nmcli -g ipv4.ignore-auto-dns connection show uuid "$NM_CONNECTION_UUID" 2>/dev/null || true)
}

create_templates() {
    [ -n "$TMP_DIR" ] || die 'TMP_DIR chưa được khởi tạo'
    EXPECTED_RUN="$TMP_DIR/nftables-run"
    EXPECTED_FINISH="$TMP_DIR/nftables-finish"
    EXPECTED_ZAPRET_RUN="$TMP_DIR/zapret2-run"
    EXPECTED_ZAPRET_FINISH="$TMP_DIR/zapret2-finish"
    EXPECTED_DNS_RUN="$TMP_DIR/dnscrypt-proxy-run"
    cat > "$EXPECTED_RUN" <<'EOF'
#!/bin/sh
exec 2>&1
[ ! -r /etc/nftables.conf ] && exit 0
nft -f /etc/nftables.conf
if [ -x /usr/bin/sv ] && [ -e /var/service/zapret2 ]; then
    /usr/bin/sv up zapret2
fi
exec chpst -b nftables pause
EOF
    cat > "$EXPECTED_FINISH" <<'EOF'
#!/bin/sh
if [ -x /usr/bin/sv ] && [ -e /var/service/zapret2 ]; then
    /usr/bin/sv down zapret2
fi
nft flush ruleset
EOF
    cat > "$EXPECTED_ZAPRET_RUN" <<'EOF'
#!/bin/sh
exec 2>&1
while ! nft list table inet void_filter >/dev/null 2>&1; do
    sleep 1
done
/opt/zapret2/init.d/sysv/zapret2 start
exec chpst -b tpws sleep infinity
EOF
    cat > "$EXPECTED_ZAPRET_FINISH" <<'EOF'
#!/bin/sh
/opt/zapret2/init.d/sysv/zapret2 stop
EOF
    cat > "$EXPECTED_DNS_RUN" <<'EOF'
#!/bin/sh
exec 2>&1
exec /usr/bin/dnscrypt-proxy -config /etc/dnscrypt-proxy.toml
EOF
    chmod 0755 "$EXPECTED_RUN" "$EXPECTED_FINISH" "$EXPECTED_ZAPRET_RUN" "$EXPECTED_ZAPRET_FINISH" "$EXPECTED_DNS_RUN"
}

check_managed_file() {
    local path=$1
    local expected=$2
    [ -e "$path" ] || return 0
    if cmp -s "$path" "$expected"; then
        return 0
    fi
    [ "$FORCE" -eq 1 ] || die "file đang tồn tại không do installer quản lý: $path; dùng --force sau khi kiểm tra"
}

check_existing_files() {
    create_templates
    check_managed_file "$NFT_SERVICE_DIR/run" "$EXPECTED_RUN"
    check_managed_file "$NFT_SERVICE_DIR/finish" "$EXPECTED_FINISH"
    check_managed_file "$SERVICE_DIR/run" "$EXPECTED_ZAPRET_RUN"
    check_managed_file "$SERVICE_DIR/finish" "$EXPECTED_ZAPRET_FINISH"
    check_managed_file "$DNS_PROXY_SERVICE_DIR/run" "$EXPECTED_DNS_RUN"
}

create_user() {
    if ! id -u "$WS_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /bin/false "$WS_USER"
        USER_CREATED=1
        log "đã tạo user hệ thống $WS_USER"
    else
        log "user $WS_USER đã tồn tại"
    fi
    if ! id -u "$DNS_PROXY_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir "$DNS_PROXY_CACHE_DIR" --shell /bin/false "$DNS_PROXY_USER"
        DNS_USER_CREATED=1
        log "đã tạo user hệ thống $DNS_PROXY_USER"
    else
        log "user $DNS_PROXY_USER đã tồn tại"
    fi
}

download_release() {
    local archive="$TMP_DIR/$ARCHIVE_NAME"
    local checksums="$TMP_DIR/sha256sum.txt"
    log "tải $VERSION từ repository chính thức"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --silent --show-error "$ARCHIVE_URL" -o "$archive" || die 'tải archive thất bại'
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 --silent --show-error "$CHECKSUM_URL" -o "$checksums" || die 'tải checksum thất bại'
    printf '%s  %s\n' "$ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null || die 'checksum archive không khớp'
    local members="$TMP_DIR/archive-members"
    tar -tzf "$archive" > "$members"
    local member
    while IFS= read -r member; do
        case "$member" in
            /*|../*|*/../*|*/..)
                die "archive chứa đường dẫn không an toàn: $member"
                ;;
        esac
    done < "$members"
    STAGE_DIR=$(mktemp -d /opt/zapret2.stage.XXXXXX)
    tar --strip-components=1 -xzf "$archive" -C "$STAGE_DIR"
    [ -f "$STAGE_DIR/install_bin.sh" ] || die 'archive thiếu install_bin.sh'
    [ -f "$STAGE_DIR/config.default" ] || die 'archive thiếu config.default'
    [ -d "$STAGE_DIR/lua" ] || die 'archive thiếu thư mục lua'
    [ -d "$STAGE_DIR/binaries/linux-x86_64" ] || die 'archive thiếu binary linux-x86_64'
    log "xác minh binary release"
    local name
    local expected
    local actual
    for name in ip2net mdig nfqws2; do
        expected=$(awk -v p="zapret2-$VERSION/binaries/linux-x86_64/$name" '$2 == p {print $1; exit}' "$checksums")
        [ -n "$expected" ] || die "không tìm thấy checksum cho $name"
        actual=$(sha256sum "$STAGE_DIR/binaries/linux-x86_64/$name" | awk '{print $1}')
        [ "$expected" = "$actual" ] || die "checksum binary $name không khớp"
    done
}

download_dns_proxy() {
    local archive="$TMP_DIR/$DNS_PROXY_ARCHIVE_NAME"
    local members="$TMP_DIR/dnscrypt-members"
    log "tải dnscrypt-proxy $DNS_PROXY_VERSION từ repository chính thức"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --silent --show-error "$DNS_PROXY_ARCHIVE_URL" -o "$archive" || die 'tải archive dnscrypt-proxy thất bại'
    printf '%s  %s\n' "$DNS_PROXY_ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null || die 'checksum archive dnscrypt-proxy không khớp'
    tar -tzf "$archive" > "$members"
    local member
    while IFS= read -r member; do
        case "$member" in
            /*|../*|*/../*|*/..)
                die "archive dnscrypt-proxy chứa đường dẫn không an toàn: $member"
                ;;
        esac
    done < "$members"
    DNS_ARCHIVE_DIR="$TMP_DIR/dnscrypt-proxy"
    mkdir -p "$DNS_ARCHIVE_DIR"
    tar -xzf "$archive" -C "$DNS_ARCHIVE_DIR"
    DNS_BIN_STAGE="$DNS_ARCHIVE_DIR/linux-x86_64/dnscrypt-proxy"
    [ -x "$DNS_BIN_STAGE" ] || die 'archive dnscrypt-proxy thiếu binary x86_64'
    local version_output
    version_output=$("$DNS_BIN_STAGE" -version 2>&1) || die 'không chạy được binary dnscrypt-proxy'
    [ "${version_output%%$'\n'*}" = "$DNS_PROXY_VERSION" ] || die "phiên bản dnscrypt-proxy không khớp: $DNS_PROXY_VERSION"
}

write_config() {
    cat > "$STAGE_DIR/config" <<'EOF'
FWTYPE=nftables
POSTNAT=1
WS_USER=tpws
QNUM=200
SET_MAXELEM=522288
IPSET_OPT="hashsize 262144 maxelem $SET_MAXELEM"
IP2NET_OPT4="--prefix-length=22-30 --v4-threshold=3/4"
IP2NET_OPT6="--prefix-length=56-64 --v6-threshold=5"
AUTOHOSTLIST_INCOMING_MAXSEQ=4096
AUTOHOSTLIST_RETRANS_MAXSEQ=32768
AUTOHOSTLIST_RETRANS_RESET=1
AUTOHOSTLIST_RETRANS_THRESHOLD=3
AUTOHOSTLIST_FAIL_THRESHOLD=3
AUTOHOSTLIST_FAIL_TIME=60
AUTOHOSTLIST_UDP_IN=1
AUTOHOSTLIST_UDP_OUT=4
AUTOHOSTLIST_DEBUGLOG=0
MDIG_THREADS=30
MDIG_EAGAIN=10
MDIG_EAGAIN_DELAY=500
GZIP_LISTS=1
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
NFQWS2_ENABLE=1
NFQWS2_PORTS_TCP=80,443
NFQWS2_PORTS_UDP=443
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=1
NFQWS2_UDP_PKT_OUT=5
NFQWS2_UDP_PKT_IN=1
NFQWS2_OPT="--filter-tcp=80 --filter-l7=http --in-range=x --out-range=-d20 --payload=http_req --lua-desync=http_hostcase:spell=hoSt --new --filter-tcp=443 --filter-l7=tls --in-range=x --out-range=-d20 --payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --in-range=x --out-range=-d5 --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=1:ip_ttl=2"
MODE_FILTER=none
FLOWOFFLOAD=donttouch
IFACE_LAN=
IFACE_WAN=eno1
IFACE_WAN6=
INIT_APPLY_FW=1
DISABLE_IPV6=1
FILTER_TTL_EXPIRED_ICMP=1
GETLIST=
EOF
    chmod 0644 "$STAGE_DIR/config"
}

write_dns_config() {
    cat > "$TMP_DIR/dnscrypt-proxy.toml" <<'EOF'
server_names = ['cloudflare']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
user_name = 'dnscrypt-proxy'
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
require_dnssec = false
require_nolog = true
require_nofilter = true
disabled_server_names = []
force_tcp = true
http3 = false
timeout = 8000
keepalive = 30
bootstrap_resolvers = ['1.1.1.1:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_timeout = 30
netprobe_address = '1.1.1.1:443'
block_ipv6 = false
block_unqualified = true
block_undelegated = true
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
log_file = '/var/log/dnscrypt-proxy.log'
log_files_max_size = 10
log_files_max_age = 7
log_files_max_backups = 1
[sources.public-resolvers]
urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md', 'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/public-resolvers.md']
cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''
EOF
    chmod 0644 "$TMP_DIR/dnscrypt-proxy.toml"
}

prepare_stage() {
    write_config
    if [ "$OLD_TARGET_PRESENT" -eq 1 ] && [ -d "$TARGET/init.d/sysv/custom.d" ]; then
        mkdir -p "$STAGE_DIR/init.d/sysv/custom.d"
        cp -a "$TARGET/init.d/sysv/custom.d/." "$STAGE_DIR/init.d/sysv/custom.d/"
    fi
    if [ "$OLD_TARGET_PRESENT" -eq 1 ]; then
        local list
        for list in zapret-hosts-user.txt zapret-hosts-user-exclude.txt zapret-hosts-user-ipban.txt zapret-hosts-auto.txt; do
            if [ -f "$TARGET/ipset/$list" ]; then
                cp -a "$TARGET/ipset/$list" "$STAGE_DIR/ipset/$list"
            fi
        done
    fi
    chown -R root:root "$STAGE_DIR"
    chmod 0755 "$STAGE_DIR" "$STAGE_DIR/lua"
    chmod 0644 "$STAGE_DIR/lua"/*.lua
    chmod 0755 "$STAGE_DIR/install_bin.sh" "$STAGE_DIR/install_prereq.sh" "$STAGE_DIR/uninstall_easy.sh"
    chmod 0755 "$STAGE_DIR/init.d/runit/zapret2/run" "$STAGE_DIR/init.d/runit/zapret2/finish" "$STAGE_DIR/init.d/sysv/zapret2"
    chmod 0755 "$STAGE_DIR/binaries/linux-x86_64/ip2net" "$STAGE_DIR/binaries/linux-x86_64/mdig" "$STAGE_DIR/binaries/linux-x86_64/nfqws2"
    "$STAGE_DIR/install_bin.sh" >/dev/null
    sh -n "$STAGE_DIR/config"
    "$STAGE_DIR/nfq2/nfqws2" --version >/dev/null
    bash -c '. "$1"; opts=${NFQWS2_OPT//\/opt\/zapret2/$2}; "$3" --dry-run --qnum="$QNUM" --user=root --fwmark="$DESYNC_MARK" $opts' _ "$STAGE_DIR/config" "$STAGE_DIR" "$STAGE_DIR/nfq2/nfqws2" >/dev/null
}

create_backup() {
    install -d -m 0700 "$BACKUP_ROOT"
    BACKUP_DIR="$BACKUP_ROOT/zapret2-void-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 0700 "$BACKUP_DIR"
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        [ -d "$TARGET" ] && [ ! -L "$TARGET" ] || die "$TARGET không phải thư mục bình thường"
        OLD_TARGET_PRESENT=1
        log 'trạng thái trước cài: zapret2 target đã tồn tại'
    else
        log 'trạng thái trước cài: zapret2 target chưa tồn tại'
    fi
    if [ -e "$SERVICE_DIR" ] || [ -L "$SERVICE_DIR" ]; then
        OLD_SERVICE_DIR_PRESENT=1
    fi
    if [ -e "$SERVICE_LINK" ] || [ -L "$SERVICE_LINK" ]; then
        [ -L "$SERVICE_LINK" ] || die "$SERVICE_LINK không phải symlink"
        OLD_SERVICE_LINK_PRESENT=1
        OLD_SERVICE_LINK_TARGET=$(readlink "$SERVICE_LINK")
        service_is_up zapret2 && ZAPRET_WAS_UP=1
    fi
    if [ -e "$MODULES_CONF" ]; then
        OLD_MODULES_PRESENT=1
        cp -a "$MODULES_CONF" "$BACKUP_DIR/modules.conf.before"
    fi
    if [ -e "$DNS_PROXY_SERVICE_DIR" ] || [ -L "$DNS_PROXY_SERVICE_DIR" ]; then
        OLD_DNS_SERVICE_DIR_PRESENT=1
    fi
    if [ -e "$DNS_PROXY_SERVICE_LINK" ] || [ -L "$DNS_PROXY_SERVICE_LINK" ]; then
        [ -L "$DNS_PROXY_SERVICE_LINK" ] || die "$DNS_PROXY_SERVICE_LINK không phải symlink"
        OLD_DNS_SERVICE_LINK_PRESENT=1
        OLD_DNS_SERVICE_LINK_TARGET=$(readlink "$DNS_PROXY_SERVICE_LINK")
        service_is_up dnscrypt-proxy && DNS_SERVICE_WAS_UP=1
    fi
    if [ -e "$DNS_PROXY_CONFIG" ]; then
        OLD_DNS_CONFIG_PRESENT=1
        cp -a "$DNS_PROXY_CONFIG" "$BACKUP_DIR/dnscrypt-proxy.toml.before"
    fi
    if [ -e "$DNS_PROXY_BIN" ]; then
        OLD_DNS_BIN_PRESENT=1
        cp -a "$DNS_PROXY_BIN" "$BACKUP_DIR/dnscrypt-proxy.before"
    fi
    printf 'uuid=%s\ndns=%s\nignore_auto_dns=%s\n' "$NM_CONNECTION_UUID" "$OLD_NM_DNS" "$OLD_NM_IGNORE" > "$BACKUP_DIR/networkmanager-dns.before"
    cp -a "$NFT_SERVICE_DIR/run" "$BACKUP_DIR/nftables-run.before"
    cp -a "$NFT_SERVICE_DIR/finish" "$BACKUP_DIR/nftables-finish.before"
    nft list ruleset > "$BACKUP_DIR/nft-ruleset.before"
    ip -brief addr > "$BACKUP_DIR/ip-address.before"
    ip route > "$BACKUP_DIR/ip-route.before"
    log "backup: $BACKUP_DIR"
}

service_is_up() {
    local name=$1
    local status
    status=$(sv status "$name" 2>/dev/null || true)
    case "$status" in
        run:*)
            return 0
            ;;
    esac
    return 1
}

stop_zapret() {
    if [ -e "$SERVICE_LINK" ] || [ -L "$SERVICE_LINK" ]; then
        sv down zapret2 >/dev/null 2>&1 || true
        local _
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            service_is_up zapret2 || return 0
            sleep 1
        done
        warn 'zapret2 chưa dừng sau 10 giây'
    fi
}

restore_file() {
    local path=$1
    local backup=$2
    rm -f "$path"
    if [ -f "$backup" ]; then
        cp -a "$backup" "$path"
    fi
}

stop_dns_proxy() {
    if [ -e "$DNS_PROXY_SERVICE_LINK" ] || [ -L "$DNS_PROXY_SERVICE_LINK" ]; then
        sv down dnscrypt-proxy >/dev/null 2>&1 || true
        local _
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            service_is_up dnscrypt-proxy || return 0
            sleep 1
        done
        warn 'dnscrypt-proxy chưa dừng sau 10 giây'
    fi
}

dns_service_ready() {
    service_is_up dnscrypt-proxy || return 1
    local sockets
    sockets=$(ss -lunt 2>/dev/null || true)
    case "$sockets" in
        *127.0.0.1:53*) return 0 ;;
    esac
    return 1
}

start_dns_proxy() {
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if sv up dnscrypt-proxy >/dev/null 2>&1 && dns_service_ready; then
            return 0
        fi
        sleep 1
    done
    return 1
}

install_dns_files() {
    CHANGED=1
    stop_dns_proxy
    if [ "$OLD_DNS_SERVICE_DIR_PRESENT" -eq 1 ]; then
        mv "$DNS_PROXY_SERVICE_DIR" "$BACKUP_DIR/dnscrypt-proxy.service.before"
        OLD_DNS_SERVICE_DIR_MOVED=1
    elif [ -e "$DNS_PROXY_SERVICE_DIR" ] || [ -L "$DNS_PROXY_SERVICE_DIR" ]; then
        die "$DNS_PROXY_SERVICE_DIR xuất hiện sau backup; không thể thay thế an toàn"
    fi
    DNS_SERVICE_DIR_REPLACED=1
    install -d -m 0755 "$DNS_PROXY_SERVICE_DIR"
    install -o root -g root -m 0755 "$EXPECTED_DNS_RUN" "$DNS_PROXY_SERVICE_DIR/run"
    rm -f "$DNS_PROXY_SERVICE_LINK"
    ln -s "$DNS_PROXY_SERVICE_DIR" "$DNS_PROXY_SERVICE_LINK"
    install -d -o "$DNS_PROXY_USER" -g "$DNS_PROXY_USER" -m 0750 "$DNS_PROXY_CACHE_DIR"
    touch "$DNS_PROXY_LOG"
    chown "$DNS_PROXY_USER:$DNS_PROXY_USER" "$DNS_PROXY_LOG"
    chmod 0640 "$DNS_PROXY_LOG"
    DNS_BIN_REPLACED=1
    install -o root -g root -m 0755 "$DNS_BIN_STAGE" "$DNS_PROXY_BIN"
    DNS_CONFIG_REPLACED=1
    install -o root -g root -m 0644 "$TMP_DIR/dnscrypt-proxy.toml" "$DNS_PROXY_CONFIG"
    "$DNS_PROXY_BIN" -check -config "$DNS_PROXY_CONFIG" >/dev/null
    start_dns_proxy || die 'dnscrypt-proxy không sẵn sàng'
    nmcli connection modify uuid "$NM_CONNECTION_UUID" ipv4.dns '127.0.0.1' ipv4.ignore-auto-dns yes
    nmcli connection up uuid "$NM_CONNECTION_UUID" >/dev/null
    sleep 3
    local address
    address=$(getent ahostsv4 example.com 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *STREAM*) printf '%s' "$line"; break ;;
        esac
    done)
    case "$address" in
        127.0.0.1*|'') die 'DNS qua dnscrypt-proxy chưa trả về địa chỉ hợp lệ' ;;
    esac
}

rollback() {
    [ "$ROLLBACK_DONE" -eq 0 ] || return 0
    ROLLBACK_DONE=1
    set +e
    trap - ERR
    log 'bắt đầu rollback'
    if [ -e "$SERVICE_LINK" ] || [ -L "$SERVICE_LINK" ]; then
        sv down zapret2 >/dev/null 2>&1 || true
    fi
    stop_dns_proxy
    if [ -n "$NM_CONNECTION_UUID" ]; then
        if [ -n "$OLD_NM_DNS" ]; then
            nmcli connection modify uuid "$NM_CONNECTION_UUID" ipv4.dns "$OLD_NM_DNS" ipv4.ignore-auto-dns "$OLD_NM_IGNORE" >/dev/null 2>&1 || true
        else
            nmcli connection modify uuid "$NM_CONNECTION_UUID" ipv4.dns '' ipv4.ignore-auto-dns no >/dev/null 2>&1 || true
        fi
        nmcli connection up uuid "$NM_CONNECTION_UUID" >/dev/null 2>&1 || true
    fi
    if [ "$NEW_TARGET_INSTALLED" -eq 1 ] && [ -d "$TARGET" ]; then
        rm -rf "$TARGET"
    fi
    if [ "$OLD_TARGET_MOVED" -eq 1 ] && [ -d "$BACKUP_DIR/zapret2.previous" ]; then
        mv "$BACKUP_DIR/zapret2.previous" "$TARGET"
    fi
    if [ "$SERVICE_DIR_REPLACED" -eq 1 ] && { [ -e "$SERVICE_DIR" ] || [ -L "$SERVICE_DIR" ]; }; then
        rm -rf "$SERVICE_DIR"
    fi
    if [ "$OLD_SERVICE_DIR_MOVED" -eq 1 ] && [ -e "$BACKUP_DIR/zapret2.service.before" ]; then
        mv "$BACKUP_DIR/zapret2.service.before" "$SERVICE_DIR"
    fi
    if [ -e "$SERVICE_LINK" ] || [ -L "$SERVICE_LINK" ]; then
        rm -f "$SERVICE_LINK"
    fi
    if [ "$OLD_SERVICE_LINK_PRESENT" -eq 1 ]; then
        ln -s "$OLD_SERVICE_LINK_TARGET" "$SERVICE_LINK"
    fi
    if [ "$DNS_SERVICE_DIR_REPLACED" -eq 1 ] && { [ -e "$DNS_PROXY_SERVICE_DIR" ] || [ -L "$DNS_PROXY_SERVICE_DIR" ]; }; then
        rm -rf "$DNS_PROXY_SERVICE_DIR"
    fi
    if [ "$OLD_DNS_SERVICE_DIR_MOVED" -eq 1 ] && [ -e "$BACKUP_DIR/dnscrypt-proxy.service.before" ]; then
        mv "$BACKUP_DIR/dnscrypt-proxy.service.before" "$DNS_PROXY_SERVICE_DIR"
    fi
    if [ -e "$DNS_PROXY_SERVICE_LINK" ] || [ -L "$DNS_PROXY_SERVICE_LINK" ]; then
        rm -f "$DNS_PROXY_SERVICE_LINK"
    fi
    if [ "$OLD_DNS_SERVICE_LINK_PRESENT" -eq 1 ]; then
        ln -s "$OLD_DNS_SERVICE_LINK_TARGET" "$DNS_PROXY_SERVICE_LINK"
    fi
    if [ "$DNS_CONFIG_REPLACED" -eq 1 ]; then
        rm -f "$DNS_PROXY_CONFIG"
        [ "$OLD_DNS_CONFIG_PRESENT" -eq 1 ] && cp -a "$BACKUP_DIR/dnscrypt-proxy.toml.before" "$DNS_PROXY_CONFIG"
    fi
    if [ "$DNS_BIN_REPLACED" -eq 1 ]; then
        rm -f "$DNS_PROXY_BIN"
        [ "$OLD_DNS_BIN_PRESENT" -eq 1 ] && cp -a "$BACKUP_DIR/dnscrypt-proxy.before" "$DNS_PROXY_BIN"
    fi
    if [ "$USER_CREATED" -eq 1 ]; then
        userdel "$WS_USER" >/dev/null 2>&1 || true
    fi
    if [ "$DNS_USER_CREATED" -eq 1 ]; then
        userdel "$DNS_PROXY_USER" >/dev/null 2>&1 || true
    fi
    restore_file "$NFT_SERVICE_DIR/run" "$BACKUP_DIR/nftables-run.before"
    restore_file "$NFT_SERVICE_DIR/finish" "$BACKUP_DIR/nftables-finish.before"
    if [ "$OLD_MODULES_PRESENT" -eq 1 ]; then
        restore_file "$MODULES_CONF" "$BACKUP_DIR/modules.conf.before"
    else
        rm -f "$MODULES_CONF"
    fi
    if [ "$NFTABLES_WAS_UP" -eq 1 ]; then
        sv restart nftables >/dev/null 2>&1 || true
    fi
    if [ "$DNS_SERVICE_WAS_UP" -eq 1 ] && [ -e "$DNS_PROXY_SERVICE_LINK" ]; then
        start_dns_proxy || warn 'không khởi động lại được dnscrypt-proxy sau rollback'
    fi
    if [ "$ZAPRET_WAS_UP" -eq 1 ] && [ -e "$SERVICE_LINK" ]; then
        sv -w 30 up zapret2 >/dev/null 2>&1 || warn 'không khởi động lại được zapret2 sau rollback'
    fi
    log 'rollback đã hoàn tất'
    set -e
}

install_files() {
    CHANGED=1
    stop_zapret
    if [ "$OLD_TARGET_PRESENT" -eq 1 ]; then
        mv "$TARGET" "$BACKUP_DIR/zapret2.previous"
        OLD_TARGET_MOVED=1
    elif [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        die "$TARGET xuất hiện sau backup; không thể thay thế an toàn"
    fi
    NEW_TARGET_INSTALLED=1
    mv "$STAGE_DIR" "$TARGET"
    STAGE_DIR=
    if [ "$OLD_SERVICE_DIR_PRESENT" -eq 1 ]; then
        mv "$SERVICE_DIR" "$BACKUP_DIR/zapret2.service.before"
        OLD_SERVICE_DIR_MOVED=1
    elif [ -e "$SERVICE_DIR" ] || [ -L "$SERVICE_DIR" ]; then
        die "$SERVICE_DIR xuất hiện sau backup; không thể thay thế an toàn"
    fi
    SERVICE_DIR_REPLACED=1
    install -d -m 0755 "$SERVICE_DIR"
    install -o root -g root -m 0755 "$EXPECTED_ZAPRET_RUN" "$SERVICE_DIR/run"
    install -o root -g root -m 0755 "$EXPECTED_ZAPRET_FINISH" "$SERVICE_DIR/finish"
    rm -f "$SERVICE_LINK"
    ln -s /etc/sv/zapret2 "$SERVICE_LINK"
    install -o root -g root -m 0755 "$EXPECTED_RUN" "$NFT_SERVICE_DIR/run"
    install -o root -g root -m 0755 "$EXPECTED_FINISH" "$NFT_SERVICE_DIR/finish"
    printf 'nft_queue\nnfnetlink_queue\n' > "$MODULES_CONF"
    chmod 0644 "$MODULES_CONF"
    chown -R root:root "$TARGET" "$SERVICE_DIR"
    modprobe nft_queue
    modprobe nfnetlink_queue
}

wait_for_zapret() {
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if service_is_up zapret2 && nft list table inet zapret2 >/dev/null 2>&1 && pgrep -xo nfqws2 >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_services() {
    if service_is_up nftables; then
        NFTABLES_WAS_UP=1
        sv restart nftables
    else
        sv up nftables
    fi
    sv -w 30 restart zapret2 >/dev/null 2>&1 || true
    if ! wait_for_zapret; then
        log "trạng thái zapret2: $(sv status zapret2 2>&1 || true)"
        log 'thử khởi động trực tiếp một lần'
        /opt/zapret2/init.d/sysv/zapret2 start || true
        wait_for_zapret || die 'zapret2 không tạo được bảng nft sau khi khởi động'
    fi
}

validate_live() {
    nft list table inet void_filter >/dev/null
    local table
    table=$(nft -a list table inet zapret2)
    case "$table" in
        *'queue flags bypass to 200'*) ;;
        *) die 'bảng zapret2 không có queue 200' ;;
    esac
    case "$table" in
        *'elements = { "eno1" }'*) ;;
        *) die 'bảng zapret2 không gắn interface eno1' ;;
    esac
    pgrep -xo nfqws2 >/dev/null || die 'nfqws2 chưa chạy'
    service_is_up zapret2 || die 'runit zapret2 chưa ở trạng thái run'
    service_is_up dnscrypt-proxy || die 'runit dnscrypt-proxy chưa ở trạng thái run'
    dns_service_ready || die 'dnscrypt-proxy chưa lắng nghe DNS nội bộ'
    ip route get 1.1.1.1 >/dev/null
    getent hosts example.com >/dev/null || warn 'DNS chưa trả về kết quả'
    if ! curl --fail --location --max-time 15 --silent --show-error -o /dev/null https://example.com; then
        warn 'HTTPS kiểm tra thất bại; cần kiểm tra chiến lược DPI'
    fi
    sh -n "$TARGET/config"
}

check_current() {
    log 'kiểm tra cài đặt hiện tại'
    if [ ! -d "$TARGET" ]; then
        warn "$TARGET chưa tồn tại"
        return 0
    fi
    [ -x "$TARGET/nfq2/nfqws2" ] || die 'binary nfqws2 không tồn tại'
    "$TARGET/nfq2/nfqws2" --version
    sh -n "$TARGET/config"
    (
        . "$TARGET/config"
        [ "$FWTYPE" = nftables ]
        [ "$NFQWS2_ENABLE" = 1 ]
        [ "$IFACE_WAN" = eno1 ]
        [ "$QNUM" = 200 ]
        [ "$NFQWS2_TCP_PKT_OUT" = 20 ]
        [ "$NFQWS2_TCP_PKT_IN" = 1 ]
        [ "$NFQWS2_UDP_PKT_OUT" = 5 ]
        [ "$NFQWS2_UDP_PKT_IN" = 1 ]
        case "$NFQWS2_OPT" in
            *--lua-init=*) false ;;
        esac
        case "$NFQWS2_OPT" in
            *--lua-desync=http_hostcase:spell=hoSt*) ;;
            *) false ;;
        esac
        case "$NFQWS2_OPT" in
            *--lua-desync=multidisorder:pos=1,midsld*) ;;
            *) false ;;
        esac
        case "$NFQWS2_OPT" in
            *--lua-desync=fake:blob=fake_default_quic:repeats=1:ip_ttl=2*) ;;
            *) false ;;
        esac
    ) || die 'cấu hình zapret2 không khớp profile đã cài'
    if [ -L "$SERVICE_LINK" ]; then
        log "service: $SERVICE_LINK -> $(readlink "$SERVICE_LINK")"
    else
        warn 'service zapret2 chưa được bật'
    fi
    if nft list table inet zapret2 >/dev/null 2>&1; then
        log 'bảng nft inet zapret2: có'
    else
        warn 'bảng nft inet zapret2: chưa có'
    fi
    if pgrep -xo nfqws2 >/dev/null; then
        log "nfqws2 pid: $(pgrep -xo nfqws2)"
    else
        warn 'nfqws2 chưa chạy'
    fi
    if service_is_up zapret2; then
        log 'runit zapret2: đang chạy'
    else
        warn 'runit zapret2 không chạy'
    fi
    if service_is_up dnscrypt-proxy && dns_service_ready; then
        log 'dnscrypt-proxy: đang chạy trên 127.0.0.1:53'
    else
        warn 'dnscrypt-proxy chưa sẵn sàng'
    fi
    log "NetworkManager DNS: $(nmcli -g ipv4.dns connection show uuid "$NM_CONNECTION_UUID" 2>/dev/null || true)"
    ip route get 1.1.1.1
}

install_release() {
    check_system
    TMP_DIR=$(mktemp -d /tmp/zapret2-void.XXXXXX)
    create_templates
    check_existing_files
    download_release
    download_dns_proxy
    write_dns_config
    create_backup
    create_user
    prepare_stage
    install_dns_files
    install_files
    start_services
    validate_live
    log "cài đặt hoàn tất; backup: $BACKUP_DIR"
}

main() {
    parse_args "$@"
    check_root
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die 'một tiến trình cài zapret2 khác đang chạy'
    check_system
    if [ "$CHECK_ONLY" -eq 1 ]; then
        check_current
        exit 0
    fi
    install_release
}

main "$@"
