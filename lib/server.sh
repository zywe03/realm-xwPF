create_nat_rules_for_ports() {
    local listen_ports="$1"
    local remote_ports="$2"

    listen_ports=$(echo "$listen_ports" | tr -d ' ')
    remote_ports=$(echo "$remote_ports" | tr -d ' ')

    IFS=',' read -ra LISTEN_PORT_ARRAY <<< "$listen_ports"
    IFS=',' read -ra REMOTE_PORT_ARRAY <<< "$remote_ports"

    local listen_count=${#LISTEN_PORT_ARRAY[@]}
    local remote_count=${#REMOTE_PORT_ARRAY[@]}

    for i in "${!LISTEN_PORT_ARRAY[@]}"; do
        local listen_port="${LISTEN_PORT_ARRAY[$i]}"
        local remote_port

        if [ "$remote_count" -eq 1 ]; then
            remote_port="${REMOTE_PORT_ARRAY[0]}"
        else
            if [ "$i" -lt "$remote_count" ]; then
                remote_port="${REMOTE_PORT_ARRAY[$i]}"
            else
                remote_port="${REMOTE_PORT_ARRAY[0]}"
            fi
        fi

        create_single_nat_rule "$listen_port" "$remote_port" || return 1
    done

    if [ ${#LISTEN_PORT_ARRAY[@]} -gt 1 ]; then
        echo -e "${BLUE}多端口配置完成，共创建 ${#LISTEN_PORT_ARRAY[@]} 个中转规则${NC}"
    fi
}

create_exit_rules_for_ports() {
    local listen_ports="$1"
    local forward_ports="$2"

    listen_ports=$(echo "$listen_ports" | tr -d ' ')
    forward_ports=$(echo "$forward_ports" | tr -d ' ')

    IFS=',' read -ra LISTEN_PORT_ARRAY <<< "$listen_ports"
    IFS=',' read -ra FORWARD_PORT_ARRAY <<< "$forward_ports"

    local listen_count=${#LISTEN_PORT_ARRAY[@]}
    local forward_count=${#FORWARD_PORT_ARRAY[@]}

    for i in "${!LISTEN_PORT_ARRAY[@]}"; do
        local listen_port="${LISTEN_PORT_ARRAY[$i]}"
        local forward_port

        if [ "$forward_count" -eq 1 ]; then
            forward_port="${FORWARD_PORT_ARRAY[0]}"
        else
            if [ "$i" -lt "$forward_count" ]; then
                forward_port="${FORWARD_PORT_ARRAY[$i]}"
            else
                forward_port="${FORWARD_PORT_ARRAY[0]}"
            fi
        fi

        create_single_exit_rule "$listen_port" "$forward_port" || return 1
    done

    if [ ${#LISTEN_PORT_ARRAY[@]} -gt 1 ]; then
        echo -e "${BLUE}多端口配置完成，共创建 ${#LISTEN_PORT_ARRAY[@]} 个服务端规则${NC}"
    fi
}

create_single_nat_rule() {
    local listen_port="$1"
    local remote_port="$2"

    local rule_id=$(generate_rule_id)
    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"
    local rule_name="中转"

    # 规则文件会被 source：自由文本必须转义，否则备注里的 " 或 $(...) 会变成可执行语句
    cat > "$rule_file" <<EOF || return 1
RULE_ID=$rule_id
RULE_NAME=$(rule_quote "$rule_name")
RULE_ROLE="1"
SECURITY_LEVEL=$(rule_quote "$SECURITY_LEVEL")
LISTEN_PORT=$listen_port
LISTEN_IP=$(rule_quote "${NAT_LISTEN_IP:-::}")
THROUGH_IP=$(rule_quote "$NAT_THROUGH_IP")
REMOTE_HOST=$(rule_quote "$REMOTE_IP")
REMOTE_PORT=$remote_port
TLS_SERVER_NAME=$(rule_quote "$TLS_SERVER_NAME")
WS_PATH=$(rule_quote "$WS_PATH")
WS_HOST=$(rule_quote "$WS_HOST")
RULE_NOTE=$(rule_quote "$RULE_NOTE")
ENABLED="true"
CREATED_TIME="$(get_gmt8_time '+%Y-%m-%d %H:%M:%S')"

BALANCE_MODE="off"
TARGET_STATES=""
WEIGHTS=""

FAILOVER_ENABLED="false"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"

MPTCP_MODE="off"
PROXY_MODE="off"
PROTOCOL="${PROTOCOL:-both}"
EOF

    echo -e "${GREEN}✓ 中转配置已创建 (ID: $rule_id) 端口: $listen_port->$REMOTE_IP:$remote_port${NC}"
}

create_single_exit_rule() {
    local listen_port="$1"
    local forward_port="$2"

    local rule_id=$(generate_rule_id)
    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"
    local rule_name="服务端"
    local forward_target="$FORWARD_TARGET:$forward_port"

    cat > "$rule_file" <<EOF || return 1
RULE_ID=$rule_id
RULE_NAME=$(rule_quote "$rule_name")
RULE_ROLE="2"
SECURITY_LEVEL=$(rule_quote "$SECURITY_LEVEL")
LISTEN_PORT=$listen_port
FORWARD_TARGET=$(rule_quote "$forward_target")
TLS_SERVER_NAME=$(rule_quote "$TLS_SERVER_NAME")
WS_PATH=$(rule_quote "$WS_PATH")
WS_HOST=$(rule_quote "$WS_HOST")
RULE_NOTE=$(rule_quote "$RULE_NOTE")
ENABLED="true"
CREATED_TIME="$(get_gmt8_time '+%Y-%m-%d %H:%M:%S')"

BALANCE_MODE="off"
TARGET_STATES=""
WEIGHTS=""

FAILOVER_ENABLED="false"
HEALTH_CHECK_INTERVAL="4"
FAILURE_THRESHOLD="2"
SUCCESS_THRESHOLD="2"
CONNECTION_TIMEOUT="3"

MPTCP_MODE="off"
PROXY_MODE="off"
PROTOCOL="${PROTOCOL:-both}"
EOF

    if [ "$SECURITY_LEVEL" = "tls_ca" ] || [ "$SECURITY_LEVEL" = "ws_tls_ca" ]; then
        cat >> "$rule_file" <<EOF || return 1
TLS_CERT_PATH=$(rule_quote "$TLS_CERT_PATH")
TLS_KEY_PATH=$(rule_quote "$TLS_KEY_PATH")
EOF
    fi

    echo -e "${GREEN}✓ 服务端配置已创建 (ID: $rule_id) 端口: $listen_port->$forward_target${NC}"
}

check_mptcp_support() {
    local kernel_version=$(uname -r | cut -d. -f1,2)
    local major=$(echo $kernel_version | cut -d. -f1)
    local minor=$(echo $kernel_version | cut -d. -f2)

    if [ "$major" -lt 5 ] || ([ "$major" -eq 5 ] && [ "$minor" -le 6 ]); then
        return 1
    fi

    if [ -f "/proc/sys/net/mptcp/enabled" ]; then
        local enabled=$(cat /proc/sys/net/mptcp/enabled 2>/dev/null)
        [ "$enabled" = "1" ]
    else
        return 1
    fi
}

enable_mptcp() {
    echo -e "${BLUE}正在启用MPTCP并进行配置...${NC}"
    echo ""

    echo -e "${YELLOW}步骤1: 检查并升级iproute2包...${NC}"
    upgrade_iproute2_for_mptcp

    echo -e "${YELLOW}步骤2: 启用系统MPTCP...${NC}"
    local mptcp_conf="/etc/sysctl.d/90-enable-MPTCP.conf"

    cat > "$mptcp_conf" << EOF
# MPTCP基础配置
net.mptcp.enabled=1

# 强制使用内核路径管理器
net.mptcp.pm_type=0

# 优化反向路径过滤
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ MPTCP配置文件已创建: $mptcp_conf${NC}"

        if sysctl -p "$mptcp_conf" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ MPTCP已成功启用并保存生效${NC}"
        else
            echo -e "${YELLOW}配置文件已创建，但立即应用失败${NC}"
            echo -e "${YELLOW}请手动执行: sysctl -p $mptcp_conf${NC}"
            return 1
        fi
    else
        echo -e "${RED}错误: 无法创建MPTCP配置文件${NC}"
        return 1
    fi

    echo -e "${YELLOW}步骤3: 优化MPTCP系统参数...${NC}"

    if sysctl -w net.mptcp.pm_type=0 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 已切换到内核路径管理器${NC}"
    else
        echo -e "${YELLOW}⚠ 无法设置路径管理器类型${NC}"
    fi

    # 避免mptcpd服务与内核路径管理器冲突
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active mptcpd >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到mptcpd服务，正在停止...${NC}"
        systemctl stop mptcpd 2>/dev/null || true
        systemctl disable mptcpd 2>/dev/null || true
        echo -e "${GREEN}✓ 已停止mptcpd服务${NC}"
    fi

    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
    echo -e "${GREEN}✓ 已优化反向路径过滤设置${NC}"

    if /usr/bin/ip mptcp limits set subflows 8 add_addr_accepted 8 2>/dev/null; then
        echo -e "${GREEN}✓ MPTCP连接限制已设置为最大值 (subflows=8, add_addr_accepted=8)${NC}"
    else
        echo -e "${YELLOW}⚠ 无法设置MPTCP连接限制，使用默认值 (subflows=2, add_addr_accepted=0)${NC}"
    fi

    echo ""
    echo -e "${GREEN}✓ MPTCP基础配置完成！${NC}"
    echo -e "${BLUE}配置将自动加载${NC}"
    return 0
}

upgrade_iproute2_for_mptcp() {
    local current_version=$(/usr/bin/ip -V 2>/dev/null | grep -oP 'iproute2-\K[^,\s]+' || echo "unknown")
    echo -e "${BLUE}当前iproute2版本: $current_version${NC}"

    local mptcp_help_output=$(/usr/bin/ip mptcp help 2>&1)
    if echo "$mptcp_help_output" | grep -q "endpoint\|limits"; then
        echo -e "${GREEN}✓ 当前版本已支持MPTCP${NC}"
        return 0
    fi

    echo -e "${YELLOW}当前版本不支持MPTCP，开始升级...${NC}"

    echo -e "${BLUE}正在使用包管理器升级...${NC}"
    local apt_output
    apt_output=$(apt update 2>&1 && apt install -y iproute2 2>&1)

    local mptcp_help_output=$(/usr/bin/ip mptcp help 2>&1)
    if [ $? -eq 0 ] && echo "$mptcp_help_output" | grep -q "endpoint\|limits"; then
        echo -e "${GREEN}✓ 升级成功，MPTCP现在可用${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ 升级后仍不支持MPTCP${NC}"
        echo -e "${YELLOW}当前系统版本过低，请尝试手动更新iproute2${NC}"
        return 1
    fi
}

disable_mptcp() {
    echo -e "${BLUE}正在禁用MPTCP并清理配置...${NC}"
    echo ""

    echo -e "${YELLOW}步骤1: 清理MPTCP端点...${NC}"
    if /usr/bin/ip mptcp endpoint show >/dev/null 2>&1; then
        local endpoints_output=$(/usr/bin/ip mptcp endpoint show 2>/dev/null)
        if [ -n "$endpoints_output" ]; then
            /usr/bin/ip mptcp endpoint flush 2>/dev/null
            echo -e "${GREEN}✓ 已清理所有MPTCP端点${NC}"
        else
            echo -e "${BLUE}  无MPTCP端点需要清理${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ ip mptcp命令不可用，跳过端点清理${NC}"
    fi

    echo -e "${YELLOW}步骤2: 禁用系统MPTCP...${NC}"
    if echo 0 > /proc/sys/net/mptcp/enabled 2>/dev/null; then
        echo -e "${GREEN}✓ MPTCP已立即禁用${NC}"
    else
        echo -e "${YELLOW}立即禁用MPTCP失败，但将删除配置文件${NC}"
    fi

    echo -e "${YELLOW}步骤3: 删除配置文件...${NC}"
    local mptcp_conf="/etc/sysctl.d/90-enable-MPTCP.conf"
    if [ -f "$mptcp_conf" ]; then
        if rm -f "$mptcp_conf" 2>/dev/null; then
            echo -e "${GREEN}✓ MPTCP配置文件已删除${NC}"
        else
            echo -e "${YELLOW}无法删除配置文件: $mptcp_conf${NC}"
            echo -e "${YELLOW}请手动删除以防止重启后自动启用${NC}"
        fi
    else
        echo -e "${BLUE}  无配置文件需要删除${NC}"
    fi

    echo ""
    echo -e "${GREEN}✓ MPTCP已完全禁用！${NC}"
    echo -e "${BLUE}重启后MPTCP将保持禁用状态,恢复TCP${NC}"
    return 0
}

get_mptcp_mode_display() {
    local mode="$1"
    case "$mode" in
        "off")
            echo "关闭"
            ;;
        "send")
            echo "发送"
            ;;
        "accept")
            echo "接收"
            ;;
        "both")
            echo "双向"
            ;;
        *)
            echo "关闭"
            ;;
    esac
}

get_mptcp_mode_color() {
    local mode="$1"
    case "$mode" in
        "off")
            echo "${WHITE}"
            ;;
        "send")
            echo "${BLUE}"
            ;;
        "accept")
            echo "${YELLOW}"
            ;;
        "both")
            echo "${GREEN}"
            ;;
        *)
            echo "${WHITE}"
            ;;
    esac
}

get_network_interfaces_detailed() {
    local interfaces_info=""

    for interface in $(ip link show | grep -E '^[0-9]+:' | cut -d: -f2 | tr -d ' ' | grep -v lo); do
        local ipv4_info=""
        local ipv6_info=""

        local ipv4_addrs=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP 'inet \K[^/]+/[0-9]+' | head -1)
        if [ -n "$ipv4_addrs" ]; then
            ipv4_info="$ipv4_addrs (IPv4)"
        else
            ipv4_info="未配置IPv4"
        fi

        local ipv6_addrs=$(ip -6 addr show "$interface" 2>/dev/null | grep -oP 'inet6 \K[^/]+/[0-9]+' | grep -v '^fe80:' | head -1)
        if [ -n "$ipv6_addrs" ]; then
            ipv6_info="$ipv6_addrs (IPv6)"
        else
            ipv6_info="未配置IPv6"
        fi

        local vlan_info=""
        if [[ "$interface" == *"."* ]]; then
            vlan_info=" (VLAN)"
        fi

        interfaces_info="${interfaces_info}  网卡 $interface: $ipv4_info | $ipv6_info$vlan_info\n"
    done

    echo -e "$interfaces_info"
}

get_mptcp_endpoints_status() {
    local endpoints_output=$(/usr/bin/ip mptcp endpoint show 2>/dev/null)
    local endpoint_count=0
    local endpoints_info=""

    if [ -n "$endpoints_output" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                endpoint_count=$((endpoint_count + 1))
                local id=$(echo "$line" | grep -oP 'id \K[0-9]+' || echo "")
                local addr=$(echo "$line" | grep -oP '^[^ ]+' || echo "")
                local dev=$(echo "$line" | grep -oP 'dev \K[^ ]+' || echo "")
                local flags=""
                if echo "$line" | grep -q "subflow.*fullmesh"; then
                    flags="[subflow fullmesh]"
                elif echo "$line" | grep -q "subflow.*backup"; then
                    flags="[subflow backup]"
                elif echo "$line" | grep -q "signal"; then
                    flags="[signal]"
                else
                    flags="[unknown]"
                fi

                if [ -n "$addr" ]; then
                    endpoints_info="${endpoints_info}  ID $id: $addr dev $dev $flags\n"
                fi
            fi
        done <<< "$endpoints_output"
    fi

    echo -e "${BLUE}MPTCP端点配置:${NC}"
    if [ $endpoint_count -gt 0 ]; then
        echo -e "$endpoints_info"
    else
        echo -e "  ${YELLOW}暂无MPTCP端点配置${NC}"
    fi

    return $endpoint_count
}

get_mptcp_connections_stats() {
    local ss_output=$(ss -M 2>/dev/null)
    local mptcp_connections=0
    local subflows=0

    if [ -n "$ss_output" ]; then
        mptcp_connections=$(echo "$ss_output" | grep -c ESTAB 2>/dev/null || true)

        # 统计子流数量 (总行数减1，最少为0)
        local total_lines=$(echo "$ss_output" | wc -l)
        subflows=$(( total_lines > 1 ? total_lines - 1 : 0 ))
    fi

    if [ "$mptcp_connections" -eq 0 ] && [ "$subflows" -eq 0 ]; then
        echo "活跃连接: 0个 | 子流: 0个 (无连接时为0正常现象)"
    else
        echo "活跃连接: ${mptcp_connections}个 | 子流: ${subflows}个"
    fi
}

mptcp_handle_unsupported_state() {
    local kernel_version=$(uname -r)
    local kernel_major=$(echo $kernel_version | cut -d. -f1)
    local kernel_minor=$(echo $kernel_version | cut -d. -f2)

    echo -e "${RED}系统不支持MPTCP或未启用${NC}"
    echo ""
    echo -e "${YELLOW}MPTCP要求：${NC}"
    echo -e "  • Linux内核版本 > 5.6"
    echo -e "  • net.mptcp.enabled=1"
    echo ""

    echo -e "${BLUE}当前内核版本: ${GREEN}$kernel_version${NC}"

    if [ "$kernel_major" -lt 5 ] || ([ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -le 6 ]); then
        echo -e "${RED}✗ 内核版本不支持MPTCP${NC}(需要 > 5.6)"
    else
        echo -e "${GREEN}✓ 内核版本支持MPTCP${NC}"
    fi

    if [ -f "/proc/sys/net/mptcp/enabled" ]; then
        local enabled=$(cat /proc/sys/net/mptcp/enabled 2>/dev/null)
        if [ "$enabled" = "1" ]; then
            echo -e "${GREEN}✓ MPTCP已启用${NC}(net.mptcp.enabled=$enabled)"
        else
            echo -e "${RED}✗ MPTCP未启用${NC}(net.mptcp.enabled=$enabled，需要为1)"
        fi
    else
        echo -e "${RED}✗ 系统不支持MPTCP${NC}(/proc/sys/net/mptcp/enabled 不存在)"
    fi

    echo ""
    read -p "是否尝试启用MPTCP? [y/N]: " enable_choice
    if [[ "$enable_choice" =~ ^[Yy]$ ]]; then
        enable_mptcp
    fi
    echo ""
    read -p "按回车键返回..."
}

mptcp_check_and_persist_config() {
    local current_status=$(cat /proc/sys/net/mptcp/enabled 2>/dev/null)
    local config_file="/etc/sysctl.d/90-enable-MPTCP.conf"

    echo -e "${GREEN}✓ 系统支持MPTCP${NC}(net.mptcp.enabled=$current_status)"

    if [ "$current_status" = "1" ]; then
        if [ -f "$config_file" ]; then
            echo -e "${GREEN}✓ 系统已开启MPTCP${NC}(MPTCP配置已设置)"
        else
            echo -e "${YELLOW}⚠ 系统已开启MPTCP${NC}(临时开启，重启后可能失效)"
            echo ""
            read -p "是否保存为配置文件重启依旧生效？[y/N]: " save_config
            if [[ "$save_config" =~ ^[Yy]$ ]]; then
                if echo "net.mptcp.enabled=1" > "$config_file" 2>/dev/null; then
                    echo -e "${GREEN}✓ MPTCP配置已保存: $config_file${NC}"

                    if sysctl -p "$config_file" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓ 配置已立即生效，重启后自动加载${NC}"
                    else
                        echo -e "${YELLOW}配置文件已保存，但立即应用失败${NC}"
                        echo -e "${BLUE}手动应用配置: sysctl -p $config_file${NC}"
                    fi
                    echo ""
                    read -p "按回车键刷新状态显示..."
                    return 0
                else
                    echo -e "${RED}✗ 保存MPTCP配置失败${NC}"
                    echo -e "${YELLOW}请手动执行: echo 'net.mptcp.enabled=1' > $config_file${NC}"
                fi
            fi
        fi
    else
        echo -e "${RED}✗ 系统未开启MPTCP${NC}(当前为普通TCP模式)"
    fi
    echo ""
    return 1
}

mptcp_display_dashboard() {
    echo -e "${BLUE}网络环境状态:${NC}"
    get_network_interfaces_detailed
    echo ""

    get_mptcp_endpoints_status
    local connections_stats=$(get_mptcp_connections_stats)
    echo -e "${BLUE}MPTCP连接统计:${NC}"
    echo -e "  $connections_stats"
    echo ""
}

mptcp_management_menu() {
    # 初始化MPTCP字段（确保向后兼容）
    init_mptcp_fields

    while true; do
        clear
        echo -e "${GREEN}=== MPTCP 管理 ===${NC}"
        echo ""

        if ! check_mptcp_support; then
            mptcp_handle_unsupported_state
            return
        fi

        if mptcp_check_and_persist_config; then
            continue
        fi

        mptcp_display_dashboard

        if ! list_rules_with_info "mptcp"; then
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo -e "${RED}规则ID 0: 关闭系统MPTCP，回退普通TCP模式${NC}"
        echo -e "${BLUE}输入 add: 添加MPTCP端点 | del: 删除MPTCP端点 | look: 查看MPTCP详细状态${NC}"
        read -p "请输入要配置的规则ID(多ID使用逗号,分隔，0为关闭系统MPTCP): " rule_input
        if [ -z "$rule_input" ]; then
            return
        fi

        case "$rule_input" in
            "add")
                add_mptcp_endpoint_interactive
                read -p "按回车键继续..."
                continue
                ;;
            "del")
                delete_mptcp_endpoint_interactive
                read -p "按回车键继续..."
                continue
                ;;
            "look")
                show_mptcp_detailed_status
                read -p "按回车键继续..."
                continue
                ;;
        esac

        if [ "$rule_input" = "0" ]; then
            echo ""
            echo -e "${YELLOW}确认关闭系统MPTCP？这将影响所有MPTCP连接。${NC}"
            read -p "继续? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                set_mptcp_mode "0" ""
            fi
            read -p "按回车键继续..."
            continue
        fi

        echo ""
        echo -e "${BLUE}请选择新的 MPTCP 模式:${NC}"
        echo -e "${WHITE}1.${NC} off (关闭)"
        echo -e "${BLUE}2.${NC} 仅发送"
        echo -e "${YELLOW}3.${NC} 仅接收"
        echo -e "${GREEN}4.${NC} 双向(发送+接收)"
        echo ""

        read -p "请选择MPTCP模式 [1-4]: " mode_choice
        if [ -z "$mode_choice" ]; then
            continue
        fi

        if [[ "$rule_input" == *","* ]]; then
            batch_set_mptcp_mode "$rule_input" "$mode_choice"
        else
            if [[ "$rule_input" =~ ^[0-9]+$ ]]; then
                set_mptcp_mode "$rule_input" "$mode_choice"
            else
                echo -e "${RED}无效的规则ID${NC}"
            fi
        fi
        read -p "按回车键继续..."
    done
}

batch_set_mptcp_mode() {
    local rule_ids="$1"
    local mode_choice="$2"

    local validation_result=$(validate_rule_ids "$rule_ids")
    IFS='|' read -r valid_count invalid_count valid_ids invalid_ids <<< "$validation_result"

    if [ "$invalid_count" -gt 0 ]; then
        echo -e "${RED}错误: 以下规则ID无效或不存在: $invalid_ids${NC}"
        return 1
    fi

    if [ "$valid_count" -eq 0 ]; then
        echo -e "${RED}错误: 没有找到有效的规则ID${NC}"
        return 1
    fi

    local valid_ids_array
    IFS=' ' read -ra valid_ids_array <<< "$valid_ids"

    echo -e "${YELLOW}即将为以下规则设置MPTCP模式:${NC}"
    echo ""
    for id in "${valid_ids_array[@]}"; do
        local rule_file="${RULES_DIR}/rule-${id}.conf"
        if read_rule_file "$rule_file"; then
            echo -e "${BLUE}规则ID: ${GREEN}$RULE_ID${NC} | ${BLUE}规则名称: ${GREEN}$RULE_NAME${NC}"
        fi
    done
    echo ""

    read -p "确认为以上 $valid_count 个规则设置MPTCP模式？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local success_count=0
        for id in "${valid_ids_array[@]}"; do
            if set_mptcp_mode "$id" "$mode_choice" "batch"; then
                success_count=$((success_count + 1))
            fi
        done

        if [ $success_count -gt 0 ]; then
            echo -e "${GREEN}✓ 成功设置 $success_count 个规则的MPTCP模式${NC}"
            echo -e "${YELLOW}正在重启服务以应用配置更改...${NC}"
            if service_restart; then
                echo -e "${GREEN}✓ 服务重启成功，MPTCP配置已生效${NC}"
            else
                echo -e "${RED}✗ 服务重启失败，请检查配置${NC}"
            fi
            return 0
        else
            echo -e "${RED}✗ 没有成功设置任何规则${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}操作已取消${NC}"
        return 1
    fi
}

set_mptcp_mode() {
    local rule_id="$1"
    local mode_choice="$2"
    local batch_mode="$3"

    # 特殊处理规则ID 0：关闭系统MPTCP
    if [ "$rule_id" = "0" ]; then
        echo -e "${YELLOW}正在关闭系统MPTCP...${NC}"
        disable_mptcp
        echo -e "${GREEN}✓ 系统MPTCP已关闭，所有连接将使用普通TCP模式${NC}"
        return 0
    fi

    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"
    if [ ! -f "$rule_file" ]; then
        echo -e "${RED}错误: 规则 $rule_id 不存在${NC}"
        return 1
    fi

    if ! read_rule_file "$rule_file"; then
        echo -e "${RED}错误: 读取规则文件失败${NC}"
        return 1
    fi

    local new_mode
    case "$mode_choice" in
        "1")
            new_mode="off"
            ;;
        "2")
            new_mode="send"
            ;;
        "3")
            new_mode="accept"
            ;;
        "4")
            new_mode="both"
            ;;
        *)
            echo -e "${RED}无效的模式选择${NC}"
            return 1
            ;;
    esac

    local mode_display=$(get_mptcp_mode_display "$new_mode")
    local mode_color=$(get_mptcp_mode_color "$new_mode")

    if [ "$batch_mode" != "batch" ]; then
        echo -e "${YELLOW}正在为规则 '$RULE_NAME' 设置MPTCP模式为: ${mode_color}$mode_display${NC}"
    fi

    local temp_file="${rule_file}.tmp.$$"

    if grep -q "^MPTCP_MODE=" "$rule_file"; then
        grep -v "^MPTCP_MODE=" "$rule_file" > "$temp_file"
        echo "MPTCP_MODE=\"$new_mode\"" >> "$temp_file"
        mv "$temp_file" "$rule_file"
    else
        echo "MPTCP_MODE=\"$new_mode\"" >> "$rule_file"
    fi

    if [ $? -eq 0 ]; then
        if [ "$batch_mode" != "batch" ]; then
            echo -e "${GREEN}✓ MPTCP模式已更新为: ${mode_color}$mode_display${NC}"
        fi
        restart_and_confirm "MPTCP配置" "$batch_mode"
        return $?
    else
        if [ "$batch_mode" != "batch" ]; then
            echo -e "${RED}✗ 更新MPTCP模式失败${NC}"
        fi
        return 1
    fi
}

# 初始化所有规则文件的MPTCP字段（确保向后兼容）
init_mptcp_fields() {
    init_rule_field "MPTCP_MODE" "off"
}

mptcp_select_interface() {
    local interfaces=()
    local interface_names=()
    local interface_count=0

    for interface in $(ip link show | grep -E '^[0-9]+:' | cut -d: -f2 | tr -d ' ' | grep -v lo); do
        local ipv4_addrs=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP 'inet \K[^/]+' | tr '\n' ' ')
        local ipv6_addrs=$(ip -6 addr show "$interface" 2>/dev/null | grep -oP 'inet6 \K[^/]+' | grep -v '^fe80:' | tr '\n' ' ')

        if [ -n "$ipv4_addrs" ] || [ -n "$ipv6_addrs" ]; then
            interface_count=$((interface_count + 1))
            interfaces+=("$interface")

            local display_info="$interface: "
            if [ -n "$ipv4_addrs" ]; then
                display_info="${display_info}${ipv4_addrs}(IPv4)"
            else
                display_info="${display_info}未配置IPv4"
            fi

            display_info="${display_info} | "

            if [ -n "$ipv6_addrs" ]; then
                display_info="${display_info}${ipv6_addrs}(IPv6)"
            else
                display_info="${display_info}未配置IPv6"
            fi

            interface_names+=("$display_info")
        fi
    done

    if [ $interface_count -eq 0 ]; then
        echo -e "${RED}未找到配置IP地址的网络接口${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}当前网络接口:${NC}" >&2
    for i in $(seq 0 $((interface_count - 1))); do
        echo -e "${GREEN}$((i + 1)).${NC} ${interface_names[$i]}" >&2
    done
    echo "" >&2

    echo -n "请选择网卡 [1-$interface_count]: " >&2
    read interface_choice
    if [[ ! "$interface_choice" =~ ^[0-9]+$ ]] || [ "$interface_choice" -lt 1 ] || [ "$interface_choice" -gt $interface_count ]; then
        echo -e "${RED}无效的选择${NC}" >&2
        return 1
    fi

    echo "${interfaces[$((interface_choice - 1))]}"
}

mptcp_select_ips() {
    local selected_interface="$1"
    local selected_ips=()
    local ip_display=()
    local ip_count=0

    local ipv4_list=$(ip -4 addr show "$selected_interface" 2>/dev/null | grep -oP 'inet \K[^/]+')
    if [ -n "$ipv4_list" ]; then
        while IFS= read -r ip; do
            if [ -n "$ip" ]; then
                ip_count=$((ip_count + 1))
                selected_ips+=("$ip")
                ip_display+=("$ip (IPv4)")
            fi
        done <<< "$ipv4_list"
    fi

    local ipv6_list=$(ip -6 addr show "$selected_interface" 2>/dev/null | grep -oP 'inet6 \K[^/]+' | grep -v '^fe80:')
    if [ -n "$ipv6_list" ]; then
        while IFS= read -r ip; do
            if [ -n "$ip" ]; then
                ip_count=$((ip_count + 1))
                selected_ips+=("$ip")
                ip_display+=("$ip (IPv6)")
            fi
        done <<< "$ipv6_list"
    fi

    if [ $ip_count -eq 0 ]; then
        echo -e "${RED}选中的网卡没有可用的IP地址${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}${selected_interface} 的可用IP地址:${NC}" >&2
    for i in $(seq 0 $((ip_count - 1))); do
        echo -e "${GREEN}$((i + 1)).${NC} ${ip_display[$i]}" >&2
    done
    echo "" >&2

    echo -n "请选择IP地址(回车默认全选): " >&2
    read ip_choice

    if [ -z "$ip_choice" ]; then
        echo -e "${BLUE}已选择全部IP地址${NC}" >&2
        printf "%s\n" "${selected_ips[@]}"
    else
        if [[ ! "$ip_choice" =~ ^[0-9]+$ ]] || [ "$ip_choice" -lt 1 ] || [ "$ip_choice" -gt $ip_count ]; then
            echo -e "${RED}无效的选择${NC}" >&2
            return 1
        fi
        echo -e "${BLUE}已选择IP地址: ${selected_ips[$((ip_choice - 1))]}${NC}" >&2
        echo "${selected_ips[$((ip_choice - 1))]}"
    fi
}

mptcp_select_endpoint_type() {
    echo "" >&2
    echo -e "${BLUE}请选择MPTCP端点类型:${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}建议:${NC}" >&2
    echo -e "  • 中转机/客户端: 选择 subflow fullmesh" >&2
    echo -e "  • 服务端机/服务端: 选择 signal (可选)" >&2
    echo -e "  • 备用路径: 选择 subflow backup (仅在主路径故障时使用)" >&2
    echo "" >&2
    echo -e "${GREEN}1.${NC} subflow fullmesh (客户端模式 - 全网格连接)" >&2
    echo -e "${BLUE}2.${NC} signal (服务端模式 - 通告地址给客户端)" >&2
    echo -e "${YELLOW}3.${NC} subflow backup (备用模式)" >&2
    echo "" >&2

    echo -n "请选择端点类型(回车默认 1) [1-3]: " >&2
    read type_choice

    if [ -z "$type_choice" ]; then
        type_choice="1"
    fi

    case "$type_choice" in
        "1")
            echo "subflow fullmesh"
            ;;
        "2")
            echo "signal"
            ;;
        "3")
            echo "subflow backup"
            ;;
        *)
            echo -e "${RED}无效的选择，请重新输入${NC}" >&2
            return 1
            ;;
    esac
}

mptcp_select_endpoint_to_delete() {
    echo -e "${BLUE}当前MPTCP端点:${NC}" >&2
    local endpoints_output=$(/usr/bin/ip mptcp endpoint show 2>/dev/null)

    if [ -z "$endpoints_output" ]; then
        echo -e "${YELLOW}暂无MPTCP端点配置${NC}" >&2
        return 1
    fi

    local endpoint_count=0
    local endpoints_list=()

    while IFS= read -r line; do
        if [ -n "$line" ]; then
            endpoint_count=$((endpoint_count + 1))
            endpoints_list+=("$line")

            local id=$(echo "$line" | grep -oP 'id \K[0-9]+' || echo "")
            local addr=$(echo "$line" | grep -oP '^[^ ]+' || echo "")
            local dev=$(echo "$line" | grep -oP 'dev \K[^ ]+' || echo "")
            local flags=""
            if echo "$line" | grep -q "subflow.*fullmesh"; then
                flags="[subflow fullmesh]"
            elif echo "$line" | grep -q "subflow.*backup"; then
                flags="[subflow backup]"
            elif echo "$line" | grep -q "signal"; then
                flags="[signal]"
            else
                flags="[unknown]"
            fi

            echo -e "  ${endpoint_count}. ID $id: $addr dev $dev $flags" >&2
        fi
    done <<< "$endpoints_output"

    if [ $endpoint_count -eq 0 ]; then
        echo -e "${YELLOW}暂无MPTCP端点配置${NC}" >&2
        return 1
    fi

    echo "" >&2
    echo -n "请选择要删除的端点编号 [1-$endpoint_count]: " >&2
    read choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $endpoint_count ]; then
        echo -e "${RED}无效的选择${NC}" >&2
        return 1
    fi

    echo "${endpoints_list[$((choice-1))]}"
}

add_mptcp_endpoint_interactive() {
    echo -e "${GREEN}=== 添加MPTCP端点 ===${NC}"
    echo ""

    echo -e "${BLUE}当前MPTCP端点:${NC}"
    get_mptcp_endpoints_status
    echo ""

    local selected_interface
    selected_interface=$(mptcp_select_interface)
    if [ $? -ne 0 ]; then return 1; fi

    echo -e "${BLUE}已选择网卡: $selected_interface${NC}"
    echo ""

    local selected_ips_output
    selected_ips_output=$(mptcp_select_ips "$selected_interface")
    if [ $? -ne 0 ]; then return 1; fi

    local selected_ip_list=()
    while IFS= read -r ip; do
        if [ -n "$ip" ]; then
            selected_ip_list+=("$ip")
        fi
    done <<< "$selected_ips_output"

    echo ""

    local endpoint_type
    endpoint_type=$(mptcp_select_endpoint_type)
    if [ $? -ne 0 ]; then return 1; fi
    
    local type_description="$endpoint_type"
    case "$endpoint_type" in
        "subflow fullmesh") type_description="subflow fullmesh (全网格模式)" ;;
        "signal") type_description="signal (服务端模式)" ;;
        "subflow backup") type_description="subflow backup (备用模式)" ;;
    esac

    echo -e "${YELLOW}正在添加MPTCP端点...${NC}"
    local success_count=0
    local total_count=${#selected_ip_list[@]}

    for ip_address in "${selected_ip_list[@]}"; do
        echo -e "${BLUE}执行命令: /usr/bin/ip mptcp endpoint add $ip_address dev $selected_interface $endpoint_type${NC}"

        local error_output
        error_output=$(/usr/bin/ip mptcp endpoint add "$ip_address" dev "$selected_interface" $endpoint_type 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}✓ MPTCP端点添加成功: $ip_address${NC}"
            success_count=$((success_count + 1))
        else
            echo -e "${RED}✗ MPTCP端点添加失败: $ip_address${NC}"
            echo -e "${RED}错误信息: $error_output${NC}"
        fi
    done

    echo ""
    echo -e "${BLUE}添加结果: 成功 $success_count/$total_count${NC}"
    echo -e "${BLUE}网络接口: $selected_interface${NC}"
    echo -e "${BLUE}端点模式: $type_description${NC}"

    if [ $success_count -gt 0 ]; then
        echo ""
        echo -e "${BLUE}更新后的MPTCP端点:${NC}"
        get_mptcp_endpoints_status
    else
        echo -e "${YELLOW}可能的原因:${NC}"
        echo -e "  • 系统过低导致iproute2版本不支持MPTCP"
        echo -e "  • IP地址已存在"
        echo -e "  • 网络接口配置问题"
    fi
}

delete_mptcp_endpoint_interactive() {
    echo -e "${GREEN}=== 删除MPTCP端点 ===${NC}"
    echo ""

    local selected_line
    selected_line=$(mptcp_select_endpoint_to_delete)
    if [ $? -ne 0 ]; then return 0; fi

    local endpoint_id=$(echo "$selected_line" | grep -oP 'id \K[0-9]+' || echo "")
    local endpoint_addr=$(echo "$selected_line" | grep -oP '^[^ ]+' || echo "")

    echo ""
    echo -e "${YELLOW}确认删除MPTCP端点:${NC}"
    echo -e "  ID: $endpoint_id"
    echo -e "  地址: $endpoint_addr"
    read -p "继续删除? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在删除MPTCP端点...${NC}"
        if /usr/bin/ip mptcp endpoint delete id "$endpoint_id" 2>/dev/null; then
            echo -e "${GREEN}✓ MPTCP端点删除成功${NC}"

            echo ""
            echo -e "${BLUE}更新后的MPTCP端点:${NC}"
            get_mptcp_endpoints_status
        else
            echo -e "${RED}✗ MPTCP端点删除失败${NC}"
            return 1
        fi
    else
        echo -e "${BLUE}已取消删除操作${NC}"
    fi
}

show_mptcp_detailed_status() {
    echo -e "${GREEN}=== MPTCP详细状态 ===${NC}"
    echo ""

    echo -e "${BLUE}系统MPTCP状态:${NC}"
    local mptcp_enabled=$(cat /proc/sys/net/mptcp/enabled 2>/dev/null || echo "0")
    if [ "$mptcp_enabled" = "1" ]; then
        echo -e "  ✓ MPTCP已启用 (net.mptcp.enabled=$mptcp_enabled)"
    else
        echo -e "  ✗ MPTCP未启用 (net.mptcp.enabled=$mptcp_enabled)"
    fi
    echo ""

    echo -e "${BLUE}MPTCP连接限制:${NC}"
    local limits_output=$(/usr/bin/ip mptcp limits show 2>/dev/null)
    if [ -n "$limits_output" ]; then
        echo "  $limits_output"
    else
        echo -e "  ${YELLOW}无法获取连接限制信息${NC}"
    fi
    echo ""

    echo -e "${BLUE}网络接口状态:${NC}"
    get_network_interfaces_detailed
    echo ""

    get_mptcp_endpoints_status
    echo ""

    echo -e "${BLUE}MPTCP连接统计:${NC}"
    local connections_stats=$(get_mptcp_connections_stats)
    echo -e "  $connections_stats"
    echo ""

    echo -e "${BLUE}活跃MPTCP连接详情:${NC}"
    local mptcp_connections=$(ss -M 2>/dev/null)
    if [ -n "$mptcp_connections" ] && [ "$(echo "$mptcp_connections" | wc -l)" -gt 1 ]; then
        echo "$mptcp_connections"
    else
        echo -e "  ${YELLOW}暂无活跃MPTCP连接${NC}"
    fi
    echo ""

    echo -e "${BLUE}实时MPTCP事件监控:${NC}"
    echo -e "${YELLOW}正在启动实时监控，按 Ctrl+C 退出...${NC}"
    echo ""
    ip mptcp monitor || echo -e "  ${YELLOW}MPTCP事件监控不可用${NC}"
}

configure_nat_server() {
    echo -e "${YELLOW}=== 中转服务器配置(不了解入口出口一般回车默认即可) ===${NC}"
    echo ""

echo -e "${BLUE}多端口使用,逗号分隔(回车随机端口)${NC}"
while true; do
    read -p "请输入本地监听端口 (客户端连接的端口，nat机需使用分配的端口): " NAT_LISTEN_PORT

    if [[ -z "$NAT_LISTEN_PORT" ]]; then
        NAT_LISTEN_PORT=$((RANDOM % 64512 + 1024))
    fi

    if validate_ports "$NAT_LISTEN_PORT"; then
        echo -e "${GREEN}监听端口设置为: $NAT_LISTEN_PORT${NC}"
        break
    else
        echo -e "${RED}无效端口号，请输入 1-65535 之间的数字，多端口用逗号分隔${NC}"
    fi
done

    local is_multi_port=false
    local port_status=0

    if [[ "$NAT_LISTEN_PORT" == *","* ]]; then
        is_multi_port=true
        echo -e "${BLUE}检测到多端口配置，跳过端口占用检测${NC}"
        port_status=0  # 多端口不检测占用
    else
        check_port_usage "$NAT_LISTEN_PORT" "中转服务器监听"
        port_status=$?
    fi

    if [ $port_status -eq 1 ]; then
        echo -e "${BLUE}检测到端口已被realm占用，读取现有配置，直接进入出口服务器配置${NC}"
        echo ""

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$LISTEN_PORT" = "$NAT_LISTEN_PORT" ] && [ "$RULE_ROLE" = "1" ]; then
                    NAT_LISTEN_IP="${LISTEN_IP}"
                    NAT_THROUGH_IP="${THROUGH_IP:-::}"
                    SECURITY_LEVEL="${SECURITY_LEVEL}"
                    TLS_SERVER_NAME="${TLS_SERVER_NAME}"
                    WS_PATH="${WS_PATH}"
                    WS_HOST="${WS_HOST}"
                    RULE_NOTE="${RULE_NOTE:-}"  # 复用现有备注
                    PROTOCOL="${PROTOCOL:-both}"  # 复用现有转发协议
                    echo -e "${GREEN}已读取端口 $NAT_LISTEN_PORT 的现有配置${NC}"
                    break
                fi
            fi
        done

    else
        RULE_NOTE=""
        echo ""

        while true; do
            read -p "自定义(指定)入口监听IP/网卡接口(客户端连接IP/网卡,回车默认全部监听 ::): " listen_ip_input

            if [ -z "$listen_ip_input" ]; then
                NAT_LISTEN_IP="::"
                echo -e "${GREEN}使用默认监听IP: :: (全部监听)${NC}"
                break
            else
                if validate_ip "$listen_ip_input"; then
                    NAT_LISTEN_IP="$listen_ip_input"
                    echo -e "${GREEN}监听IP设置为: $NAT_LISTEN_IP${NC}"
                    break
                elif [[ "$listen_ip_input" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                    NAT_LISTEN_IP="$listen_ip_input"
                    echo -e "${GREEN}监听网卡设置为: $NAT_LISTEN_IP${NC}"
                    break
                else
                    echo -e "${RED}无效IP地址或网卡名称格式${NC}"
                    echo -e "${YELLOW}示例: 192.168.1.100 或 2001:db8::1 或 eth0${NC}"
                fi
            fi
        done

        echo ""

        while true; do
            read -p "自定义(指定)出口IP/网卡接口(适用于多IP/网卡出口情况,回车默认全部监听 ::): " through_ip_input

            if [ -z "$through_ip_input" ]; then
                NAT_THROUGH_IP="::"
                echo -e "${GREEN}使用默认出口IP: :: (全部监听)${NC}"
                break
            else
                if validate_ip "$through_ip_input"; then
                    NAT_THROUGH_IP="$through_ip_input"
                    echo -e "${GREEN}出口IP设置为: $NAT_THROUGH_IP${NC}"
                    break
                elif [[ "$through_ip_input" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                    NAT_THROUGH_IP="$through_ip_input"
                    echo -e "${GREEN}出口网卡设置为: $NAT_THROUGH_IP${NC}"
                    break
                else
                    echo -e "${RED}无效IP地址或网卡名称格式${NC}"
                    echo -e "${YELLOW}示例: 192.168.1.100 或 2001:db8::1 或 eth0${NC}"
                fi
            fi
        done

        echo ""
    fi

    echo -e "${YELLOW}=== 出口服务器信息配置 ===${NC}"
    echo ""

    while true; do
        read -p "出口服务器的IP地址或域名: " REMOTE_IP
        if [ -n "$REMOTE_IP" ]; then
            if validate_ip "$REMOTE_IP" || [[ "$REMOTE_IP" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                echo -e "${RED}请输入有效的IP地址或域名${NC}"
            fi
        else
            echo -e "${RED}IP地址或域名不能为空${NC}"
        fi
    done

    while true; do
        read -p "出口服务器的监听端口(多端口使用,逗号分隔): " REMOTE_PORT
        if validate_ports "$REMOTE_PORT"; then
            break
        else
            echo -e "${RED}无效端口号，请输入 1-65535 之间的数字，多端口用逗号分隔${NC}"
        fi
    done

    # 转发协议选择：端口被复用时沿用现有协议，否则询问
    if [ $port_status -ne 1 ]; then
        echo ""
        echo -e "${YELLOW}=== 转发协议配置 ===${NC}"
        echo "请选择转发协议:"
        echo -e "${GREEN}[1]${NC} TCP+UDP 双栈（默认）"
        echo -e "${GREEN}[2]${NC} 仅 TCP"
        echo -e "${GREEN}[3]${NC} 仅 UDP"
        echo ""
        while true; do
            read -p "请输入选择(回车默认1) [1-3]: " proto_choice
            [ -z "$proto_choice" ] && proto_choice="1"
            case "$proto_choice" in
                1) PROTOCOL="both" ; echo -e "${GREEN}已选择: TCP+UDP 双栈${NC}"; break ;;
                2) PROTOCOL="tcp"  ; echo -e "${GREEN}已选择: 仅 TCP${NC}"; break ;;
                3) PROTOCOL="udp"  ; echo -e "${GREEN}已选择: 仅 UDP${NC}"; break ;;
                *) echo -e "${RED}无效选择，请输入 1-3${NC}" ;;
            esac
        done
        echo ""
    fi

    local connectivity_ok=true

    if [[ "$REMOTE_PORT" == *","* ]]; then
        echo -e "${BLUE}多端口配置，跳过连通性测试${NC}"
    else
        echo -e "${YELLOW}正在测试与出口服务器的连通性...${NC}"
        if check_connectivity "$REMOTE_IP" "$REMOTE_PORT"; then
            echo -e "${GREEN}✓ 连接测试成功！${NC}"
        else
            echo -e "${RED}✗ 连接测试失败，请检查出口服务器是否已启动并确认IP和端口正确${NC}"
            connectivity_ok=false
        fi
    fi

    if [ "$connectivity_ok" = false ]; then

        if ! validate_ip "$REMOTE_IP" && [[ "$REMOTE_IP" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${YELLOW}检测到您使用的是域名地址，如果是DDNS域名：${NC}"
            echo -e "${YELLOW}确认域名和端口正确后，直接继续配置无需担心${NC}"
        fi

        read -p "是否继续配置？(y/n): " continue_config
        if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
            echo "配置已取消"
            exit 1
        fi
    fi

    # 如果端口被realm占用，跳过协议和传输配置
    if [ $port_status -eq 1 ]; then

        echo -e "${BLUE}使用默认配置完成设置${NC}"
    # 纯 UDP 无 TCP 连接，ws/tls 加密传输挂在 TCP 上对纯 UDP 无效，直接默认传输
    elif [ "$PROTOCOL" = "udp" ]; then

        SECURITY_LEVEL="standard"
        echo -e "${BLUE}纯 UDP 无需传输加密，使用默认传输${NC}"
    else

    echo ""
    echo "请选择传输模式:"
    echo -e "${GREEN}[1]${NC} 默认传输 (不加密，理论最快)"
    echo -e "${GREEN}[2]${NC} WebSocket (ws)"
    echo -e "${GREEN}[3]${NC} TLS (自签证书，自动生成)"
    echo -e "${GREEN}[4]${NC} TLS (CA签发证书)"
    echo -e "${GREEN}[5]${NC} TLS+WebSocket (自签证书)"
    echo -e "${GREEN}[6]${NC} TLS+WebSocket (CA证书)"
    echo ""

    while true; do
        read -p "请输入选择(回车默认1) [1-6]: " transport_choice
        if [ -z "$transport_choice" ]; then
            transport_choice="1"
        fi
        case $transport_choice in
            1)
                SECURITY_LEVEL="standard"
                echo -e "${GREEN}已选择: 默认传输${NC}"
                break
                ;;
            2)
                SECURITY_LEVEL="ws"
                echo -e "${GREEN}已选择: WebSocket${NC}"

                echo ""
                read -p "请输入WebSocket Host [默认: $DEFAULT_SNI_DOMAIN]: " WS_HOST
                if [ -z "$WS_HOST" ]; then
                    WS_HOST="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}WebSocket Host设置为: $WS_HOST${NC}"

                echo ""
                read -p "请输入WebSocket路径 [默认: /ws]: " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/ws"
                fi
                echo -e "${GREEN}WebSocket路径设置为: $WS_PATH${NC}"
                break
                ;;
            3)
                SECURITY_LEVEL="tls_self"
                echo -e "${GREEN}已选择: TLS自签证书${NC}"

                echo ""
                read -p "请输入TLS服务器名称 (SNI) [默认$DEFAULT_SNI_DOMAIN]: " TLS_SERVER_NAME
                if [ -z "$TLS_SERVER_NAME" ]; then
                    TLS_SERVER_NAME="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}TLS服务器名称设置为: $TLS_SERVER_NAME${NC}"
                break
                ;;
            4)
                SECURITY_LEVEL="tls_ca"
                echo -e "${GREEN}已选择: TLS CA证书${NC}"

                echo ""
                read -p "请输入TLS服务器名称 (SNI) [默认$DEFAULT_SNI_DOMAIN]: " TLS_SERVER_NAME
                if [ -z "$TLS_SERVER_NAME" ]; then
                    TLS_SERVER_NAME="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}TLS服务器名称设置为: $TLS_SERVER_NAME${NC}"
                echo -e "${GREEN}TLS配置完成${NC}"
                break
                ;;
            5)
                SECURITY_LEVEL="ws_tls_self"
                echo -e "${GREEN}已选择: TLS+WebSocket自签证书${NC}"

                echo ""
                read -p "请输入WebSocket Host [默认: $DEFAULT_SNI_DOMAIN]: " WS_HOST
                if [ -z "$WS_HOST" ]; then
                    WS_HOST="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}WebSocket Host设置为: $WS_HOST${NC}"

                echo ""
                read -p "请输入TLS服务器名称 (SNI) [默认$DEFAULT_SNI_DOMAIN]: " TLS_SERVER_NAME
                if [ -z "$TLS_SERVER_NAME" ]; then
                    TLS_SERVER_NAME="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}TLS服务器名称设置为: $TLS_SERVER_NAME${NC}"

                read -p "请输入WebSocket路径 [默认: /ws]: " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/ws"
                fi
                echo -e "${GREEN}WebSocket路径设置为: $WS_PATH${NC}"
                break
                ;;
            6)
                SECURITY_LEVEL="ws_tls_ca"
                echo -e "${GREEN}已选择: TLS+WebSocket CA证书${NC}"

                echo ""
                read -p "请输入WebSocket Host [默认: $DEFAULT_SNI_DOMAIN]: " WS_HOST
                if [ -z "$WS_HOST" ]; then
                    WS_HOST="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}WebSocket Host设置为: $WS_HOST${NC}"

                echo ""
                read -p "请输入TLS服务器名称 (SNI) [默认$DEFAULT_SNI_DOMAIN]: " TLS_SERVER_NAME
                if [ -z "$TLS_SERVER_NAME" ]; then
                    TLS_SERVER_NAME="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}TLS服务器名称设置为: $TLS_SERVER_NAME${NC}"

                read -p "请输入WebSocket路径 [默认: /ws]: " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/ws"
                fi
                echo -e "${GREEN}TLS+WebSocket配置完成${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 1-6${NC}"
                ;;
        esac
    done

    fi

    echo ""
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"

    if [ -n "$RULE_NOTE" ]; then
        read -r -p "请输入新的备注(回车使用现有备注$RULE_NOTE): " new_note
        new_note=$(echo "$new_note" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-50)
        if [ -n "$new_note" ]; then
            RULE_NOTE="$new_note"
            echo -e "${GREEN}备注设置为: $RULE_NOTE${NC}"
        else
            echo -e "${GREEN}使用现有备注: $RULE_NOTE${NC}"
        fi
    else
        read -r -p "请输入当前规则备注(可选，直接回车跳过): " RULE_NOTE
        RULE_NOTE=$(echo "$RULE_NOTE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-50)
        if [ -n "$RULE_NOTE" ]; then
            echo -e "${GREEN}备注设置为: $RULE_NOTE${NC}"
        else
            echo -e "${BLUE}未设置备注${NC}"
        fi
    fi

    echo ""
}

configure_exit_server() {
    echo -e "${YELLOW}=== 解密并转发服务器配置 (双端Realm架构) ===${NC}"
    echo ""

    echo "正在获取本机公网IP..."
    local ipv4=$(get_public_ip "ipv4")
    local ipv6=$(get_public_ip "ipv6")

    if [ -n "$ipv4" ]; then
        echo -e "${GREEN}本机IPv4地址: $ipv4${NC}"
    fi
    if [ -n "$ipv6" ]; then
        echo -e "${GREEN}本机IPv6地址: $ipv6${NC}"
    fi

    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        echo -e "${YELLOW}无法自动获取公网IP，请手动确认${NC}"
    fi
    echo ""

    echo -e "${BLUE}多端口使用,逗号分隔${NC}"
    while true; do
        read -p "请输入监听端口 (等待中转服务器连接的端口，NAT VPS需使用商家分配的端口): " EXIT_LISTEN_PORT
        if validate_ports "$EXIT_LISTEN_PORT"; then
            echo -e "${GREEN}监听端口设置为: $EXIT_LISTEN_PORT${NC}"
            break
        else
            echo -e "${RED}无效端口号，请输入 1-65535 之间的数字，多端口用逗号分隔${NC}"
        fi
    done

    local is_multi_port=false

    if [[ "$EXIT_LISTEN_PORT" == *","* ]]; then
        is_multi_port=true
        echo -e "${BLUE}检测到多端口配置，跳过端口占用检测${NC}"
    else

        check_port_usage "$EXIT_LISTEN_PORT" "出口服务器监听"
    fi

    echo ""

    echo "内循环本地转发目标或者远端服务器业务:"
    echo ""
    echo -e "${YELLOW}本地业务输入: IPv4: 127.0.0.1 | IPv6: ::1 | 双栈: localhost${NC}"
    echo -e "${YELLOW}远端业务输入:对应服务器IP ${NC}"
    echo ""

    while true; do
        read -p "转发目标IP地址(默认:127.0.0.1): " input_target
        if [ -z "$input_target" ]; then
            input_target="127.0.0.1"
        fi

        if validate_target_address "$input_target"; then
            FORWARD_TARGET="$input_target"
            echo -e "${GREEN}转发目标设置为: $FORWARD_TARGET${NC}"
            break
        else
            echo -e "${RED}无效地址格式${NC}"
            echo -e "${YELLOW}支持格式: IP地址、域名、或多个地址用逗号分隔${NC}"
            echo -e "${YELLOW}示例: 127.0.0.1,::1 或 localhost 或 192.168.1.100${NC}"
        fi
    done

    local forward_port
    while true; do
        read -p "转发目标业务端口(多端口使用,逗号分隔): " forward_port
        if validate_ports "$forward_port"; then
            echo -e "${GREEN}转发端口设置为: $forward_port${NC}"
            break
        else
            echo -e "${RED}无效端口号，请输入 1-65535 之间的数字，多端口用逗号分隔${NC}"
        fi
    done

    FORWARD_TARGET="$FORWARD_TARGET:$forward_port"

    local connectivity_ok=true

    if [[ "$forward_port" == *","* ]]; then
        echo -e "${BLUE}多端口配置，跳过转发目标连通性测试${NC}"
    else
        echo -e "${YELLOW}正在测试转发目标连通性...${NC}"

        local addresses_part="${FORWARD_TARGET%:*}"
        local target_port="${FORWARD_TARGET##*:}"
        IFS=',' read -ra TARGET_ADDRESSES <<< "$addresses_part"
        for addr in "${TARGET_ADDRESSES[@]}"; do
            addr=$(echo "$addr" | xargs)  # 去除空格
            echo -e "${BLUE}测试连接: $addr:$target_port${NC}"
            if check_connectivity "$addr" "$target_port"; then
                echo -e "${GREEN}✓ $addr:$target_port 连接成功${NC}"
            else
                echo -e "${RED}✗ $addr:$target_port 连接失败${NC}"
                connectivity_ok=false
            fi
        done
    fi

    if ! $connectivity_ok && [[ "$forward_port" != *","* ]]; then
        echo -e "${RED}部分或全部转发目标连接测试失败，请确认代理服务是否正常运行${NC}"

        local has_domain=false
        local addresses_part="${FORWARD_TARGET%:*}"
        IFS=',' read -ra TARGET_ADDRESSES <<< "$addresses_part"
        for addr in "${TARGET_ADDRESSES[@]}"; do
            addr=$(echo "$addr" | xargs)
            if ! validate_ip "$addr" && [[ "$addr" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                has_domain=true
                break
            fi
        done

        if $has_domain; then
            echo -e "${YELLOW}检测到您使用的是域名地址，如果是DDNS域名：${NC}"
            echo -e "${YELLOW}确认域名和端口正确，可以直接继续配置无需担心${NC}"
            echo -e "${YELLOW}DDNS域名无法进行连通性测试${NC}"
        fi

        read -p "是否继续配置？(y/n): " continue_config
        if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
            echo "配置已取消"
            exit 1
        fi
    else
        echo -e "${GREEN}✓ 所有转发目标连接测试成功！${NC}"
    fi

    echo ""
    echo -e "${YELLOW}=== 转发协议配置 ===${NC}"
    echo "请选择转发协议:"
    echo -e "${GREEN}[1]${NC} TCP+UDP 双栈（默认）"
    echo -e "${GREEN}[2]${NC} 仅 TCP"
    echo -e "${GREEN}[3]${NC} 仅 UDP"
    echo ""
    while true; do
        read -p "请输入选择(回车默认1) [1-3]: " proto_choice
        [ -z "$proto_choice" ] && proto_choice="1"
        case "$proto_choice" in
            1) PROTOCOL="both" ; echo -e "${GREEN}已选择: TCP+UDP 双栈${NC}"; break ;;
            2) PROTOCOL="tcp"  ; echo -e "${GREEN}已选择: 仅 TCP${NC}"; break ;;
            3) PROTOCOL="udp"  ; echo -e "${GREEN}已选择: 仅 UDP${NC}"; break ;;
            *) echo -e "${RED}无效选择，请输入 1-3${NC}" ;;
        esac
    done

    # 纯 UDP 无 TCP 连接，ws/tls 加密传输挂在 TCP 上对纯 UDP 无效，直接默认传输
    if [ "$PROTOCOL" = "udp" ]; then
        SECURITY_LEVEL="standard"
        echo -e "${BLUE}纯 UDP 无需传输加密，使用默认传输${NC}"
    else

    echo ""
    echo "请选择传输模式:"
    echo -e "${GREEN}[1]${NC} 默认传输 (不加密，理论最快)"
    echo -e "${GREEN}[2]${NC} WebSocket (ws)"
    echo -e "${GREEN}[3]${NC} TLS (自签证书，自动生成)"
    echo -e "${GREEN}[4]${NC} TLS (CA签发证书)"
    echo -e "${GREEN}[5]${NC} TLS+WebSocket (自签证书)"
    echo -e "${GREEN}[6]${NC} TLS+WebSocket (CA证书)"
    echo ""

    while true; do
        read -p "请输入选择(回车默认1) [1-6]: " transport_choice
        if [ -z "$transport_choice" ]; then
            transport_choice="1"
        fi
        case $transport_choice in
            1)
                SECURITY_LEVEL="standard"
                echo -e "${GREEN}已选择: 默认传输${NC}"
                break
                ;;
            2)
                SECURITY_LEVEL="ws"
                echo -e "${GREEN}已选择: WebSocket${NC}"

                echo ""
                read -p "请输入WebSocket Host [默认: $DEFAULT_SNI_DOMAIN]: " WS_HOST
                if [ -z "$WS_HOST" ]; then
                    WS_HOST="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}WebSocket Host设置为: $WS_HOST${NC}"

                echo ""
                read -p "请输入WebSocket路径 [默认: /ws]: " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/ws"
                fi
                echo -e "${GREEN}WebSocket路径设置为: $WS_PATH${NC}"
                break
                ;;
            3)
                SECURITY_LEVEL="tls_self"
                echo -e "${GREEN}已选择: TLS自签证书${NC}"

                echo ""
                read -p "请输入TLS服务器名称 (servername/CN) [默认$DEFAULT_SNI_DOMAIN]: " TLS_SERVER_NAME
                if [ -z "$TLS_SERVER_NAME" ]; then
                    TLS_SERVER_NAME="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}TLS服务器名称设置为: $TLS_SERVER_NAME${NC}"
                break
                ;;
            4)
                SECURITY_LEVEL="tls_ca"
                echo -e "${GREEN}已选择: TLS CA证书${NC}"

                echo ""
                while true; do
                    read -p "请输入证书文件路径: " TLS_CERT_PATH
                    if [ -f "$TLS_CERT_PATH" ]; then
                        break
                    else
                        echo -e "${RED}证书文件不存在，请检查路径${NC}"
                    fi
                done

                while true; do
                    read -p "请输入私钥文件路径: " TLS_KEY_PATH
                    if [ -f "$TLS_KEY_PATH" ]; then
                        break
                    else
                        echo -e "${RED}私钥文件不存在，请检查路径${NC}"
                    fi
                done

                echo -e "${GREEN}TLS配置完成${NC}"
                break
                ;;
            5)
                SECURITY_LEVEL="ws_tls_self"
                echo -e "${GREEN}已选择: TLS+WebSocket自签证书${NC}"

                echo ""
                read -p "请输入WebSocket Host [默认: $DEFAULT_SNI_DOMAIN]: " WS_HOST
                if [ -z "$WS_HOST" ]; then
                    WS_HOST="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}WebSocket Host设置为: $WS_HOST${NC}"

                echo ""
                read -p "请输入TLS服务器名称 (servername/CN) [默认$DEFAULT_SNI_DOMAIN]: " TLS_SERVER_NAME
                if [ -z "$TLS_SERVER_NAME" ]; then
                    TLS_SERVER_NAME="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}TLS服务器名称设置为: $TLS_SERVER_NAME${NC}"

                read -p "请输入WebSocket路径 [默认: /ws]: " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/ws"
                fi
                echo -e "${GREEN}WebSocket路径设置为: $WS_PATH${NC}"
                break
                ;;
            6)
                SECURITY_LEVEL="ws_tls_ca"
                echo -e "${GREEN}已选择: TLS+WebSocket CA证书${NC}"

                echo ""
                read -p "请输入WebSocket Host [默认: $DEFAULT_SNI_DOMAIN]: " WS_HOST
                if [ -z "$WS_HOST" ]; then
                    WS_HOST="$DEFAULT_SNI_DOMAIN"
                fi
                echo -e "${GREEN}WebSocket Host设置为: $WS_HOST${NC}"

                echo ""
                while true; do
                    read -p "请输入证书文件路径: " TLS_CERT_PATH
                    if [ -f "$TLS_CERT_PATH" ]; then
                        break
                    else
                        echo -e "${RED}证书文件不存在，请检查路径${NC}"
                    fi
                done

                while true; do
                    read -p "请输入私钥文件路径: " TLS_KEY_PATH
                    if [ -f "$TLS_KEY_PATH" ]; then
                        break
                    else
                        echo -e "${RED}私钥文件不存在，请检查路径${NC}"
                    fi
                done

                read -p "请输入WebSocket路径 [默认: /ws]: " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/ws"
                fi
                echo -e "${GREEN}TLS+WebSocket配置完成${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 1-6${NC}"
                ;;
        esac
    done

    fi

    echo ""
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"

    read -r -p "请输入当前规则备注(可选，直接回车跳过): " RULE_NOTE
    RULE_NOTE=$(echo "$RULE_NOTE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-50)
    if [ -n "$RULE_NOTE" ]; then
        echo -e "${GREEN}备注设置为: $RULE_NOTE${NC}"
    else
        echo -e "${BLUE}未设置备注${NC}"
    fi

    echo ""
}
