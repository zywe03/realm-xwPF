#!/bin/bash

SCRIPT_VERSION="v2.3.4"
REALM_VERSION="v2.9.6"

NAT_LISTEN_PORT=""
NAT_LISTEN_IP=""
NAT_THROUGH_IP="::"
REMOTE_IP=""
REMOTE_PORT=""
EXIT_LISTEN_PORT=""
FORWARD_TARGET=""

SECURITY_LEVEL=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
TLS_SERVER_NAME=""
WS_PATH=""
WS_HOST=""

RULE_ID=""
RULE_NAME=""

REQUIRED_TOOLS=("curl" "wget" "tar" "grep" "cut" "bc" "jq")

# 系统标识（由 detect_system 设置）
DISTRO=""        # debian | alpine | centos
PKG_MGR=""       # apt-get | apk | yum/dnf
INIT_SYSTEM=""   # systemd | openrc

# 编码成规则文件里可安全 source 的单行赋值右值。不用 %q：非 UTF-8 locale 下它会把中文写成 $'\xxx' 字节转义
rule_quote() {
    local s="$1"
    s=${s//\'/\'\\\'\'}
    s=${s//$'\n'/\'\$\'\\n\'\'}
    printf "'%s'" "$s"
}

init_rule_field() {
    local field_name="$1"
    local default_value="$2"

    if [ ! -d "$RULES_DIR" ]; then
        return 0
    fi

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if ! grep -q "^${field_name}=" "$rule_file"; then
                echo "${field_name}=\"${default_value}\"" >> "$rule_file"
            fi
        fi
    done
}

restart_and_confirm() {
    local operation_name="$1"
    local batch_mode="$2"

    if [ "$batch_mode" != "batch" ]; then
        echo -e "${YELLOW}正在重启服务以应用${operation_name}...${NC}"
        if service_restart; then
            echo -e "${GREEN}✓ 服务重启成功，${operation_name}已生效${NC}"
            return 0
        else
            echo -e "${RED}✗ 服务重启失败，请检查配置${NC}"
            return 1
        fi
    fi
    return 0
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
NC='\033[0m'

REALM_PATH="/usr/local/bin/realm"
CONFIG_DIR="/etc/realm"
MANAGER_CONF="${CONFIG_DIR}/manager.conf"
CONFIG_PATH="${CONFIG_DIR}/config.json"
SYSTEMD_PATH="/etc/systemd/system/realm.service"
RULES_DIR="${CONFIG_DIR}/rules"

HEALTH_DIR="${CONFIG_DIR}/health"
HEALTH_STATUS_FILE="${HEALTH_DIR}/health_status.conf"

# 客户端与服务端必须使用同一 SNI
DEFAULT_SNI_DOMAIN="www.tesla.com"

SHORT_CONNECT_TIMEOUT=5
SHORT_MAX_TIMEOUT=7

# 保留 config.json 中已有的 proxy 字段，规则未覆盖时继续沿用
generate_network_config() {
    local config_file="/etc/realm/config.json"
    local base_network='{
        "no_tcp": false,
        "use_udp": true
    }'

    if [ -f "$config_file" ]; then
        local existing_proxy=$(jq -r '.network | {send_proxy, send_proxy_version, accept_proxy, accept_proxy_timeout} | to_entries | map(select(.value != null)) | from_entries' "$config_file" 2>/dev/null || echo "{}")
        if [ -n "$existing_proxy" ] && [ "$existing_proxy" != "{}" ] && [ "$existing_proxy" != "null" ]; then
            echo "$base_network" | jq ". + $existing_proxy" 2>/dev/null || echo "$base_network"
            return
        fi
    fi

    echo "$base_network"
}

generate_complete_config() {
    local endpoints="$1"
    local config_path="${2:-$CONFIG_PATH}"

    local network_config=$(generate_network_config)
    if [ -z "$network_config" ]; then
        network_config='{"no_tcp": false, "use_udp": true}'
    fi

    cat > "$config_path" <<EOF
{
    "network": $network_config,
    "endpoints": [$endpoints
    ]
}
EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行。${NC}"
        exit 1
    fi
}

detect_system() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}错误: 无法识别系统（缺少 /etc/os-release）${NC}"
        exit 1
    fi
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID

    case "$ID" in
        debian|ubuntu)
            DISTRO="debian" ;;
        alpine)
            DISTRO="alpine" ;;
        centos|rhel|rocky|almalinux|fedora)
            DISTRO="centos" ;;
        *)
            echo -e "${RED}错误: 不支持的系统: $ID${NC}"
            echo -e "${YELLOW}当前支持: Debian/Ubuntu, Alpine, CentOS/RHEL${NC}"
            exit 1 ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
    elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    else
        echo -e "${RED}错误: 未找到支持的包管理器${NC}"
        exit 1
    fi

    if command -v systemctl >/dev/null 2>&1; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else
        echo -e "${RED}错误: 未找到支持的 init 系统${NC}"
        exit 1
    fi
}

_pkg_install() {
    case "$PKG_MGR" in
        apt-get)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y "$@" >/dev/null 2>&1 ;;
        apk)
            apk add --no-cache "$@" >/dev/null 2>&1 ;;
        yum|dnf)
            $PKG_MGR install -y "$@" >/dev/null 2>&1 ;;
    esac
    for tool in "$@"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} $tool 安装成功"
        else
            echo -e "${RED}✗${NC} $tool 安装失败"
        fi
    done
}

manage_dependencies() {
    local mode="$1"
    local missing_tools=()

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        elif [ "$mode" = "install" ]; then
            echo -e "${GREEN}✓${NC} $tool 已安装"
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        if [ "$mode" = "check" ]; then
            echo -e "${RED}错误: 缺少必备工具: ${missing_tools[*]}${NC}"
            echo -e "${YELLOW}请先选择菜单选项1进行安装，或手动运行安装命令:${NC}"
            echo -e "${BLUE}curl -fsSL https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install${NC}"
            exit 1
        elif [ "$mode" = "install" ]; then
            echo -e "${YELLOW}需要安装以下工具: ${missing_tools[*]}${NC}"
            echo -e "${BLUE}使用 $PKG_MGR 安装依赖,下载中...${NC}"
            _pkg_install "${missing_tools[@]}"
        fi
    elif [ "$mode" = "install" ]; then
        echo -e "${GREEN}所有必备工具已安装完成${NC}"
    fi

    [ "$mode" = "install" ] && echo ""
}

check_dependencies() {
    manage_dependencies "check"
}

get_public_ip() {
    local ip_type="$1"
    local ip=""
    local curl_opts=""

    [ "$ip_type" = "ipv6" ] && curl_opts="-6"

    ip=$(curl -s --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT $curl_opts https://ipinfo.io/ip 2>/dev/null | tr -d '\n\r ')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
        echo "$ip"
        return 0
    fi

    ip=$(curl -s --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT $curl_opts https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "ip=" | cut -d'=' -f2 | tr -d '\n\r ')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
        echo "$ip"
        return 0
    fi

    echo ""
}

# 支持realm单端口多规则复用，避免误报端口冲突
check_port_usage() {
    local port="$1"
    [ -z "$port" ] && return 0

    local output=$(ss -tulnp 2>/dev/null | grep ":${port} ")
    [ -z "$output" ] && return 0

    if echo "$output" | grep -q "realm"; then
        echo -e "${GREEN}✓ 端口 $port 已被realm服务占用，支持单端口中转多服务端配置${NC}"
        return 1
    fi

    echo -e "${YELLOW}警告: 端口 $port 已被其他服务占用${NC}"
    echo -e "${BLUE}占用进程信息:${NC}"
    echo "$output" | sed 's/^/  /'

    read -p "是否继续配置？(y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "配置已取消"; exit 1; }
    return 0
}

check_connectivity() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"

    [ -z "$target" ] || [ -z "$port" ] && return 1

    # bash /dev/tcp（全平台通用）
    timeout "$timeout" bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_ports() {
    local input="${1// /}"
    [ -z "$input" ] && return 1

    IFS=',' read -ra ports <<< "$input"
    for p in "${ports[@]}"; do
        validate_port "$p" || return 1
    done
}

validate_ip() {
    local ip="$1"

    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [ "$i" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi

    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *":"* ]]; then
        return 0
    fi
    return 1
}

validate_target_address() {
    local target="$1"

    if [ -z "$target" ]; then
        return 1
    fi

    if [[ "$target" == *","* ]]; then
        IFS=',' read -ra ADDRESSES <<< "$target"
        for addr in "${ADDRESSES[@]}"; do
            addr=$(echo "$addr" | xargs)
            if ! validate_single_address "$addr"; then
                return 1
            fi
        done
        return 0
    else
        validate_single_address "$target"
    fi
}

validate_single_address() {
    local addr="$1"

    if validate_ip "$addr"; then
        return 0
    fi

    if [[ "$addr" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || [[ "$addr" == "localhost" ]]; then
        return 0
    fi

    return 1
}

# 根据角色和安全级别生成对应的传输配置，确保客户端和服务端配置匹配 1=中转服务器(客户端), 2=出口服务器(服务端)
get_transport_config() {
    local security_level="$1"
    local tls_server_name="$2"
    local cert_path="$3"
    local key_path="$4"
    local role="$5"
    local ws_path="$6"
    local ws_host="$7"

    case "$security_level" in
        "standard")
            echo ""
            ;;
        "ws")
            local ws_path_param="${ws_path:-/ws}"
            local ws_host_param="${ws_host:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "ws;host='$ws_host_param';path='$ws_path_param'"'
            elif [ "$role" = "2" ]; then
                echo '"listen_transport": "ws;host='$ws_host_param';path='$ws_path_param'"'
            fi
            ;;
        "tls_self")
            local sni_name="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "tls;sni='$sni_name';insecure"'
            elif [ "$role" = "2" ]; then
                echo '"listen_transport": "tls;servername='$sni_name'"'
            fi
            ;;
        "tls_ca")
            if [ "$role" = "1" ]; then
                local sni_name="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
                echo '"remote_transport": "tls;sni='$sni_name'"'
            elif [ "$role" = "2" ]; then
                if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
                    echo '"listen_transport": "tls;cert='$cert_path';key='$key_path'"'
                else
                    echo ""
                fi
            fi
            ;;
        "ws_tls_self")
            local ws_host_param="${ws_host:-$DEFAULT_SNI_DOMAIN}"
            local ws_path_param="${ws_path:-/ws}"
            local sni_name="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
            if [ "$role" = "1" ]; then
                echo '"remote_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;sni='$sni_name';insecure"'
            elif [ "$role" = "2" ]; then
                echo '"listen_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;servername='$sni_name'"'
            fi
            ;;
        "ws_tls_ca")
            local ws_host_param="${ws_host:-$DEFAULT_SNI_DOMAIN}"
            local ws_path_param="${ws_path:-/ws}"
            if [ "$role" = "1" ]; then
                local sni_name="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
                echo '"remote_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;sni='$sni_name'"'
            elif [ "$role" = "2" ]; then
                if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
                    echo '"listen_transport": "ws;host='$ws_host_param';path='$ws_path_param';tls;cert='$cert_path';key='$key_path'"'
                else
                    echo ""
                fi
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}
