#!/bin/bash

# xw_realm_OCR.sh - Realm配置文件识别脚本
# 识别用户的realm配置文件，识别endpoints字段，导入脚本管理

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'
SCRIPT_VERSION="1.1.1"

get_gmt8_time() {
    TZ='GMT-8' date "$@"
}

# 规则ID生成器（临时使用，最终由主脚本重排序）
generate_rule_id() {
    local existing_count=$(ls -1 "$OUTPUT_DIR"/rule-*.conf 2>/dev/null | wc -l)
    echo $((existing_count + 1))
}

# 编码成规则文件里可安全 source 的单行赋值右值。本脚本独立运行不加载 lib/core.sh，副本需与其 rule_quote 保持一致
rule_quote() {
    local s="$1"
    s=${s//\'/\'\\\'\'}
    s=${s//$'\n'/\'\$\'\\n\'\'}
    printf "'%s'" "$s"
}

CONFIG_DIR="/etc/realm"
RULES_DIR="${CONFIG_DIR}/rules"

DEFAULT_SNI_DOMAIN="www.tesla.com"

if [ -n "$1" ]; then
    RULES_DIR="$1"
fi

echo -e "${YELLOW}=== 识别realm配置文件并导入 ===${NC}"
echo ""

if ! pwd >/dev/null 2>&1; then
    cd /tmp
fi

read -p "请输入配置文件的完整路径：" CONFIG_FILE
echo ""

if [ -z "$CONFIG_FILE" ]; then
    echo -e "${BLUE}已取消操作${NC}"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误: 文件不存在${NC}"
    exit 1
fi

file_ext=$(echo "$CONFIG_FILE" | awk -F. '{print tolower($NF)}')
if [ "$file_ext" != "json" ] && [ "$file_ext" != "toml" ]; then
    echo -e "${RED}错误: 仅支持 .json 和 .toml 格式的配置文件${NC}"
    exit 1
fi

OUTPUT_DIR="/tmp/realm_import_$$"
mkdir -p "$OUTPUT_DIR"

echo -e "${YELLOW}正在识别配置文件...${NC}"

file_ext=$(echo "$CONFIG_FILE" | awk -F. '{print tolower($NF)}')

# 获取安全级别显示文本（与主脚本完全一致）
get_security_display() {
    local security_level="$1"
    local ws_path="$2"
    local tls_server_name="$3"  # 在ws模式下作为host，在tls模式下作为SNI

    case "$security_level" in
        "standard")
            echo "默认传输"
            ;;
        "ws")
            echo "ws (host: $tls_server_name) (路径: $ws_path)"
            ;;
        "tls_self")
            local display_sni="${tls_server_name:-$DEFAULT_SNI_DOMAIN}"
            echo "TLS自签证书 (SNI: $display_sni)"
            ;;
        "tls_ca")
            echo "TLS CA证书 (域名: $tls_server_name)"
            ;;
        "ws_tls_self")
            local display_sni="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            echo "wss 自签证书 (host: $tls_server_name) (路径: $ws_path) (SNI: $display_sni)"
            ;;
        "ws_tls_ca")
            local display_sni="${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            echo "wss CA证书 (host: $tls_server_name) (路径: $ws_path) (SNI: $display_sni)"
            ;;
        "ws_"*)
            echo "$security_level (路径: $ws_path)"
            ;;
        *)
            echo "$security_level"
            ;;
    esac
}

parse_transport_config() {
    local transport="$1"
    local role="$2"  # 1=中转服务器, 2=服务端服务器

    local security_level="standard"
    local tls_server_name=""
    local ws_path=""
    local ws_host=""

    if [ -n "$transport" ]; then
        local has_ws=false
        if echo "$transport" | grep -q "ws;"; then
            has_ws=true

            ws_host=$(echo "$transport" | grep -oP 'host=\K[^;]+' || echo "")
            ws_path=$(echo "$transport" | grep -oP 'path=\K[^;]+' || echo "")
        fi

        local has_tls=false
        if echo "$transport" | grep -q "tls"; then
            has_tls=true

            if [ "$role" = "1" ]; then
                tls_server_name=$(echo "$transport" | grep -oP 'sni=\K[^;]+' || echo "")
            else
                tls_server_name=$(echo "$transport" | grep -oP 'servername=\K[^;]+' || echo "")
            fi
        fi

        if [ "$has_ws" = true ] && [ "$has_tls" = true ]; then
            if echo "$transport" | grep -q "insecure"; then
                security_level="ws_tls_self"
            elif echo "$transport" | grep -q "servername="; then
                security_level="ws_tls_self"
            elif echo "$transport" | grep -q "cert=.*key="; then
                security_level="ws_tls_ca"
            elif [ "$role" = "1" ]; then
                security_level="ws_tls_ca"
            else
                security_level="ws_tls_self"
            fi
        elif [ "$has_ws" = true ]; then
            security_level="ws"
        elif [ "$has_tls" = true ]; then
            if echo "$transport" | grep -q "insecure"; then
                security_level="tls_self"
            elif echo "$transport" | grep -q "servername="; then
                security_level="tls_self"
            elif echo "$transport" | grep -q "cert=.*key="; then
                security_level="tls_ca"
            elif [ "$role" = "1" ]; then
                security_level="tls_ca"
            else
                security_level="tls_self"
            fi
        fi
    fi

    echo "$security_level|$tls_server_name|$ws_path|$ws_host"
}

valid_endpoint_address() {
    local address="$1" port="${1##*:}"
    [[ "$address" == ?*:* && "$port" =~ ^[0-9]{1,5}$ ]] &&
        (( 10#$port >= 1 && 10#$port <= 65535 ))
}

process_json() {
    local json_file="$1"

    if ! jq -e '.endpoints | type == "array"' "$json_file" >/dev/null 2>&1; then
        echo "错误: 配置文件中未找到endpoints字段"
        return 1
    fi

    local endpoint_count=$(jq '.endpoints | length' "$json_file")
    local generated_count=0
    if [ "$endpoint_count" -eq 0 ]; then
        echo "错误: endpoints数组为空"
        return 1
    fi

    echo "发现 $endpoint_count 个endpoint配置"

    for i in $(seq 0 $((endpoint_count - 1))); do
        local endpoint=$(jq ".endpoints[$i]" "$json_file")

        local listen="" remote="" extra_remotes="" balance="" listen_transport="" remote_transport=""
        local rule_role="" rule_name="" listen_ip="" listen_port="" remote_host="" remote_port=""
        local transport_to_parse="" security_level="" tls_server_name="" ws_path="" ws_host=""
        local protocol=""

        listen=$(echo "$endpoint" | jq -r '.listen // empty')
        remote=$(echo "$endpoint" | jq -r '.remote // empty')
        extra_remotes=$(echo "$endpoint" | jq -r '.extra_remotes[]? // empty' | tr '\n' ',' | sed 's/,$//')
        balance=$(echo "$endpoint" | jq -r '.balance // empty')
        listen_transport=$(echo "$endpoint" | jq -r '.listen_transport // empty')
        remote_transport=$(echo "$endpoint" | jq -r '.remote_transport // empty')

        # 推断转发协议：endpoint.network 字段级优先，缺省回退全局 .network，再缺省按 false
        # 陷阱：jq 的 // 会把显式 false 当空，判缺失必须用 == null
        # 全缺(network 全无)→both 用 xwPF 全局双栈顶着；no_tcp:true+use_udp:false 不转发任何流量→invalid 跳过
        protocol=$(jq -r --argjson idx "$i" '
            def eff($f):
                if .endpoints[$idx].network[$f] != null then .endpoints[$idx].network[$f]
                elif .network[$f] != null then .network[$f]
                else false end;
            if (.network.no_tcp == null and .network.use_udp == null
                and .endpoints[$idx].network.no_tcp == null
                and .endpoints[$idx].network.use_udp == null)
            then "both"
            else
            (eff("no_tcp")) as $nt | (eff("use_udp")) as $uu |
            if      $nt == false and $uu == true  then "both"
            elif    $nt == false and $uu == false then "tcp"
            elif    $nt == true  and $uu == true  then "udp"
            else "invalid" end
            end' "$json_file" 2>/dev/null)

        if [ -z "$protocol" ]; then
            echo "警告: endpoint $i 的 network 字段格式异常，按双栈(both)导入"
            protocol="both"
        elif [ "$protocol" = "invalid" ]; then
            echo "警告: endpoint $i 的 network 为 no_tcp=true/use_udp=false（不转发任何流量），跳过"
            continue
        fi

        if ! valid_endpoint_address "$listen" || ! valid_endpoint_address "$remote"; then
            echo "警告: endpoint $i 的监听或目标地址无效（格式应为 IP:端口 或 域名:端口），跳过"
            continue
        fi

        local listen_ip="${listen%:*}"
        local listen_port="${listen##*:}"

        local remote_host="${remote%:*}"
        local remote_port="${remote##*:}"

        local rule_role="1"  # 默认中转服务器
        local rule_name="中转"

        if [ -n "$listen_transport" ]; then
            rule_role="2"
            rule_name="服务端"
            # 服务端服务器监听IP强制改为::（双栈监听）
            listen_ip="::"
        fi
        local transport_to_parse=""
        if [ "$rule_role" = "1" ]; then
            transport_to_parse="$remote_transport"
        else
            transport_to_parse="$listen_transport"
        fi

        local transport_result=$(parse_transport_config "$transport_to_parse" "$rule_role")
        local security_level tls_server_name ws_path ws_host
        IFS='|' read -r security_level tls_server_name ws_path ws_host <<< "$transport_result"

        # 纯 UDP 无 TCP 连接，ws/tls 加密传输挂在 TCP 上对纯 UDP 无效，强制降级 standard
        # 与主脚本添加/编辑流程保持一致
        if [ "$protocol" = "udp" ] && [ "$security_level" != "standard" ]; then
            echo "警告: endpoint $i 为纯 UDP，ws/tls 加密传输仅对 TCP 生效，已降级为默认传输"
            security_level="standard"
            tls_server_name="" ws_path="" ws_host=""
        fi

        local all_targets=("$remote")
        if [ -n "$extra_remotes" ]; then
            IFS=',' read -ra extra_array <<< "$extra_remotes"
            for extra_addr in "${extra_array[@]}"; do
                extra_addr=$(echo "$extra_addr" | xargs)  # 去除空格
                if ! valid_endpoint_address "$extra_addr"; then
                    echo "警告: endpoint $i 的额外目标地址 $extra_addr 无效（格式应为 IP:端口 或 域名:端口），跳过该 endpoint"
                    continue 2
                fi
                all_targets+=("$extra_addr")
            done
        fi

        local balance_mode="off"
        local weights=""
        if [ -n "$balance" ]; then
            if echo "$balance" | grep -q "roundrobin"; then
                balance_mode="roundrobin"
                # 提取权重 (格式: "roundrobin: 4, 2, 1")
                weights=$(echo "$balance" | sed 's/.*roundrobin:\s*//' | tr -d ' ')
            elif echo "$balance" | grep -q "iphash"; then
                balance_mode="iphash"
                # 提取权重 (格式: "iphash: 2, 1")
                weights=$(echo "$balance" | sed 's/.*iphash:\s*//' | tr -d ' ')
            fi
        fi

        local target_index=0
        for target in "${all_targets[@]}"; do
            local rule_id=$(generate_rule_id)
            local rule_file="$OUTPUT_DIR/rule-$rule_id.conf"

            local target_host="${target%:*}"
            local target_port="${target##*:}"

            local rule_balance_mode="off"
            local rule_target_states=""
            local rule_weights=""

            if [ ${#all_targets[@]} -gt 1 ]; then
                rule_balance_mode="$balance_mode"
                rule_target_states=$(IFS=','; echo "${all_targets[*]}")
                if [ -n "$weights" ]; then
                    rule_weights="$weights"
                else
                    local default_weights=()
                    for ((j=0; j<${#all_targets[@]}; j++)); do
                        default_weights+=("1")
                    done
                    rule_weights=$(IFS=','; echo "${default_weights[*]}")
                fi
            fi

            # 字段来自外部 realm 配置且规则文件会被 source，地址/路径里的引号或 $(...) 必须转义
            cat > "$rule_file" << RULE_EOF || return 1
RULE_ID=$rule_id
RULE_NAME=$(rule_quote "$rule_name")
RULE_ROLE="$rule_role"
SECURITY_LEVEL=$(rule_quote "$security_level")
LISTEN_PORT=$listen_port
LISTEN_IP=$(rule_quote "$listen_ip")
ENABLED="true"
CREATED_TIME="$(get_gmt8_time '+%Y-%m-%d %H:%M:%S')"
RULE_NOTE=""

# 负载均衡配置
BALANCE_MODE=$(rule_quote "$rule_balance_mode")
TARGET_STATES=$(rule_quote "$rule_target_states")
WEIGHTS=$(rule_quote "$rule_weights")

# 故障转移配置
FAILOVER_ENABLED="false"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"

# MPTCP配置
MPTCP_MODE="off"

# Proxy配置
PROXY_MODE="off"

# 转发协议
PROTOCOL="$protocol"
RULE_EOF

            if [ "$rule_role" = "1" ]; then
                cat >> "$rule_file" << RULE_EOF || return 1

# 中转服务器配置
THROUGH_IP="::"
REMOTE_HOST=$(rule_quote "$target_host")
REMOTE_PORT=$target_port
TLS_SERVER_NAME=$(rule_quote "$tls_server_name")
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=$(rule_quote "$ws_path")
WS_HOST=$(rule_quote "$ws_host")
RULE_EOF
            else
                cat >> "$rule_file" << RULE_EOF || return 1

# 服务端服务器配置
FORWARD_TARGET=$(rule_quote "$target")
TLS_SERVER_NAME=$(rule_quote "$tls_server_name")
TLS_CERT_PATH=""
TLS_KEY_PATH=""
WS_PATH=$(rule_quote "$ws_path")
WS_HOST=$(rule_quote "$ws_host")
RULE_EOF
            fi

            local targets_display="$target_host:$target_port"
            if [ ${#all_targets[@]} -gt 1 ]; then
                targets_display="$targets_display (${target_index}/${#all_targets[@]})"
            fi

            echo "✓ 生成规则文件: rule-$rule_id.conf ($rule_name → $targets_display)"
            target_index=$((target_index + 1))
            generated_count=$((generated_count + 1))
        done
    done

    [ "$generated_count" -gt 0 ]
}

process_toml() {
    local toml_file="$1"
    local temp_json

    if ! command -v python3 >/dev/null 2>&1; then
        echo "需要Python3转换TOML格式或手动转换成json格式"
        return 1
    fi

    temp_json=$(mktemp) || return 1
    python3 - "$toml_file" "$temp_json" << 'EOF'
import sys, json
toml_file, json_file = sys.argv[1], sys.argv[2]

try:
    import tomllib
    with open(toml_file, 'rb') as f:
        data = tomllib.load(f)
except ImportError:
    try:
        import toml
        with open(toml_file, 'r') as f:
            data = toml.load(f)
    except ImportError:
        try:
            import tomli
            with open(toml_file, 'rb') as f:
                data = tomli.load(f)
        except ImportError:
            print("错误: 缺少TOML库,请安装: pip3 install tomli", file=sys.stderr)
            sys.exit(1)

with open(json_file, 'w') as f:
    json.dump(data, f)
EOF

    if [ $? -eq 0 ]; then
        process_json "$temp_json"
        local result=$?
        rm -f "$temp_json"
        return $result
    fi

    rm -f "$temp_json"
    return 1
}

case "$file_ext" in
    "json")
        if process_json "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 配置文件识别成功${NC}"
        else
            echo -e "${RED}✗ 配置文件识别失败${NC}"
            rm -rf "$OUTPUT_DIR"
            exit 1
        fi
        ;;
    "toml")
        if process_toml "$CONFIG_FILE"; then
            echo -e "${GREEN}✓ 配置文件识别成功${NC}"
        else
            echo -e "${RED}✗ 配置文件识别失败${NC}"
            rm -rf "$OUTPUT_DIR"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}错误: 不支持的文件格式${NC}"
        rm -rf "$OUTPUT_DIR"
        exit 1
        ;;
esac

echo ""

rule_count=$(ls -1 "$OUTPUT_DIR"/rule-*.conf 2>/dev/null | wc -l)
if [ "$rule_count" -eq 0 ]; then
    echo -e "${RED}错误: 未识别到有效的realm配置${NC}"
    rm -rf "$OUTPUT_DIR"
    exit 1
fi

echo -e "${BLUE}识别到 $rule_count 个转发规则:${NC}"
for rule_file in "$OUTPUT_DIR"/rule-*.conf; do
    if [ -f "$rule_file" ]; then
        source "$rule_file"

        TLS_SERVER_NAME="$TLS_SERVER_NAME"

        third_param=""
        case "$SECURITY_LEVEL" in
            "ws"|"ws_tls_self"|"ws_tls_ca")
                third_param="$WS_HOST"
                ;;
            *)
                third_param="$TLS_SERVER_NAME"
                ;;
        esac
        transport_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$third_param")

        balance_display=""
        if [ "$BALANCE_MODE" != "off" ] && [ -n "$TARGET_STATES" ]; then
            target_count=$(echo "$TARGET_STATES" | tr ',' ' ' | wc -w)
            case "$BALANCE_MODE" in
                "roundrobin") balance_display=" [轮询负载均衡:${target_count}个目标" ;;
                "iphash") balance_display=" [IP哈希负载均衡:${target_count}个目标" ;;
                *) balance_display=" [${BALANCE_MODE}负载均衡:${target_count}个目标" ;;
            esac
            if [ -n "$WEIGHTS" ]; then
                balance_display="${balance_display},权重:$WEIGHTS"
            fi
            balance_display="${balance_display}]"
        fi

        # 协议标签：对齐主脚本 get_rule_status_display，both 常态不显示
        protocol_display=""
        case "${PROTOCOL:-both}" in
            tcp) protocol_display=" | 协议: ${BLUE}[纯TCP]${NC}" ;;
            udp) protocol_display=" | 协议: ${YELLOW}[纯UDP]${NC}" ;;
        esac

        if [ "$RULE_ROLE" = "1" ]; then
            echo -e "  • ${GREEN}$RULE_NAME${NC}: $LISTEN_PORT → $REMOTE_HOST:$REMOTE_PORT"
            echo -e "    传输模式: ${YELLOW}$transport_display${NC}$balance_display$protocol_display"
        else
            echo -e "  • ${GREEN}$RULE_NAME${NC}: $LISTEN_PORT → $FORWARD_TARGET"
            echo -e "    传输模式: ${YELLOW}$transport_display${NC}$balance_display$protocol_display"
        fi
    fi
done
echo ""

echo -e "${RED}警告: 导入操作将清空现有规则并导入新配置！${NC}"
echo -e "${YELLOW}这是初始化导入，会删除所有现有的转发规则${NC}"
echo ""
read -p "确认清空现有规则并导入新配置？(y/n): " confirm
if ! echo "$confirm" | grep -qE "^[Yy]$"; then
    echo -e "${BLUE}已取消导入操作${NC}"
    rm -rf "$OUTPUT_DIR"
    exit 1
fi

echo ""
echo -e "${YELLOW}正在清空现有规则...${NC}"

if [ -d "$RULES_DIR" ]; then
    rm -rf "$RULES_DIR"/*
    echo -e "${GREEN}✓${NC} 已清空现有规则"
fi

mkdir -p "$RULES_DIR"

echo -e "${YELLOW}正在导入新配置...${NC}"

imported_count=0
for rule_file in "$OUTPUT_DIR"/rule-*.conf; do
    if [ -f "$rule_file" ]; then
        rule_name=$(basename "$rule_file")
        cp "$rule_file" "$RULES_DIR/"
        imported_count=$((imported_count + 1))
        echo -e "${GREEN}✓${NC} 导入规则文件: $rule_name"
    fi
done

rm -rf "$OUTPUT_DIR"

if [ $imported_count -gt 0 ]; then
    echo -e "${GREEN}✓ realm配置导入成功，共导入 $imported_count 个规则${NC}"
    echo ""
    echo -e "${YELLOW}正在重启服务并优化规则排序...${NC}"

    pf --restart-service

    echo -e "${GREEN}✓ 配置导入和优化完成${NC}"
    exit 0
else
    echo -e "${RED}✗ 配置导入失败${NC}"
    exit 1
fi