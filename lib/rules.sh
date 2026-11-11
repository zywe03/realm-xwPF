

init_rules_dir() {
    mkdir -p "$RULES_DIR"
    if [ ! -f "${RULES_DIR}/.initialized" ]; then
        touch "${RULES_DIR}/.initialized"
        echo -e "${GREEN}✓ 规则目录已初始化: $RULES_DIR${NC}"
    fi
}

validate_rule_ids() {
    local rule_ids="$1"
    local valid_ids=()
    local invalid_ids=()

    local ids_array
    IFS=',' read -ra ids_array <<< "$rule_ids"

    for id in "${ids_array[@]}"; do
        id=$(echo "$id" | xargs)
        if [[ "$id" =~ ^[0-9]+$ ]]; then
            local rule_file="${RULES_DIR}/rule-${id}.conf"
            if [ -f "$rule_file" ]; then
                valid_ids+=("$id")
            else
                invalid_ids+=("$id")
            fi
        else
            invalid_ids+=("$id")
        fi
    done

    echo "${#valid_ids[@]}|${#invalid_ids[@]}|${valid_ids[*]}|${invalid_ids[*]}"
}

get_active_rules_count() {
    local count=0
    if [ -d "$RULES_DIR" ]; then
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file"; then
                    count=$((count + 1))
                fi
            fi
        done
    fi
    echo "$count"
}

# 规则重排序后同步更新健康监控记录，保持数据一致性
sync_health_status_ids() {
    local health_status_file="/etc/realm/health/health_status.conf"

    if [ ! -f "$health_status_file" ]; then
        return 0
    fi

    local temp_health_file="${health_status_file}.tmp"
    grep "^#" "$health_status_file" > "$temp_health_file" 2>/dev/null || true

    while IFS='|' read -r old_rule_id target status fail_count success_count last_check failure_start_time; do
        [[ "$old_rule_id" =~ ^#.*$ ]] && continue
        [[ -z "$old_rule_id" ]] && continue

        local new_rule_id=""
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ] && read_rule_file "$rule_file"; then
                if [ "$RULE_ROLE" = "1" ]; then
                    if [[ "$REMOTE_HOST" == *"$target"* ]] || [[ "$target" == "${REMOTE_HOST}:${REMOTE_PORT}" ]]; then
                        new_rule_id="$RULE_ID"
                        break
                    fi
                else
                    if [[ "$FORWARD_TARGET" == "$target" ]]; then
                        new_rule_id="$RULE_ID"
                        break
                    fi
                fi
            fi
        done

        if [ -n "$new_rule_id" ]; then
            echo "${new_rule_id}|${target}|${status}|${fail_count}|${success_count}|${last_check}|${failure_start_time}" >> "$temp_health_file"
        fi

    done < <(grep -v "^#" "$health_status_file" 2>/dev/null || true)

    if [ -f "$temp_health_file" ]; then
        mv "$temp_health_file" "$health_status_file"
    fi
}

# 按端口和角色排序规则ID，提升配置可读性和管理效率
reorder_rule_ids() {
    if [ ! -d "$RULES_DIR" ]; then
        return 0
    fi

    local rule_count=$(ls -1 "${RULES_DIR}"/rule-*.conf 2>/dev/null | wc -l)
    if [ "$rule_count" -eq 0 ]; then
        return 0
    fi

    local temp_file=$(mktemp)

    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file"; then
                echo "${LISTEN_PORT}|${RULE_ROLE}|${RULE_ID}|${rule_file}" >> "$temp_file"
            fi
        fi
    done

    local sorted_rules=($(sort -t'|' -k1,1n -k2,2n -k3,3n "$temp_file"))
    rm -f "$temp_file"

    if [ ${#sorted_rules[@]} -eq 0 ]; then
        return 0
    fi

    local temp_dir=$(mktemp -d)
    local new_id=1
    local reorder_needed=false

    for rule_data in "${sorted_rules[@]}"; do
        IFS='|' read -r port role old_id old_file <<< "$rule_data"
        if [ "$old_id" -ne "$new_id" ]; then
            reorder_needed=true
            break
        fi
        new_id=$((new_id + 1))
    done

    if [ "$reorder_needed" = false ]; then
        rmdir "$temp_dir"
        return 0
    fi

    new_id=1
    for rule_data in "${sorted_rules[@]}"; do
        IFS='|' read -r port role old_id old_file <<< "$rule_data"

        local temp_new_file="${temp_dir}/rule-${new_id}.conf"

        if cp "$old_file" "$temp_new_file"; then
            sed -i "s/^RULE_ID=.*/RULE_ID=$new_id/" "$temp_new_file"
        else
            echo -e "${RED}错误: 无法复制规则文件${NC}" >&2
            rm -rf "$temp_dir"
            return 1
        fi

        new_id=$((new_id + 1))
    done

    # 原子性操作：避免中间状态导致的配置不一致
    if rm -f "${RULES_DIR}"/rule-*.conf && mv "${temp_dir}"/rule-*.conf "${RULES_DIR}/"; then
        rmdir "$temp_dir"
        sync_health_status_ids
        return 0
    else
        echo -e "${RED}错误: 规则重排序失败${NC}" >&2
        rm -rf "$temp_dir"
        return 1
    fi
}

generate_rule_id() {
    local max_id=0
    if [ -d "$RULES_DIR" ]; then
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                local id=$(basename "$rule_file" | sed 's/rule-\([0-9]*\)\.conf/\1/')
                if [ "$id" -gt "$max_id" ]; then
                    max_id=$id
                fi
            fi
        done
    fi
    echo $((max_id + 1))
}

# 按 rule-N.conf 中 N 的数字序返回文件列表，避免 glob 字典序 (1,10,2)
get_sorted_rule_files() {
    ls "${RULES_DIR}"/rule-*.conf 2>/dev/null | sort -t- -k2 -n
}

read_rule_file() {
    local rule_file="$1"
    if [ -f "$rule_file" ]; then
        source "$rule_file"
        RULE_NOTE="${RULE_NOTE:-}"
        MPTCP_MODE="${MPTCP_MODE:-off}"
        PROXY_MODE="${PROXY_MODE:-off}"
        PROTOCOL="${PROTOCOL:-both}"
        return 0
    else
        return 1
    fi
}

get_balance_info_display() {
    local remote_host="$1"
    local balance_mode="$2"

    local balance_info=""
    case "$balance_mode" in
        "roundrobin")
            balance_info=" ${YELLOW}[轮询]${NC}"
            ;;
        "iphash")
            balance_info=" ${BLUE}[IP哈希]${NC}"
            ;;
        *)
            balance_info=" ${WHITE}[off]${NC}"
            ;;
    esac
    echo "$balance_info"
}

is_target_enabled() {
    local target_index="$1"
    local target_states="$2"
    local state_key="target_${target_index}"

    if [[ "$target_states" == *"$state_key:false"* ]]; then
        echo "false"
    else
        echo "true"
    fi
}

read_and_check_relay_rule() {
    local rule_file="$1"
    if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ]; then
        return 0
    else
        return 1
    fi
}

# 根据显示模式调整规则列表格式，支持管理、MPTCP、Proxy三种视图
list_rules_with_info() {
    local display_mode="${1:-management}"

    if [ ! -d "$RULES_DIR" ] || [ -z "$(ls -A "$RULES_DIR"/*.conf 2>/dev/null)" ]; then
        echo -e "${BLUE}暂无转发规则${NC}"
        return 1
    fi

    case "$display_mode" in
        "mptcp")
            echo -e "${BLUE}当前规则列表:${NC}"
            echo ""
            ;;
        "proxy")
            echo -e "${BLUE}当前规则列表:${NC}"
            echo ""
            ;;
        "management"|*)
            ;;
    esac

    local has_relay_rules=false
    local relay_count=0

    if [ "$display_mode" = "management" ]; then
        for rule_file in $(get_sorted_rule_files); do
            if [ -f "$rule_file" ]; then
                if read_and_check_relay_rule "$rule_file"; then
                    if [ "$has_relay_rules" = false ]; then
                        echo -e "${GREEN}中转服务器:${NC}"
                        has_relay_rules=true
                    fi
                    relay_count=$((relay_count + 1))
                    display_single_rule_info "$rule_file" "$display_mode"
                fi
            fi
        done
    fi

    local has_exit_rules=false
    local exit_count=0
    local has_rules=false

    for rule_file in $(get_sorted_rule_files); do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file"; then
                has_rules=true

                if [ "$display_mode" = "management" ]; then
                    if [ "$RULE_ROLE" = "2" ]; then
                        if [ "$has_exit_rules" = false ]; then
                            if [ "$has_relay_rules" = true ]; then
                                echo ""
                            fi
                            echo -e "${GREEN}服务端服务器 (双端Realm架构):${NC}"
                            has_exit_rules=true
                        fi
                        exit_count=$((exit_count + 1))
                        display_single_rule_info "$rule_file" "$display_mode"
                    fi
                else
                    display_single_rule_info "$rule_file" "$display_mode"
                fi
            fi
        fi
    done

    if [ "$display_mode" != "management" ] && [ "$has_rules" = false ]; then
        echo -e "${BLUE}暂无转发规则${NC}"
        return 1
    fi

    return 0
}

get_rule_status_display() {
    local security_display="$1"
    local note_display="$2"

    local mptcp_mode="${MPTCP_MODE:-off}"
    local mptcp_display=""
    if [ "$mptcp_mode" != "off" ]; then
        local mptcp_text=$(get_mptcp_mode_display "$mptcp_mode")
        local mptcp_color=$(get_mptcp_mode_color "$mptcp_mode")
        mptcp_display=" | MPTCP: ${mptcp_color}$mptcp_text${NC}"
    fi

    local proxy_mode="${PROXY_MODE:-off}"
    local proxy_display=""
    if [ "$proxy_mode" != "off" ]; then
        local proxy_text=$(get_proxy_mode_display "$proxy_mode")
        local proxy_color=$(get_proxy_mode_color "$proxy_mode")
        proxy_display=" | Proxy: ${proxy_color}$proxy_text${NC}"
    fi

    # 协议标签：both 是常态不显示，仅纯 TCP/纯 UDP 标注
    local protocol="${PROTOCOL:-both}"
    local protocol_display=""
    if [ "$protocol" = "tcp" ]; then
        protocol_display=" | 协议: ${BLUE}[纯TCP]${NC}"
    elif [ "$protocol" = "udp" ]; then
        protocol_display=" | 协议: ${YELLOW}[纯UDP]${NC}"
    fi

    echo -e "    安全: ${YELLOW}$security_display${NC}${mptcp_display}${proxy_display}${protocol_display}${note_display}"
}

display_single_rule_info() {
    local rule_file="$1"
    local display_mode="$2"

    if ! read_rule_file "$rule_file"; then
        return 1
    fi

    local status_color="${GREEN}"
    local status_text="启用"
    if [ "$ENABLED" != "true" ]; then
        status_color="${RED}"
        status_text="禁用"
    fi

    # 基础信息显示
    case "$display_mode" in
        "mptcp")
            local mptcp_mode="${MPTCP_MODE:-off}"
            local mptcp_display=$(get_mptcp_mode_display "$mptcp_mode")
            local mptcp_color=$(get_mptcp_mode_color "$mptcp_mode")
            echo -e "ID ${BLUE}$RULE_ID${NC}: $RULE_NAME | 状态: ${status_color}$status_text${NC} | MPTCP: ${mptcp_color}$mptcp_display${NC}"
            ;;
        "proxy")
            local proxy_mode="${PROXY_MODE:-off}"
            local proxy_display=$(get_proxy_mode_display "$proxy_mode")
            local proxy_color=$(get_proxy_mode_color "$proxy_mode")
            echo -e "ID ${BLUE}$RULE_ID${NC}: $RULE_NAME | 状态: ${status_color}$status_text${NC} | Proxy: ${proxy_color}$proxy_display${NC}"
            ;;
        "management"|*)
            if [ "$RULE_ROLE" = "2" ]; then
                local target_host="${FORWARD_TARGET%:*}"
                local target_port="${FORWARD_TARGET##*:}"
                local display_target=$(smart_display_target "$target_host")
                local rule_display_name="$RULE_NAME"
                echo -e "  ID ${BLUE}$RULE_ID${NC}: ${GREEN}$rule_display_name${NC} ($LISTEN_PORT → $display_target:$target_port) [${status_color}$status_text${NC}]"
            else
                local display_target=$(smart_display_target "$REMOTE_HOST")
                local rule_display_name="$RULE_NAME"
                local through_display="${THROUGH_IP:-::}"
                echo -e "  ID ${BLUE}$RULE_ID${NC}: ${GREEN}$rule_display_name${NC} ($LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT) [${status_color}$status_text${NC}]"
            fi
            return 0
            ;;
    esac

    if [ "$RULE_ROLE" = "2" ]; then
        local target_host="${FORWARD_TARGET%:*}"
        local target_port="${FORWARD_TARGET##*:}"
        local display_target=$(smart_display_target "$target_host")
        local display_ip="::"
        echo -e "  监听: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $display_target:$target_port"
    else
        local display_target=$(smart_display_target "$REMOTE_HOST")
        local display_ip="${NAT_LISTEN_IP:-::}"
        local through_display="${THROUGH_IP:-::}"
        echo -e "  监听: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT"
    fi
    echo ""
}

list_all_rules() {
    echo -e "${YELLOW}=== 所有转发规则 ===${NC}"
    echo ""

    if [ ! -d "$RULES_DIR" ] || [ -z "$(ls -A "$RULES_DIR"/*.conf 2>/dev/null)" ]; then
        echo -e "${BLUE}暂无转发规则${NC}"
        return 0
    fi

    local count=0
    for rule_file in $(get_sorted_rule_files); do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file"; then
                count=$((count + 1))
                local status_color="${GREEN}"
                local status_text="启用"
                if [ "$ENABLED" != "true" ]; then
                    status_color="${RED}"
                    status_text="禁用"
                fi

                echo -e "ID ${BLUE}$RULE_ID${NC}: $RULE_NAME"
                local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                local note_display=""
                if [ -n "$RULE_NOTE" ]; then
                    note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                fi
                echo -e "  通用配置: ${YELLOW}$security_display${NC}${note_display} | 状态: ${status_color}$status_text${NC}"

                if [ "$RULE_ROLE" = "2" ]; then
                    local display_ip="::"
                    echo -e "  监听: ${GREEN}${LISTEN_IP:-$display_ip}:$LISTEN_PORT${NC} → 转发: ${GREEN}$FORWARD_TARGET${NC}"
                else
                    local display_ip="${NAT_LISTEN_IP:-::}"
                    local through_display="${THROUGH_IP:-::}"
                    echo -e "  中转: ${GREEN}${LISTEN_IP:-$display_ip}:$LISTEN_PORT${NC} → ${GREEN}$through_display${NC} → ${GREEN}$REMOTE_HOST:$REMOTE_PORT${NC}"
                fi
                echo -e "  创建时间: $CREATED_TIME"
                echo ""
            fi
        fi
    done

    echo -e "${BLUE}共找到 $count 个配置${NC}"
}

# 编辑现有规则
edit_rule_interactive() {
    echo -e "${YELLOW}=== 编辑配置 ===${NC}"
    echo ""
    
    if ! list_rules_with_info "management"; then
        read -p "按回车键返回..."
        return 1
    fi
    
    echo ""
    read -p "请输入要编辑的规则ID: " rule_id
    
    if [ -z "$rule_id" ]; then
        echo -e "${RED}未输入规则ID${NC}"
        read -p "按回车键返回..."
        return 1
    fi
    
    if ! [[ "$rule_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的规则ID${NC}"
        read -p "按回车键返回..."
        return 1
    fi
    
    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"
    if [ ! -f "$rule_file" ]; then
        echo -e "${RED}规则 $rule_id 不存在${NC}"
        read -p "按回车键返回..."
        return 1
    fi
    
    if ! read_rule_file "$rule_file"; then
        echo -e "${RED}无法读取规则文件${NC}"
        read -p "按回车键返回..."
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}正在编辑规则: $RULE_NAME (ID: $rule_id)${NC}"
    echo ""
    
    if [ "$RULE_ROLE" = "1" ]; then
        edit_nat_server_config "$rule_file"
    elif [ "$RULE_ROLE" = "2" ]; then
        edit_exit_server_config "$rule_file"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}正在重启服务以应用配置更改...${NC}"
        service_restart
    fi
    
    read -p "按回车键返回..."
}

# 从TARGET_STATES移除指定目标，保持目标与权重的索引对应关系
# 格式: "new_target_states|new_weights"
remove_target_from_states() {
    local original_states="$1"
    local target_to_remove="$2"
    local original_weights="$3"

    local new_target_states=""
    local new_weights=""

    IFS=',' read -ra targets <<< "$original_states"
    IFS=',' read -ra weight_array <<< "$original_weights"

    for i in "${!targets[@]}"; do
        if [ "${targets[i]}" != "$target_to_remove" ]; then
            local weight="${weight_array[i]:-1}"

            if [ -z "$new_target_states" ]; then
                new_target_states="${targets[i]}"
                new_weights="$weight"
            else
                new_target_states="$new_target_states,${targets[i]}"
                new_weights="$new_weights,$weight"
            fi
        fi
    done

    echo "$new_target_states|$new_weights"
}

# 同步更新同端口负载均衡组的所有规则
sync_target_states_for_port() {
    local port="$1"
    local new_target_states="$2"
    local new_weights="$3"
    local rf

    local updated_count=0

    for rf in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rf" ]; then
            if read_rule_file "$rf" && [ "$LISTEN_PORT" = "$port" ] && [ "$BALANCE_MODE" != "off" ]; then
                sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"$new_target_states\"|" "$rf"
                sed -i "s|^WEIGHTS=.*|WEIGHTS=\"$new_weights\"|" "$rf"
                updated_count=$((updated_count + 1))
            fi
        fi
    done

    return $updated_count
}

# 降级单规则模式
disable_balance_for_port() {
    local port="$1"
    local rf

    for rf in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rf" ]; then
            if read_rule_file "$rf" && [ "$LISTEN_PORT" = "$port" ]; then
                sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"off\"/" "$rf"
                sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"\"|" "$rf"
                sed -i "s|^WEIGHTS=.*|WEIGHTS=\"\"|" "$rf"
            fi
        fi
    done
}

# 保存本次 TLS 编辑字段；转义 source 和 sed 的特殊字符，兼容缺少字段的旧规则。
save_tls_rule_field() {
    local rule_file="$1" field="$2" value="$3" assignment
    printf -v assignment '%s=%q' "$field" "$value"
    assignment=$(printf '%s' "$assignment" | sed 's/[\\&|]/\\&/g') || return 1
    if grep -q "^${field}=" "$rule_file"; then
        sed -i "s|^${field}=.*|${assignment}|" "$rule_file"
    else
        printf '\n%s=%q\n' "$field" "$value" >> "$rule_file"
    fi
}

# 编辑中转服务器配置
edit_nat_server_config() {
    local rule_file="$1"
    local TLS_SERVER_NAME=""
    read_rule_file "$rule_file"
    
    echo -e "${YELLOW}=== 编辑中转服务器配置 ===${NC}"
    echo ""
    
    local new_listen_port
    while true; do
        echo -ne "请输入本地监听端口 (客户端连接的端口，回车默认${GREEN}${LISTEN_PORT}${NC}): "
        read new_listen_port
        if [ -z "$new_listen_port" ]; then
            new_listen_port="$LISTEN_PORT"
            break
        fi
        if validate_port "$new_listen_port"; then
            break
        else
            echo -e "${RED}无效端口号${NC}"
        fi
    done
    
    local new_listen_ip
    echo -ne "自定义(指定)入口监听IP/网卡接口(客户端连接IP/网卡,回车默认${GREEN}${LISTEN_IP:-::}${NC}): "
    read new_listen_ip
    if [ -z "$new_listen_ip" ]; then
        new_listen_ip="${LISTEN_IP:-::}"
    elif ! validate_ip "$new_listen_ip" && ! [[ "$new_listen_ip" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo -e "${RED}无效IP地址或网卡名称，保持原值${NC}"
        new_listen_ip="${LISTEN_IP:-::}"
    fi
    
    local new_through_ip
    echo -ne "自定义(指定)出口IP/网卡接口(适用于多IP/网卡出口情况,回车默认${GREEN}${THROUGH_IP:-::}${NC}): "
    read new_through_ip
    if [ -z "$new_through_ip" ]; then
        new_through_ip="${THROUGH_IP:-::}"
    elif ! validate_ip "$new_through_ip" && ! [[ "$new_through_ip" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo -e "${RED}无效IP地址或网卡名称，保持原值${NC}"
        new_through_ip="${THROUGH_IP:-::}"
    fi
    
    echo ""
    echo -e "${YELLOW}=== 编辑出口服务器信息配置 ===${NC}"
    
    local new_remote_host
    echo -ne "出口服务器的IP地址或域名(回车默认${GREEN}${REMOTE_HOST}${NC}): "
    read new_remote_host
    if [ -z "$new_remote_host" ]; then
        new_remote_host="$REMOTE_HOST"
    elif ! validate_single_address "$new_remote_host"; then
        echo -e "${RED}无效地址，保持原值${NC}"
        new_remote_host="$REMOTE_HOST"
    fi
    
    local new_remote_port
    while true; do
        echo -ne "出口服务器的监听端口(回车默认${GREEN}${REMOTE_PORT}${NC}): "
        read new_remote_port
        if [ -z "$new_remote_port" ]; then
            new_remote_port="$REMOTE_PORT"
            break
        fi
        if validate_port "$new_remote_port"; then
            break
        else
            echo -e "${RED}无效端口号${NC}"
        fi
    done
    
    # 保存原始值用于后续比较
    local old_remote_host="$REMOTE_HOST"
    local old_remote_port="$REMOTE_PORT"
    local old_listen_port="$LISTEN_PORT"
    local is_balance_mode=false

    if [ "$BALANCE_MODE" != "off" ] && [ -n "$TARGET_STATES" ]; then
        is_balance_mode=true
    fi

    # 更新基本字段
    sed -i "s/^LISTEN_PORT=.*/LISTEN_PORT=\"$new_listen_port\"/" "$rule_file"
    sed -i "s|^LISTEN_IP=.*|LISTEN_IP=\"$new_listen_ip\"|" "$rule_file"
    sed -i "s|^THROUGH_IP=.*|THROUGH_IP=\"$new_through_ip\"|" "$rule_file"
    sed -i "s/^REMOTE_HOST=.*/REMOTE_HOST=\"$new_remote_host\"/" "$rule_file"
    sed -i "s/^REMOTE_PORT=.*/REMOTE_PORT=\"$new_remote_port\"/" "$rule_file"

    # 转发协议编辑：both 双栈是常态，纯 TCP/纯 UDP 才需要标注
    local current_protocol="${PROTOCOL:-both}"
    echo ""
    echo -e "${YELLOW}=== 转发协议配置 ===${NC}"
    echo "请选择转发协议:"
    echo -e "${GREEN}[1]${NC} TCP+UDP 双栈"
    echo -e "${GREEN}[2]${NC} 仅 TCP"
    echo -e "${GREEN}[3]${NC} 仅 UDP"
    local proto_default="1"
    case "$current_protocol" in
        tcp) proto_default="2" ;;
        udp) proto_default="3" ;;
    esac
    local new_protocol
    while true; do
        read -p "请输入选择(回车默认${GREEN}${proto_default}${NC}) [1-3]: " proto_choice
        [ -z "$proto_choice" ] && proto_choice="$proto_default"
        case "$proto_choice" in
            1) new_protocol="both"  ; echo -e "${GREEN}已选择: TCP+UDP 双栈${NC}"; break ;;
            2) new_protocol="tcp"   ; echo -e "${GREEN}已选择: 仅 TCP${NC}"; break ;;
            3) new_protocol="udp"   ; echo -e "${GREEN}已选择: 仅 UDP${NC}"; break ;;
            *) echo -e "${RED}无效选择，请输入 1-3${NC}" ;;
        esac
    done

    # 纯 UDP 无 TCP 连接，ws/tls 等加密传输挂在 TCP 上对纯 UDP 无效，强制降级为 standard
    if [ "$new_protocol" = "udp" ] && [ "$SECURITY_LEVEL" != "standard" ]; then
        echo -e "${YELLOW}纯 UDP 不支持 ws/tls 加密传输，已自动切换为默认传输${NC}"
        SECURITY_LEVEL="standard"
        sed -i "s/^SECURITY_LEVEL=.*/SECURITY_LEVEL=\"standard\"/" "$rule_file"
        sed -i "s|^TLS_SERVER_NAME=.*|TLS_SERVER_NAME=\"\"|" "$rule_file"
        sed -i "s|^WS_PATH=.*|WS_PATH=\"\"|" "$rule_file"
        sed -i "s|^WS_HOST=.*|WS_HOST=\"\"|" "$rule_file"
    fi

    if grep -q "^PROTOCOL=" "$rule_file"; then
        sed -i "s/^PROTOCOL=.*/PROTOCOL=\"$new_protocol\"/" "$rule_file"
    else
        echo "PROTOCOL=\"$new_protocol\"" >> "$rule_file"
    fi

    if [ "$SECURITY_LEVEL" = "tls_ca" ] || [ "$SECURITY_LEVEL" = "ws_tls_ca" ]; then
        echo ""
        echo "同端口多规则仍使用首条启用规则的 TLS 配置，本次只编辑当前规则。"
        local new_tls_server_name
        while true; do
            printf 'TLS服务器名称 (SNI，回车保留 %s): ' "${TLS_SERVER_NAME:-$DEFAULT_SNI_DOMAIN}"
            IFS= read -r new_tls_server_name || break
            [ -n "$new_tls_server_name" ] || break
            if validate_single_address "$new_tls_server_name"; then
                save_tls_rule_field "$rule_file" TLS_SERVER_NAME "$new_tls_server_name" || return 1
                break
            fi
            echo -e "${RED}无效的TLS服务器名称，请输入域名或IP，不含端口及传输参数${NC}"
        done
    fi

    # 规则备注编辑
    local current_note="${RULE_NOTE:-}"
    echo -ne "规则备注(回车默认${GREEN}${current_note}${NC}): "
    read new_note
    new_note=$(echo "$new_note" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-50)
    if [ -z "$new_note" ]; then
        new_note="$current_note"
    fi

    # 更新或添加 RULE_NOTE 字段
    if grep -q "^RULE_NOTE=" "$rule_file"; then
        sed -i "s|^RULE_NOTE=.*|RULE_NOTE=\"$new_note\"|" "$rule_file"
    else
        echo "RULE_NOTE=\"$new_note\"" >> "$rule_file"
    fi

    # 如果是负载均衡模式，需要处理TARGET_STATES同步
    if [ "$is_balance_mode" = true ]; then

        local old_target="${old_remote_host}:${old_remote_port}"
        local new_target="${new_remote_host}:${new_remote_port}"
        local port_changed=false
        local target_changed=false

        if [ "$old_listen_port" != "$new_listen_port" ]; then
            port_changed=true
        fi

        if [ "$old_target" != "$new_target" ]; then
            target_changed=true
        fi

        # 端口变更,规则离开原负载均衡组
        if [ "$port_changed" = true ]; then
            echo ""
            echo -e "${BLUE}检测到端口变更，正在处理负载均衡配置...${NC}"

            local result=$(remove_target_from_states "$TARGET_STATES" "$old_target" "$WEIGHTS")
            local new_target_states_for_old_port="${result%|*}"
            local new_weights_for_old_port="${result#*|}"

            local remaining_count=0
            if [ -n "$new_target_states_for_old_port" ]; then
                remaining_count=$(echo "$new_target_states_for_old_port" | tr ',' '\n' | grep -c .)
            fi

            if [ $remaining_count -le 1 ]; then
                echo -e "${YELLOW}旧端口组只剩1个目标，自动关闭负载均衡模式${NC}"
                disable_balance_for_port "$old_listen_port"
            else
                sync_target_states_for_port "$old_listen_port" "$new_target_states_for_old_port" "$new_weights_for_old_port"
                local sync_count=$?
                if [ $sync_count -gt 0 ]; then
                    echo -e "${GREEN}✓ 已更新旧端口组 $old_listen_port 的 $sync_count 个规则${NC}"
                fi
            fi

            # 规则变为独立规则，清空负载均衡配置
            sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"off\"/" "$rule_file"
            sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"\"|" "$rule_file"
            sed -i "s|^WEIGHTS=.*|WEIGHTS=\"\"|" "$rule_file"
            echo -e "${GREEN}✓ 当前规则已设为独立规则（端口 $new_listen_port）${NC}"

        # 目标变更 - 同步更新负载均衡组
        elif [ "$target_changed" = true ]; then
            echo ""
            echo -e "${BLUE}检测到负载均衡规则，正在同步更新相同端口的所有规则...${NC}"

            local new_target_states="${TARGET_STATES//$old_target/$new_target}"

            sync_target_states_for_port "$old_listen_port" "$new_target_states" "$WEIGHTS"
            local sync_count=$?

            if [ $sync_count -gt 0 ]; then
                echo -e "${GREEN}✓ 已同步更新 $sync_count 个相同端口的规则${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ 配置已更新${NC}"
    return 0
}

# 编辑服务端服务器配置
edit_exit_server_config() {
    local rule_file="$1"
    local TLS_CERT_PATH="" TLS_KEY_PATH=""
    read_rule_file "$rule_file"
    
    echo -e "${YELLOW}=== 编辑解密并转发服务器配置 (双端Realm架构) ===${NC}"
    echo ""
    
    local new_listen_port
    while true; do
        echo -ne "请输入监听端口 (回车默认${GREEN}${LISTEN_PORT}${NC}): "
        read new_listen_port
        if [ -z "$new_listen_port" ]; then
            new_listen_port="$LISTEN_PORT"
            break
        fi
        if validate_port "$new_listen_port"; then
            break
        else
            echo -e "${RED}无效端口号${NC}"
        fi
    done
    
    local current_target_host="${FORWARD_TARGET%:*}"
    local current_target_port="${FORWARD_TARGET##*:}"
    
    local new_target_host
    echo -ne "转发目标IP地址(回车默认${GREEN}${current_target_host}${NC}): "
    read new_target_host
    if [ -z "$new_target_host" ]; then
        new_target_host="$current_target_host"
    elif ! validate_target_address "$new_target_host"; then
        echo -e "${RED}无效地址，保持原值${NC}"
        new_target_host="$current_target_host"
    fi
    
    local new_target_port
    while true; do
        echo -ne "转发目标业务端口(回车默认${GREEN}${current_target_port}${NC}): "
        read new_target_port
        if [ -z "$new_target_port" ]; then
            new_target_port="$current_target_port"
            break
        fi
        if validate_port "$new_target_port"; then
            break
        else
            echo -e "${RED}无效端口号${NC}"
        fi
    done
    
    # 规则备注编辑
    local current_note="${RULE_NOTE:-}"
    echo -ne "规则备注(回车默认${GREEN}${current_note}${NC}): "
    read new_note
    new_note=$(echo "$new_note" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-50)
    if [ -z "$new_note" ]; then
        new_note="$current_note"
    fi
    
    sed -i "s/^LISTEN_PORT=.*/LISTEN_PORT=\"$new_listen_port\"/" "$rule_file"
    sed -i "s|^FORWARD_TARGET=.*|FORWARD_TARGET=\"${new_target_host}:${new_target_port}\"|" "$rule_file"

    # 转发协议编辑：both 双栈是常态，纯 TCP/纯 UDP 才需要标注
    local current_protocol="${PROTOCOL:-both}"
    echo ""
    echo -e "${YELLOW}=== 转发协议配置 ===${NC}"
    echo "请选择转发协议:"
    echo -e "${GREEN}[1]${NC} TCP+UDP 双栈"
    echo -e "${GREEN}[2]${NC} 仅 TCP"
    echo -e "${GREEN}[3]${NC} 仅 UDP"
    local proto_default="1"
    case "$current_protocol" in
        tcp) proto_default="2" ;;
        udp) proto_default="3" ;;
    esac
    local new_protocol
    while true; do
        read -p "请输入选择(回车默认${GREEN}${proto_default}${NC}) [1-3]: " proto_choice
        [ -z "$proto_choice" ] && proto_choice="$proto_default"
        case "$proto_choice" in
            1) new_protocol="both"  ; echo -e "${GREEN}已选择: TCP+UDP 双栈${NC}"; break ;;
            2) new_protocol="tcp"   ; echo -e "${GREEN}已选择: 仅 TCP${NC}"; break ;;
            3) new_protocol="udp"   ; echo -e "${GREEN}已选择: 仅 UDP${NC}"; break ;;
            *) echo -e "${RED}无效选择，请输入 1-3${NC}" ;;
        esac
    done

    # 纯 UDP 无 TCP 连接，ws/tls 等加密传输挂在 TCP 上对纯 UDP 无效，强制降级为 standard
    if [ "$new_protocol" = "udp" ] && [ "$SECURITY_LEVEL" != "standard" ]; then
        echo -e "${YELLOW}纯 UDP 不支持 ws/tls 加密传输，已自动切换为默认传输${NC}"
        SECURITY_LEVEL="standard"
        sed -i "s/^SECURITY_LEVEL=.*/SECURITY_LEVEL=\"standard\"/" "$rule_file"
        sed -i "s|^TLS_SERVER_NAME=.*|TLS_SERVER_NAME=\"\"|" "$rule_file"
        sed -i "s|^TLS_CERT_PATH=.*|TLS_CERT_PATH=\"\"|" "$rule_file"
        sed -i "s|^TLS_KEY_PATH=.*|TLS_KEY_PATH=\"\"|" "$rule_file"
        sed -i "s|^WS_PATH=.*|WS_PATH=\"\"|" "$rule_file"
        sed -i "s|^WS_HOST=.*|WS_HOST=\"\"|" "$rule_file"
    fi

    if grep -q "^PROTOCOL=" "$rule_file"; then
        sed -i "s/^PROTOCOL=.*/PROTOCOL=\"$new_protocol\"/" "$rule_file"
    else
        echo "PROTOCOL=\"$new_protocol\"" >> "$rule_file"
    fi

    if [ "$SECURITY_LEVEL" = "tls_ca" ] || [ "$SECURITY_LEVEL" = "ws_tls_ca" ]; then
        echo ""
        echo "同端口多规则仍使用首条启用规则的 TLS 配置，本次只编辑当前规则。"
        local new_tls_cert_path="${TLS_CERT_PATH:-}" new_tls_key_path="${TLS_KEY_PATH:-}"
        local tls_field tls_label tls_path tls_input_complete=true
        for tls_field in new_tls_cert_path new_tls_key_path; do
            if [ "$tls_field" = "new_tls_cert_path" ]; then
                tls_label="证书文件路径"
            else
                tls_label="私钥文件路径"
            fi
            while true; do
                printf '%s (回车保留 %s): ' "$tls_label" "${!tls_field}"
                if ! IFS= read -r tls_path; then
                    tls_input_complete=false
                    break 2
                fi
                [ -n "$tls_path" ] || break
                # 保持现有 transport 生成逻辑，仅接受其能原样表达的新路径。
                case "$tls_path" in
                    *[[:space:][:cntrl:]]*|*';'*|*'|'*|*'"'*|*'\'*|*'*'*|*'?'*|*'['*)
                        echo -e "${RED}路径不能包含空白、控制字符、分号、竖线、双引号、反斜线或通配符${NC}"
                        continue
                        ;;
                esac
                if [ -f "$tls_path" ]; then
                    printf -v "$tls_field" '%s' "$tls_path"
                    break
                fi
                echo -e "${RED}文件不存在，请检查路径${NC}"
            done
        done
        if [ "$tls_input_complete" = true ]; then
            if [ "$new_tls_cert_path" != "${TLS_CERT_PATH:-}" ]; then
                save_tls_rule_field "$rule_file" TLS_CERT_PATH "$new_tls_cert_path" || return 1
            fi
            if [ "$new_tls_key_path" != "${TLS_KEY_PATH:-}" ]; then
                save_tls_rule_field "$rule_file" TLS_KEY_PATH "$new_tls_key_path" || return 1
            fi
        fi
    fi

    # 更新或添加 RULE_NOTE 字段
    if grep -q "^RULE_NOTE=" "$rule_file"; then
        sed -i "s|^RULE_NOTE=.*|RULE_NOTE=\"$new_note\"|" "$rule_file"
    else
        echo "RULE_NOTE=\"$new_note\"" >> "$rule_file"
    fi
    
    echo ""
    echo -e "${GREEN}✓ 配置已更新${NC}"
    return 0
}

interactive_add_rule() {
    echo -e "${YELLOW}=== 添加新转发配置 ===${NC}"
    echo ""

    echo "请选择新配置的角色:"
    echo -e "${GREEN}[1]${NC} 中转服务器"
    echo -e "${GREEN}[2]${NC} 服务端服务器 (解密并转发)"
    echo "解密并转发用于一方发送一方接收的场景如：隧道,MPTCP，Proxy Protocol等"
    echo ""
    local RULE_ROLE
    while true; do
        read -p "请输入数字 [1-2]: " RULE_ROLE
        case $RULE_ROLE in
            1)
                echo -e "${GREEN}已选择: 中转服务器${NC}"
                break
                ;;
            2)
                echo -e "${GREEN}已选择: 服务端服务器 (解密并转发)${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 1-2${NC}"
                ;;
        esac
    done
    echo ""

    # 保护全局变量不被污染，确保多次配置操作的独立性
    local ORIG_ROLE="$ROLE"
    local ORIG_NAT_LISTEN_PORT="$NAT_LISTEN_PORT"
    local ORIG_REMOTE_IP="$REMOTE_IP"
    local ORIG_REMOTE_PORT="$REMOTE_PORT"
    local ORIG_EXIT_LISTEN_PORT="$EXIT_LISTEN_PORT"
    local ORIG_FORWARD_TARGET="$FORWARD_TARGET"
    local ORIG_SECURITY_LEVEL="$SECURITY_LEVEL"
    local ORIG_TLS_SERVER_NAME="$TLS_SERVER_NAME"
    local ORIG_TLS_CERT_PATH="$TLS_CERT_PATH"
    local ORIG_TLS_KEY_PATH="$TLS_KEY_PATH"
    local ORIG_PROTOCOL="$PROTOCOL"

    ROLE="$RULE_ROLE"

    if [ "$RULE_ROLE" -eq 1 ]; then
        configure_nat_server
        if [ $? -ne 0 ]; then
            echo "配置已取消"
            return 1
        fi
    elif [ "$RULE_ROLE" -eq 2 ]; then
        configure_exit_server
        if [ $? -ne 0 ]; then
            echo "配置已取消"
            return 1
        fi
    fi

    echo -e "${YELLOW}正在创建转发配置...${NC}"
    init_rules_dir

    if [ "$RULE_ROLE" -eq 1 ]; then
        create_nat_rules_for_ports "$NAT_LISTEN_PORT" "$REMOTE_PORT"
    elif [ "$RULE_ROLE" -eq 2 ]; then
        local forward_port="${FORWARD_TARGET##*:}"
        local forward_address="${FORWARD_TARGET%:*}"

        local temp_forward_target="$FORWARD_TARGET"
        FORWARD_TARGET="$forward_address"

        create_exit_rules_for_ports "$EXIT_LISTEN_PORT" "$forward_port"

        FORWARD_TARGET="$temp_forward_target"
    fi

    ROLE="$ORIG_ROLE"
    NAT_LISTEN_PORT="$ORIG_NAT_LISTEN_PORT"
    REMOTE_IP="$ORIG_REMOTE_IP"
    REMOTE_PORT="$ORIG_REMOTE_PORT"
    EXIT_LISTEN_PORT="$ORIG_EXIT_LISTEN_PORT"
    FORWARD_TARGET="$ORIG_FORWARD_TARGET"
    SECURITY_LEVEL="$ORIG_SECURITY_LEVEL"
    TLS_SERVER_NAME="$ORIG_TLS_SERVER_NAME"
    TLS_CERT_PATH="$ORIG_TLS_CERT_PATH"
    TLS_KEY_PATH="$ORIG_TLS_KEY_PATH"
    PROTOCOL="$ORIG_PROTOCOL"

    echo ""

    echo -e "${BLUE}正在规则排序...${NC}"
    if reorder_rule_ids; then
        echo -e "${GREEN}✓ 规则排序优化完成${NC}"
    fi

    return 0
}

delete_rule() {
    local rule_id="$1"
    local skip_confirm="${2:-false}"
    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"

    if [ ! -f "$rule_file" ]; then
        echo -e "${RED}错误: 规则 $rule_id 不存在${NC}"
        return 1
    fi

    if read_rule_file "$rule_file"; then
        # 保存规则信息用于后续同步
        local deleted_listen_port="$LISTEN_PORT"
        local deleted_remote_host="$REMOTE_HOST"
        local deleted_remote_port="$REMOTE_PORT"
        local deleted_balance_mode="$BALANCE_MODE"
        local deleted_target_states="$TARGET_STATES"
        local deleted_weights="$WEIGHTS"
        local is_balance_mode=false

        if [ "$deleted_balance_mode" != "off" ] && [ -n "$deleted_target_states" ]; then
            is_balance_mode=true
        fi

        if [ "$skip_confirm" != "true" ]; then
            echo -e "${YELLOW}即将删除规则:${NC}"
            echo -e "${BLUE}规则ID: ${GREEN}$RULE_ID${NC}"
            echo -e "${BLUE}规则名称: ${GREEN}$RULE_NAME${NC}"
            echo -e "${BLUE}监听端口: ${GREEN}$LISTEN_PORT${NC}"

            if [ "$is_balance_mode" = true ]; then
                echo -e "${YELLOW}⚠️  此规则属于负载均衡组${NC}"
            fi
            echo ""

            read -p "确认删除此规则？(y/n): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "删除已取消"
                return 1
            fi
        fi

        if rm -f "$rule_file"; then
            echo -e "${GREEN}✓ 规则 $rule_id 已删除${NC}"

            # 负载均衡组删除：同步更新剩余规则
            if [ "$is_balance_mode" = true ]; then
                echo ""
                echo -e "${BLUE}正在同步更新负载均衡配置...${NC}"

                local deleted_target="${deleted_remote_host}:${deleted_remote_port}"

                local result=$(remove_target_from_states "$deleted_target_states" "$deleted_target" "$deleted_weights")
                local new_target_states="${result%|*}"
                local new_weights="${result#*|}"

                local remaining_count=0
                if [ -n "$new_target_states" ]; then
                    remaining_count=$(echo "$new_target_states" | tr ',' '\n' | grep -c .)
                fi

                if [ $remaining_count -le 1 ]; then
                    echo -e "${YELLOW}只剩1个目标，自动关闭负载均衡模式${NC}"
                    disable_balance_for_port "$deleted_listen_port"
                else
                    sync_target_states_for_port "$deleted_listen_port" "$new_target_states" "$new_weights"
                    local sync_count=$?

                    if [ $sync_count -gt 0 ]; then
                        echo -e "${GREEN}✓ 已同步更新 $sync_count 个相同端口的规则${NC}"
                    fi
                fi
            fi

            if [ "$skip_confirm" != "true" ]; then
                echo -e "${BLUE}正在规则排序...${NC}"
                if reorder_rule_ids; then
                    echo -e "${GREEN}✓ 规则排序优化完成${NC}"
                fi
            fi

            return 0
        else
            echo -e "${RED}✗ 规则 $rule_id 删除失败${NC}"
            return 1
        fi
    else
        echo -e "${RED}错误: 无法读取规则文件${NC}"
        return 1
    fi
}

batch_delete_rules() {
    local rule_ids="$1"

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

    echo -e "${YELLOW}即将删除以下规则:${NC}"
    echo ""
    for id in "${valid_ids_array[@]}"; do
        local rule_file="${RULES_DIR}/rule-${id}.conf"
        if read_rule_file "$rule_file"; then
            echo -e "${BLUE}规则ID: ${GREEN}$RULE_ID${NC} | ${BLUE}规则名称: ${GREEN}$RULE_NAME${NC} | ${BLUE}监听端口: ${GREEN}$LISTEN_PORT${NC}"
        fi
    done
    echo ""

    read -p "确认删除以上 $valid_count 个规则？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        for id in "${valid_ids_array[@]}"; do
            if delete_rule "$id" "true"; then
                deleted_count=$((deleted_count + 1))
            fi
        done
        echo ""
        echo -e "${GREEN}批量删除完成，共删除 $deleted_count 个规则${NC}"

        echo -e "${BLUE}正在规则排序...${NC}"
        if reorder_rule_ids; then
            echo -e "${GREEN}✓ 规则排序优化完成${NC}"
        fi

        return 0
    else
        echo "批量删除已取消"
        return 1
    fi
}

toggle_rule() {
    local rule_id="$1"
    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"

    if [ ! -f "$rule_file" ]; then
        echo -e "${RED}错误: 规则 $rule_id 不存在${NC}"
        return 1
    fi

    if read_rule_file "$rule_file"; then
        local new_status
        if [ "$ENABLED" = "true" ]; then
            new_status="false"
            echo -e "${YELLOW}正在禁用规则: $RULE_NAME${NC}"
        else
            new_status="true"
            echo -e "${YELLOW}正在启用规则: $RULE_NAME${NC}"
        fi

        sed -i "s/^ENABLED=.*/ENABLED=\"$new_status\"/" "$rule_file"

        if [ "$new_status" = "true" ]; then
            echo -e "${GREEN}✓ 规则已启用${NC}"
        else
            echo -e "${GREEN}✓ 规则已禁用${NC}"
        fi

        return 0
    else
        echo -e "${RED}错误: 无法读取规则文件${NC}"
        return 1
    fi
}

generate_export_metadata() {
    local metadata_file="$1"
    local rules_count="$2"

    cat > "$metadata_file" <<EOF
EXPORT_TIME=$(get_gmt8_time '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
EXPORT_HOST=$(hostname 2>/dev/null || echo "unknown")
RULES_COUNT=$rules_count
HAS_MANAGER_CONF=$([ -f "$MANAGER_CONF" ] && echo "true" || echo "false")
HAS_HEALTH_STATUS=$([ -f "$HEALTH_STATUS_FILE" ] && echo "true" || echo "false")
PACKAGE_VERSION=1.0
EOF
}

export_config_package() {
    echo -e "${YELLOW}=== 导出配置包 ===${NC}"
    echo ""

    local rules_count=$(get_active_rules_count)

    local has_manager_conf=false
    [ -f "$MANAGER_CONF" ] && has_manager_conf=true

    if [ $rules_count -eq 0 ] && [ "$has_manager_conf" = false ]; then
        echo -e "${RED}没有可导出的配置数据${NC}"
        echo ""
        read -p "按回车键返回..."
        return 1
    fi

    echo -e "${BLUE}将要导出的完整配置：${NC}"
    echo -e "  转发规则: ${GREEN}$rules_count 条${NC}"
    [ "$has_manager_conf" = true ] && echo -e "  管理状态: ${GREEN}包含${NC}"
    [ -f "$HEALTH_STATUS_FILE" ] && echo -e "  健康监控: ${GREEN}包含${NC}"
    echo -e "  备注权重: ${GREEN}完整保留${NC}"
    echo ""

    read -p "确认导出配置包？(y/n): " confirm
    if ! echo "$confirm" | grep -qE "^[Yy]$"; then
        echo -e "${BLUE}已取消导出操作${NC}"
        read -p "按回车键返回..."
        return
    fi

    local export_dir="/usr/local/bin"
    local timestamp=$(get_gmt8_time '+%Y%m%d_%H%M%S')
    local export_filename="xwPF_config_${timestamp}.tar.gz"
    local export_path="${export_dir}/${export_filename}"

    local temp_dir=$(mktemp -d)
    local package_dir="${temp_dir}/xwPF_config"
    mkdir -p "$package_dir"

    echo ""
    echo -e "${YELLOW}正在收集配置数据...${NC}"

    generate_export_metadata "${package_dir}/metadata.txt" "$rules_count"

    if [ $rules_count -gt 0 ]; then
        mkdir -p "${package_dir}/rules"
        cp "${RULES_DIR}"/rule-*.conf "${package_dir}/rules/" 2>/dev/null
        echo -e "${GREEN}✓${NC} 已收集 $rules_count 个规则文件"
    fi

    if [ -f "$MANAGER_CONF" ]; then
        cp "$MANAGER_CONF" "${package_dir}/"
        echo -e "${GREEN}✓${NC} 已收集管理配置文件"
    fi

    if [ -f "$HEALTH_STATUS_FILE" ]; then
        cp "$HEALTH_STATUS_FILE" "${package_dir}/health_status.conf"
        echo -e "${GREEN}✓${NC} 已收集健康状态文件"
    fi

    local mptcp_conf="/etc/sysctl.d/90-enable-MPTCP.conf"
    if [ -f "$mptcp_conf" ]; then
        cp "$mptcp_conf" "${package_dir}/90-enable-MPTCP.conf"
        echo -e "${GREEN}✓${NC} 已收集MPTCP系统配置文件"
    fi

    # 导出运行时MPTCP端点配置，便于在新环境中快速恢复
    if command -v ip >/dev/null 2>&1 && /usr/bin/ip mptcp endpoint show >/dev/null 2>&1; then
        local endpoints_output=$(/usr/bin/ip mptcp endpoint show 2>/dev/null)
        if [ -n "$endpoints_output" ]; then
            echo "$endpoints_output" > "${package_dir}/mptcp_endpoints.conf"
            echo -e "${GREEN}✓${NC} 已收集MPTCP端点配置"
        fi
    fi

    echo -e "${YELLOW}正在创建压缩包...${NC}"
    cd "$temp_dir"
    if tar -czf "$export_path" xwPF_config/ >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 配置包导出成功${NC}"
        echo ""
        echo -e "${BLUE}导出信息：${NC}"
        echo -e "  文件名: ${GREEN}$export_filename${NC}"
        echo -e "  路径: ${GREEN}$export_path${NC}"
        echo -e "  大小: ${GREEN}$(du -h "$export_path" 2>/dev/null | cut -f1)${NC}"
    else
        echo -e "${RED}✗ 配置包创建失败${NC}"
        rm -rf "$temp_dir"
        read -p "按回车键返回..."
        return 1
    fi

    rm -rf "$temp_dir"

    echo ""
    read -p "按回车键返回..."
}

export_config_with_view() {
    echo -e "${YELLOW}=== 查看配置文件 ===${NC}"
    echo -e "${BLUE}当前生效配置文件:${NC}"
    echo -e "${YELLOW}文件: $CONFIG_PATH${NC}"
    echo ""

    if [ -f "$CONFIG_PATH" ]; then
        cat "$CONFIG_PATH" | sed 's/^/  /'
    else
        echo -e "${RED}配置文件不存在${NC}"
    fi

    echo ""
    echo "是否一键导出当前全部文件架构？"
    echo -e "${GREEN}1.${NC}  一键导出为压缩包 "
    echo -e "${GREEN}0.${NC} 返回菜单"
    echo ""
    read -p "请输入选择 [0-1]: " export_choice
    echo ""

    case $export_choice in
        1)
            export_config_package
            ;;
        0)
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            read -p "按回车键继续..."
            ;;
    esac
}

# 验证逻辑，返回配置目录路径供后续使用
validate_config_package_content() {
    local package_file="$1"
    local temp_dir=$(mktemp -d)

    if ! tar -xzf "$package_file" -C "$temp_dir" >/dev/null 2>&1; then
        rm -rf "$temp_dir"
        return 1
    fi

    local config_dir=""
    for dir in "$temp_dir"/*; do
        if [ -d "$dir" ] && [ -f "$dir/metadata.txt" ]; then
            config_dir="$dir"
            break
        fi
    done

    if [ -z "$config_dir" ]; then
        rm -rf "$temp_dir"
        return 1
    fi

    echo "$config_dir"
    return 0
}

import_config_package() {
    echo -e "${YELLOW}=== 导入配置包 ===${NC}"
    echo ""

    read -p "请输入配置包的完整路径：" package_path
    echo ""

    if [ -z "$package_path" ]; then
        echo -e "${BLUE}已取消操作${NC}"
        read -p "按回车键返回..."
        return
    fi

    if [ ! -f "$package_path" ]; then
        echo -e "${RED}文件不存在: $package_path${NC}"
        read -p "按回车键返回..."
        return
    fi

    echo -e "${YELLOW}正在验证配置包...${NC}"
    local config_dir=$(validate_config_package_content "$package_path")
    if [ $? -ne 0 ] || [ -z "$config_dir" ]; then
        echo -e "${RED}无效的配置包文件${NC}"
        read -p "按回车键返回..."
        return
    fi

    local selected_filename=$(basename "$package_path")

    echo -e "${BLUE}配置包: ${GREEN}$selected_filename${NC}"

    if [ -f "${config_dir}/metadata.txt" ]; then
        source "${config_dir}/metadata.txt"
        echo -e "${BLUE}配置包信息：${NC}"
        echo -e "  导出时间: ${GREEN}$EXPORT_TIME${NC}"
        echo -e "  脚本版本: ${GREEN}$SCRIPT_VERSION${NC}"
        echo -e "  规则数量: ${GREEN}$RULES_COUNT${NC}"
        echo ""
    fi

    local current_rules=$(get_active_rules_count)

    echo -e "${YELLOW}当前规则数量: $current_rules${NC}"
    echo -e "${YELLOW}即将导入规则: $RULES_COUNT${NC}"
    echo ""
    echo -e "${RED}警告: 导入操作将覆盖所有现有配置！${NC}"
    echo ""

    read -p "确认导入配置包？(y/n): " confirm
    if ! echo "$confirm" | grep -qE "^[Yy]$"; then
        echo -e "${BLUE}已取消导入操作${NC}"
        rm -rf "$(dirname "$config_dir")"
        read -p "按回车键返回..."
        return
    fi

    echo ""
    echo -e "${YELLOW}正在导入配置...${NC}"

    echo -e "${BLUE}正在清理现有配置...${NC}"
    if [ -d "$RULES_DIR" ]; then
        rm -f "${RULES_DIR}"/rule-*.conf 2>/dev/null
    fi
    rm -f "$MANAGER_CONF" 2>/dev/null
    rm -f "$HEALTH_STATUS_FILE" 2>/dev/null

    init_rules_dir

    local imported_count=0

    if [ -d "${config_dir}/rules" ]; then
        for rule_file in "${config_dir}/rules"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                local rule_name=$(basename "$rule_file")
                cp "$rule_file" "${RULES_DIR}/"
                imported_count=$((imported_count + 1))
                echo -e "${GREEN}✓${NC} 恢复规则文件: $rule_name"
            fi
        done
    fi

    if [ -f "${config_dir}/manager.conf" ]; then
        cp "${config_dir}/manager.conf" "$MANAGER_CONF"
        echo -e "${GREEN}✓${NC} 恢复管理配置文件"
    fi

    if [ -f "${config_dir}/health_status.conf" ]; then
        cp "${config_dir}/health_status.conf" "$HEALTH_STATUS_FILE"
        echo -e "${GREEN}✓${NC} 恢复健康状态文件"
    fi

    if [ -f "${config_dir}/90-enable-MPTCP.conf" ]; then
        local mptcp_conf="/etc/sysctl.d/90-enable-MPTCP.conf"
        cp "${config_dir}/90-enable-MPTCP.conf" "$mptcp_conf"
        echo -e "${GREEN}✓${NC} 恢复MPTCP系统配置文件"
        sysctl -p "$mptcp_conf" >/dev/null 2>&1
    fi

    # 解析MPTCP端点配置格式，支持三种端点模式
    if [ -f "${config_dir}/mptcp_endpoints.conf" ] && command -v ip >/dev/null 2>&1; then
        echo -e "${YELLOW}正在恢复MPTCP端点配置...${NC}"
        /usr/bin/ip mptcp endpoint flush 2>/dev/null

        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local addr=$(echo "$line" | awk '{print $1}')
                local dev=$(echo "$line" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

                local flags=""
                if echo "$line" | grep -q "subflow.*fullmesh"; then
                    flags="subflow fullmesh"
                elif echo "$line" | grep -q "subflow.*backup"; then
                    flags="subflow backup"
                elif echo "$line" | grep -q "signal"; then
                    flags="signal"
                fi

                if [ -n "$addr" ] && [ -n "$dev" ] && [ -n "$flags" ]; then
                    /usr/bin/ip mptcp endpoint add "$addr" dev "$dev" $flags 2>/dev/null
                fi
            fi
        done < "${config_dir}/mptcp_endpoints.conf"
        echo -e "${GREEN}✓${NC} 恢复MPTCP端点配置"
    fi

    rm -rf "$(dirname "$config_dir")"

    if [ $imported_count -gt 0 ]; then
        echo -e "${GREEN}✓ 配置导入成功，共恢复 $imported_count 个规则${NC}"
        echo ""
        echo -e "${YELLOW}正在重启服务以应用新配置...${NC}"
        service_restart
        echo ""
        echo -e "${GREEN}配置导入完成！${NC}"
    else
        echo -e "${RED}✗ 配置导入失败${NC}"
    fi

    echo ""
    read -p "按回车键返回..."
}

get_proxy_mode_display() {
    local mode="$1"
    case "$mode" in
        "off")
            echo "关闭"
            ;;
        "v1_send")
            echo "v1发送"
            ;;
        "v1_accept")
            echo "v1接收"
            ;;
        "v1_both")
            echo "v1双向"
            ;;
        "v2_send")
            echo "v2发送"
            ;;
        "v2_accept")
            echo "v2接收"
            ;;
        "v2_both")
            echo "v2双向"
            ;;
        *)
            echo "关闭"
            ;;
    esac
}

get_proxy_mode_color() {
    local mode="$1"
    case "$mode" in
        "off")
            echo "${WHITE}"
            ;;
        "v1_send"|"v2_send")
            echo "${BLUE}"
            ;;
        "v1_accept"|"v2_accept")
            echo "${YELLOW}"
            ;;
        "v1_both"|"v2_both")
            echo "${GREEN}"
            ;;
        *)
            echo "${WHITE}"
            ;;
    esac
}

# 初始化所有规则文件的Proxy字段
init_proxy_fields() {
    init_rule_field "PROXY_MODE" "off"
}

proxy_management_menu() {
    init_proxy_fields

    while true; do
        clear
        echo -e "${GREEN}=== Proxy Protocol 管理 ===${NC}"
        echo ""

        local config_file="/etc/realm/config.json"
        local global_send_proxy=$(jq -r '.network.send_proxy // false' "$config_file" 2>/dev/null)
        if [ "$global_send_proxy" = "true" ]; then
            echo -e "${GREEN}全局[开启]${NC}"
        else
            echo -e "${RED}全局[关闭]${NC}"
        fi
        echo ""
        echo "当前规则列表(可单独开启或关闭覆盖全局):"
        echo ""

        if ! list_rules_with_info "proxy"; then
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo "多ID使用逗号,分隔"
        read -p "请输入要配置的规则ID（输入0切换全局状态）: " rule_input
        if [ -z "$rule_input" ]; then
            return
        fi

        # 处理全局状态切换（输入0）
        if [ "$rule_input" = "0" ]; then
            echo ""
            local config_file="/etc/realm/config.json"
            local current_status=$(jq -r '.network.send_proxy // false' "$config_file" 2>/dev/null)
            local temp_config=$(mktemp)

            if [ "$current_status" = "true" ]; then
                echo -e "${YELLOW}关闭全局Proxy Protocol...${NC}"
                jq 'del(.network.send_proxy) |
                    del(.network.send_proxy_version) |
                    del(.network.accept_proxy) |
                    del(.network.accept_proxy_timeout)' "$config_file" > "$temp_config"
                mv "$temp_config" "$config_file"
                echo -e "${GREEN}✓ 已关闭全局Proxy Protocol${NC}"
            else
                echo -e "${YELLOW}开启全局Proxy Protocol...${NC}"
                jq '.network.send_proxy = true |
                    .network.send_proxy_version = 2 |
                    .network.accept_proxy = true |
                    .network.accept_proxy_timeout = 5' "$config_file" > "$temp_config"
                mv "$temp_config" "$config_file"
                echo -e "${GREEN}✓ 已开启全局Proxy Protocol${NC}"
            fi

            restart_realm_service true

            read -p "按回车键继续..."
            continue
        fi

        echo ""
        echo -e "${BLUE}请选择 Proxy 协议版本:${NC}"
        echo -e "${WHITE}1.${NC} off (关闭)"
        echo -e "${BLUE}2.${NC} 协议v1"
        echo -e "${GREEN}3.${NC} 协议v2"
        echo ""

        read -p "请选择协议版本（回车默认v2） [1-3]: " version_choice
        if [ -z "$version_choice" ]; then
            version_choice="3"
        fi

        if [ "$version_choice" = "1" ]; then
            if [[ "$rule_input" == *","* ]]; then
                batch_set_proxy_mode "$rule_input" "off" ""
            else
                if [[ "$rule_input" =~ ^[0-9]+$ ]]; then
                    set_proxy_mode "$rule_input" "off" ""
                else
                    echo -e "${RED}无效的规则ID${NC}"
                fi
            fi
            read -p "按回车键继续..."
            continue
        fi

        echo ""
        echo -e "${BLUE}请选择 Proxy 方向:${NC}"
        echo -e "${BLUE}1.${NC} 仅发送 (send_proxy)"
        echo -e "${YELLOW}2.${NC} 仅接收 (accept_proxy)"
        echo -e "${GREEN}3.${NC} 双向 (send + accept)"
        echo ""

        read -p "请选择方向 [1-3]: " direction_choice
        if [ -z "$direction_choice" ]; then
            continue
        fi

        if [[ "$rule_input" == *","* ]]; then
            batch_set_proxy_mode "$rule_input" "$version_choice" "$direction_choice"
        else
            if [[ "$rule_input" =~ ^[0-9]+$ ]]; then
                set_proxy_mode "$rule_input" "$version_choice" "$direction_choice"
            else
                echo -e "${RED}无效的规则ID${NC}"
            fi
        fi
        read -p "按回车键继续..."
    done
}

batch_set_proxy_mode() {
    local rule_ids="$1"
    local version_choice="$2"
    local direction_choice="$3"

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

    echo -e "${YELLOW}即将为以下规则设置Proxy模式:${NC}"
    echo ""
    for id in "${valid_ids_array[@]}"; do
        local rule_file="${RULES_DIR}/rule-${id}.conf"
        if read_rule_file "$rule_file"; then
            echo -e "${BLUE}规则ID: ${GREEN}$RULE_ID${NC} | ${BLUE}规则名称: ${GREEN}$RULE_NAME${NC}"
        fi
    done
    echo ""

    read -p "确认为以上 $valid_count 个规则设置Proxy模式？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local success_count=0
        for id in "${valid_ids_array[@]}"; do
            if set_proxy_mode "$id" "$version_choice" "$direction_choice" "batch"; then
                success_count=$((success_count + 1))
            fi
        done

        if [ $success_count -gt 0 ]; then
            echo -e "${GREEN}✓ 成功设置 $success_count 个规则的Proxy模式${NC}"
            echo -e "${YELLOW}正在重启服务以应用配置更改...${NC}"
            if service_restart; then
                echo -e "${GREEN}✓ 服务重启成功，Proxy配置已生效${NC}"
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

set_proxy_mode() {
    local rule_id="$1"
    local version_choice="$2"
    local direction_choice="$3"
    local batch_mode="$4"

    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"
    if [ ! -f "$rule_file" ]; then
        echo -e "${RED}错误: 规则 $rule_id 不存在${NC}"
        return 1
    fi

    if ! read_rule_file "$rule_file"; then
        echo -e "${RED}错误: 读取规则文件失败${NC}"
        return 1
    fi

    if [ "$version_choice" = "off" ]; then
        local new_mode="off"
        local mode_display=$(get_proxy_mode_display "$new_mode")
        local mode_color=$(get_proxy_mode_color "$new_mode")

        if [ "$batch_mode" != "batch" ]; then
            echo -e "${YELLOW}正在为规则 '$RULE_NAME' 关闭Proxy功能${NC}"
        fi

        update_proxy_mode_in_file "$rule_file" "$new_mode"

        if [ $? -eq 0 ]; then
            if [ "$batch_mode" != "batch" ]; then
                echo -e "${GREEN}✓ Proxy已关闭${NC}"
                restart_service_for_proxy
            fi
        fi
        return $?
    fi

    local version=""
    case "$version_choice" in
        "2")
            version="v1"
            ;;
        "3")
            version="v2"
            ;;
        *)
            echo -e "${RED}无效的版本选择${NC}"
            return 1
            ;;
    esac

    local direction=""
    case "$direction_choice" in
        "1")
            direction="send"
            ;;
        "2")
            direction="accept"
            ;;
        "3")
            direction="both"
            ;;
        *)
            echo -e "${RED}无效的方向选择${NC}"
            return 1
            ;;
    esac

    local new_mode="${version}_${direction}"
    local mode_display=$(get_proxy_mode_display "$new_mode")
    local mode_color=$(get_proxy_mode_color "$new_mode")

    if [ "$batch_mode" != "batch" ]; then
        echo -e "${YELLOW}正在为规则 '$RULE_NAME' 设置Proxy模式为: ${mode_color}$mode_display${NC}"
    fi

    update_proxy_mode_in_file "$rule_file" "$new_mode"

    if [ $? -eq 0 ]; then
        if [ "$batch_mode" != "batch" ]; then
            echo -e "${GREEN}✓ Proxy模式已更新为: ${mode_color}$mode_display${NC}"
            restart_service_for_proxy
        fi
        return 0
    else
        if [ "$batch_mode" != "batch" ]; then
            echo -e "${RED}✗ 更新Proxy模式失败${NC}"
        fi
        return 1
    fi
}

update_proxy_mode_in_file() {
    local rule_file="$1"
    local new_mode="$2"
    local temp_file="${rule_file}.tmp.$$"

    if grep -q "^PROXY_MODE=" "$rule_file"; then
        grep -v "^PROXY_MODE=" "$rule_file" > "$temp_file"
        echo "PROXY_MODE=\"$new_mode\"" >> "$temp_file"
        mv "$temp_file" "$rule_file"
    else
        echo "PROXY_MODE=\"$new_mode\"" >> "$rule_file"
    fi
}

restart_service_for_proxy() {
    echo -e "${YELLOW}正在重启服务以应用Proxy配置...${NC}"
    if service_restart; then
        echo -e "${GREEN}✓ 服务重启成功，Proxy配置已生效${NC}"
        return 0
    else
        echo -e "${RED}✗ 服务重启失败，请检查配置${NC}"
        return 1
    fi
}

load_balance_management_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 负载均衡管理(按端口组管理) ===${NC}"
        echo ""

        if [ ! -d "$RULES_DIR" ] || [ -z "$(ls -A "$RULES_DIR"/*.conf 2>/dev/null)" ]; then
            echo -e "${YELLOW}暂无转发规则，请先创建转发规则${NC}"
            echo ""
            read -p "按回车键返回..."
            return
        fi

        # 按端口分组收集中转服务器规则，只显示有多个服务器的端口组
        declare -A port_groups
        declare -A port_configs
        declare -A port_balance_modes
        declare -A port_weights
        declare -A port_failover_status

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ]; then
                    local port_key="$LISTEN_PORT"

                    if [ -z "${port_configs[$port_key]}" ]; then
                        port_configs[$port_key]="$RULE_NAME"
                        port_balance_modes[$port_key]="${BALANCE_MODE:-off}"
                        port_weights[$port_key]="$WEIGHTS"
                        port_failover_status[$port_key]="${FAILOVER_ENABLED:-false}"
                    elif [[ "$WEIGHTS" == *","* ]]; then
                        port_weights[$port_key]="$WEIGHTS"
                    fi

                    if [[ "$REMOTE_HOST" == *","* ]]; then
                        IFS=',' read -ra host_array <<< "$REMOTE_HOST"
                        for host in "${host_array[@]}"; do
                            local target="$host:$REMOTE_PORT"
                            if [[ "${port_groups[$port_key]}" != *"$target"* ]]; then
                                if [ -z "${port_groups[$port_key]}" ]; then
                                    port_groups[$port_key]="$target"
                                else
                                    port_groups[$port_key]="${port_groups[$port_key]},$target"
                                fi
                            fi
                        done
                    else
                        local target="$REMOTE_HOST:$REMOTE_PORT"
                        if [[ "${port_groups[$port_key]}" != *"$target"* ]]; then
                            if [ -z "${port_groups[$port_key]}" ]; then
                                port_groups[$port_key]="$target"
                            else
                                port_groups[$port_key]="${port_groups[$port_key]},$target"
                            fi
                        fi
                    fi
                fi
            fi
        done

        local has_balance_groups=false
        echo -e "${GREEN}中转服务器:${NC}"

        for port_key in $(printf '%s\n' "${!port_groups[@]}" | sort -n); do
            IFS=',' read -ra targets <<< "${port_groups[$port_key]}"
            local target_count=${#targets[@]}

            if [ $target_count -gt 1 ]; then
                has_balance_groups=true

                local balance_mode="${port_balance_modes[$port_key]}"
                local balance_info=$(get_balance_info_display "${port_groups[$port_key]}" "$balance_mode")

                # 显示端口组标题
                echo -e "  ${BLUE}端口 $port_key${NC}: ${GREEN}${port_configs[$port_key]}${NC} [$balance_info] - $target_count个服务器"

                # 显示每个服务器及其权重
                for ((i=0; i<target_count; i++)); do
                    local target="${targets[i]}"

                    # 获取权重信息
                    local current_weight=1
                    local weights_str="${port_weights[$port_key]}"

                    if [ -n "$weights_str" ] && [[ "$weights_str" == *","* ]]; then
                        IFS=',' read -ra weight_array <<< "$weights_str"
                        current_weight="${weight_array[i]:-1}"
                    elif [ -n "$weights_str" ] && [[ "$weights_str" != *","* ]]; then
                        current_weight="$weights_str"
                    fi

                    # 计算权重百分比
                    local total_weight=0
                    if [ -n "$weights_str" ] && [[ "$weights_str" == *","* ]]; then
                        IFS=',' read -ra weight_array <<< "$weights_str"
                        for w in "${weight_array[@]}"; do
                            total_weight=$((total_weight + w))
                        done
                    else
                        total_weight=$((target_count * current_weight))
                    fi

                    local percentage
                    if [ "$total_weight" -gt 0 ]; then
                        if command -v bc >/dev/null 2>&1; then
                            percentage=$(echo "scale=1; $current_weight * 100 / $total_weight" | bc 2>/dev/null || echo "100.0")
                        else
                            percentage=$(awk "BEGIN {printf \"%.1f\", $current_weight * 100 / $total_weight}")
                        fi
                    else
                        percentage="100.0"
                    fi

                    # 构建故障转移状态信息
                    local failover_info=""
                    if [ "$balance_mode" != "off" ] && [ "${port_failover_status[$port_key]}" = "true" ]; then
                        local health_status_file="/etc/realm/health/health_status.conf"
                        local node_status="healthy"

                        if [ -f "$health_status_file" ]; then
                            local host_only=$(echo "$target" | cut -d':' -f1)
                            local health_key="*|${host_only}"
                            local found_status=$(grep "^.*|${host_only}|" "$health_status_file" 2>/dev/null | cut -d'|' -f3 | head -1)
                            if [ "$found_status" = "failed" ]; then
                                node_status="failed"
                            fi
                        fi

                        case "$node_status" in
                            "healthy") failover_info=" ${GREEN}[健康]${NC}" ;;
                            "failed") failover_info=" ${RED}[故障]${NC}" ;;
                        esac
                    fi

                    # 显示服务器信息（只在负载均衡模式下显示权重）
                    if [ "$balance_mode" != "off" ]; then
                        echo -e "    ${BLUE}$((i+1)).${NC} $target ${GREEN}[权重: $current_weight]${NC} ${BLUE}($percentage%)${NC}$failover_info"
                    else
                        echo -e "    ${BLUE}$((i+1)).${NC} $target$failover_info"
                    fi
                done
                echo ""
            fi
        done

        if [ "$has_balance_groups" = false ]; then
            echo -e "${YELLOW}暂无符合条件的负载均衡组${NC}"
            echo -e "${BLUE}提示: 只显示单端口有至少两台服务器的中转规则${NC}"
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 切换负载均衡模式"
        echo -e "${BLUE}2.${NC} 权重配置管理"
        echo -e "${YELLOW}3.${NC} 开启/关闭故障转移"
        echo -e "${RED}0.${NC} 返回上级菜单"
        echo ""

        read -p "请输入选择 [0-3]: " choice
        echo ""

        case $choice in
            1)
                # 切换负载均衡模式
                switch_balance_mode
                ;;
            2)
                # 权重配置管理
                weight_management_menu
                ;;
            3)
                # 开启/关闭故障转移
                failover_management_menu
                ;;
            0)
                # 返回上级菜单
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-3${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

# 切换负载均衡模式（按端口分组管理）
switch_balance_mode() {
    while true; do
        clear
        echo -e "${YELLOW}=== 切换负载均衡模式 ===${NC}"
        echo ""

        # 按端口分组收集中转服务器规则
        # 清空并重新初始化关联数组
        unset port_groups port_configs port_balance_modes
        declare -A port_groups
        declare -A port_configs
        declare -A port_balance_modes

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ]; then
                    local port_key="$LISTEN_PORT"

                    # 存储端口配置（使用第一个规则的配置作为基准）
                    if [ -z "${port_configs[$port_key]}" ]; then
                        port_configs[$port_key]="$RULE_NAME"
                        port_balance_modes[$port_key]="${BALANCE_MODE:-off}"
                    fi

                    # 正确处理REMOTE_HOST中可能包含多个地址的情况
                    if [[ "$REMOTE_HOST" == *","* ]]; then
                        # REMOTE_HOST包含多个地址，分别添加
                        IFS=',' read -ra host_array <<< "$REMOTE_HOST"
                        for host in "${host_array[@]}"; do
                            local target="$host:$REMOTE_PORT"
                            # 检查是否已存在，避免重复添加
                            if [[ "${port_groups[$port_key]}" != *"$target"* ]]; then
                                if [ -z "${port_groups[$port_key]}" ]; then
                                    port_groups[$port_key]="$target"
                                else
                                    port_groups[$port_key]="${port_groups[$port_key]},$target"
                                fi
                            fi
                        done
                    else
                        # REMOTE_HOST是单个地址
                        local target="$REMOTE_HOST:$REMOTE_PORT"
                        # 检查是否已存在，避免重复添加
                        if [[ "${port_groups[$port_key]}" != *"$target"* ]]; then
                            if [ -z "${port_groups[$port_key]}" ]; then
                                port_groups[$port_key]="$target"
                            else
                                port_groups[$port_key]="${port_groups[$port_key]},$target"
                            fi
                        fi
                    fi
                fi
            fi
        done

        # 显示端口组列表（只显示有多个目标服务器的端口组）
        local has_balance_rules=false
        declare -a rule_ports
        declare -a rule_names

        for port_key in "${!port_groups[@]}"; do
            # 计算目标服务器总数
            IFS=',' read -ra targets <<< "${port_groups[$port_key]}"
            local target_count=${#targets[@]}

            # 只显示有多个目标服务器的端口组
            if [ "$target_count" -gt 1 ]; then
                if [ "$has_balance_rules" = false ]; then
                    echo "请选择要切换负载均衡模式的规则组 (仅显示多目标服务器的规则组):"
                    has_balance_rules=true
                fi

                # 使用数字ID
                local rule_number=$((${#rule_ports[@]} + 1))
                rule_ports+=("$port_key")
                rule_names+=("${port_configs[$port_key]}")

                local balance_mode="${port_balance_modes[$port_key]}"
                local balance_display=""
                case "$balance_mode" in
                    "roundrobin")
                        balance_display="${YELLOW}[轮询]${NC}"
                        ;;
                    "iphash")
                        balance_display="${BLUE}[IP哈希]${NC}"
                        ;;
                    *)
                        balance_display="${WHITE}[off]${NC}"
                        ;;
                esac

                echo -e "${GREEN}$rule_number.${NC} ${port_configs[$port_key]} (端口: $port_key) $balance_display - $target_count个目标服务器"
            fi
        done

        if [ "$has_balance_rules" = false ]; then
            echo -e "${YELLOW}暂无多目标服务器的规则组${NC}"
            echo -e "${BLUE}提示: 只有具有多个目标服务器的规则组才能配置负载均衡${NC}"
            echo ""
            echo -e "${BLUE}负载均衡的前提条件：${NC}"
            echo -e "${BLUE}  1. 规则类型为中转服务器${NC}"
            echo -e "${BLUE}  2. 有多个目标服务器（单规则多地址或多规则单地址）${NC}"
            echo ""
            echo -e "${YELLOW}如果您需要添加更多目标服务器：${NC}"
            echo -e "${BLUE}  请到 '转发配置管理' → '添加转发规则' 创建更多规则${NC}"
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo -e "${WHITE}注意: 负载均衡模式将应用到选定端口组的所有相关规则${NC}"
        echo ""
        read -p "请输入规则编号 [1-${#rule_ports[@]}] (或按回车返回): " choice

        if [ -z "$choice" ]; then
            return
        fi

        # 验证数字输入
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#rule_ports[@]} ]; then
            echo -e "${RED}无效的规则编号${NC}"
            read -p "按回车键继续..."
            continue
        fi

        # 计算数组索引（从0开始）
        local selected_index=$((choice - 1))
        local selected_port="${rule_ports[$selected_index]}"
        local current_balance_mode="${port_balance_modes[$selected_port]}"

        echo ""
        echo -e "${GREEN}当前选择: ${port_configs[$selected_port]} (端口: $selected_port)${NC}"
        echo -e "${BLUE}当前负载均衡模式: $current_balance_mode${NC}"
        echo ""
        echo "请选择新的负载均衡模式:"
        echo -e "${GREEN}1.${NC} 关闭负载均衡（off）"
        echo -e "${YELLOW}2.${NC} 轮询 (roundrobin)"
        echo -e "${BLUE}3.${NC} IP哈希 (iphash)"
        echo ""

        read -p "请输入选择 [1-3]: " mode_choice

        local new_mode=""
        local mode_display=""
        case $mode_choice in
            1)
                new_mode="off"
                mode_display="关闭"
                ;;
            2)
                new_mode="roundrobin"
                mode_display="轮询"
                ;;
            3)
                new_mode="iphash"
                mode_display="IP哈希"
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                read -p "按回车键继续..."
                continue
                ;;
        esac

        # 更新选定端口组下所有相关规则的负载均衡模式
        local updated_count=0
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$selected_port" ]; then
                    sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"$new_mode\"/" "$rule_file"
                    updated_count=$((updated_count + 1))
                fi
            fi
        done

        if [ $updated_count -gt 0 ]; then
            echo -e "${GREEN}✓ 已将端口 $selected_port 的 $updated_count 个规则的负载均衡模式更新为: $mode_display${NC}"
            echo -e "${YELLOW}正在重启服务以应用更改...${NC}"

            # 重启realm服务
            if service_restart; then
                echo -e "${GREEN}✓ 服务重启成功，负载均衡模式已生效${NC}"
            else
                echo -e "${RED}✗ 服务重启失败，请检查配置${NC}"
            fi
        else
            echo -e "${RED}✗ 未找到相关规则文件${NC}"
        fi

        read -p "按回车键继续..."
    done
}


# 权重配置管理菜单
weight_management_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 权重配置管理 ===${NC}"
        echo ""

        # 按端口分组收集启用负载均衡的中转服务器规则
        declare -A port_groups
        declare -A port_configs
        declare -A port_weights
        declare -A port_balance_modes

        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ]; then
                    local port_key="$LISTEN_PORT"

                    # 存储端口配置（优先使用包含完整权重的规则）
                    if [ -z "${port_configs[$port_key]}" ]; then
                        port_configs[$port_key]="$RULE_NAME"
                        port_weights[$port_key]="$WEIGHTS"
                        port_balance_modes[$port_key]="${BALANCE_MODE:-off}"
                    elif [[ "$WEIGHTS" == *","* ]] && [[ "${port_weights[$port_key]}" != *","* ]]; then
                        # 如果当前规则有完整权重而已存储的没有，更新为完整权重
                        port_weights[$port_key]="$WEIGHTS"
                    fi

                    # 正确处理REMOTE_HOST中可能包含多个地址的情况
                    if [[ "$REMOTE_HOST" == *","* ]]; then
                        # REMOTE_HOST包含多个地址，分别添加
                        IFS=',' read -ra host_array <<< "$REMOTE_HOST"
                        for host in "${host_array[@]}"; do
                            local target="$host:$REMOTE_PORT"
                            # 检查是否已存在，避免重复添加
                            if [[ "${port_groups[$port_key]}" != *"$target"* ]]; then
                                if [ -z "${port_groups[$port_key]}" ]; then
                                    port_groups[$port_key]="$target"
                                else
                                    port_groups[$port_key]="${port_groups[$port_key]},$target"
                                fi
                            fi
                        done
                    else
                        # REMOTE_HOST是单个地址
                        local target="$REMOTE_HOST:$REMOTE_PORT"
                        # 检查是否已存在，避免重复添加
                        if [[ "${port_groups[$port_key]}" != *"$target"* ]]; then
                            if [ -z "${port_groups[$port_key]}" ]; then
                                port_groups[$port_key]="$target"
                            else
                                port_groups[$port_key]="${port_groups[$port_key]},$target"
                            fi
                        fi
                    fi
                fi
            fi
        done

        # 检查是否有需要权重配置的端口组（多目标服务器）
        local has_balance_rules=false
        local rule_ports=()
        local rule_names=()

        for port_key in "${!port_groups[@]}"; do
            # 计算目标服务器总数
            IFS=',' read -ra targets <<< "${port_groups[$port_key]}"
            local target_count=${#targets[@]}
            local balance_mode="${port_balance_modes[$port_key]}"

            # 只显示有多个目标服务器的端口组
            if [ "$target_count" -gt 1 ] && [ "$balance_mode" != "off" ] && [ -n "$balance_mode" ]; then
                if [ "$has_balance_rules" = false ]; then
                    echo "请选择要配置权重的规则组 (仅显示多目标服务器的负载均衡规则):"
                    has_balance_rules=true
                fi

                # 数字ID
                local rule_number=$((${#rule_ports[@]} + 1))
                rule_ports+=("$port_key")
                rule_names+=("${port_configs[$port_key]}")

                echo -e "${GREEN}$rule_number.${NC} ${port_configs[$port_key]} (端口: $port_key) [$balance_mode] - $target_count个目标服务器"
            fi
        done

        if [ "$has_balance_rules" = false ]; then
            echo -e "${YELLOW}暂无需要权重配置的规则组${NC}"
            echo ""
            echo -e "${BLUE}权重配置的前提条件：${NC}"
            echo -e "  1. 必须是中转服务器规则"
            echo -e "  2. 必须已启用负载均衡模式 (roundrobin/iphash)"
            echo -e "  3. 必须有多个目标服务器"
            echo ""
            echo -e "${YELLOW}如果您有多目标规则但未启用负载均衡：${NC}"
            echo -e "  请先选择 '切换负载均衡模式' 启用负载均衡，然后再配置权重"
            echo ""
            read -p "按回车键返回..."
            return
        fi

        echo ""
        echo -e "${GRAY}注意: 只有多个目标服务器的规则组才需要权重配置${NC}"
        echo ""
        read -p "请输入规则编号 [1-${#rule_ports[@]}] (或按回车返回): " selected_number

        if [ -z "$selected_number" ]; then
            break
        fi

        # 验证数字输入
        if ! [[ "$selected_number" =~ ^[0-9]+$ ]] || [ "$selected_number" -lt 1 ] || [ "$selected_number" -gt ${#rule_ports[@]} ]; then
            echo -e "${RED}无效的规则编号${NC}"
            read -p "按回车键继续..."
            continue
        fi

        # 计算数组索引（从0开始）
        local selected_index=$((selected_number - 1))

        # 配置选中端口组的权重
        local selected_port="${rule_ports[$selected_index]}"
        local selected_name="${rule_names[$selected_index]}"
        configure_port_group_weights "$selected_port" "$selected_name" "${port_groups[$selected_port]}" "${port_weights[$selected_port]}"
    done
}

# 配置端口组权重
configure_port_group_weights() {
    local port="$1"
    local rule_name="$2"
    local targets_str="$3"
    local current_weights_str="$4"

    clear
    echo -e "${GREEN}=== 权重配置: $rule_name ===${NC}"
    echo ""

    # 解析目标服务器
    IFS=',' read -ra targets <<< "$targets_str"
    local target_count=${#targets[@]}

    echo "规则组: $rule_name (端口: $port)"
    echo "目标服务器列表:"

    # 解析当前权重
    local current_weights
    if [ -n "$current_weights_str" ]; then
        IFS=',' read -ra current_weights <<< "$current_weights_str"
    else
        # 默认相等权重
        for ((i=0; i<target_count; i++)); do
            current_weights[i]=1
        done
    fi

    # 显示当前配置
    for ((i=0; i<target_count; i++)); do
        local weight="${current_weights[i]:-1}"
        echo -e "  $((i+1)). ${targets[i]} [当前权重: $weight]"
    done

    echo ""
    echo "请输入权重序列 (用逗号分隔):"
    echo -e "${WHITE}格式说明: 按服务器顺序输入权重值，如 \"2,1,3\"${NC}"
    echo -e "${WHITE}权重范围: 1-10，数值越大分配流量越多${NC}"
    echo ""

    read -p "权重序列: " weight_input

    if [ -z "$weight_input" ]; then
        echo -e "${YELLOW}未输入权重，保持原配置${NC}"
        read -p "按回车键返回..."
        return
    fi

    if ! validate_weight_input "$weight_input" "$target_count"; then
        read -p "按回车键返回..."
        return
    fi

    # 预览配置
    preview_port_group_weight_config "$port" "$rule_name" "$weight_input" "${targets[@]}"
}

# 验证权重输入
validate_weight_input() {
    local weight_input="$1"
    local expected_count="$2"

    # 检查格式
    if ! [[ "$weight_input" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo -e "${RED}权重格式错误，请使用数字和逗号，如: 2,1,3${NC}"
        return 1
    fi

    # 解析权重数组
    IFS=',' read -ra weights <<< "$weight_input"

    # 检查数量
    if [ "${#weights[@]}" -ne "$expected_count" ]; then
        echo -e "${RED}权重数量不匹配，需要 $expected_count 个权重值，实际输入 ${#weights[@]} 个${NC}"
        return 1
    fi

    # 检查权重值范围
    for weight in "${weights[@]}"; do
        if [ "$weight" -lt 1 ] || [ "$weight" -gt 10 ]; then
            echo -e "${RED}权重值 $weight 超出范围，请使用 1-10 之间的数值${NC}"
            return 1
        fi
    done

    return 0
}

# 预览端口组权重配置
preview_port_group_weight_config() {
    local port="$1"
    local rule_name="$2"
    local weight_input="$3"
    shift 3
    local targets=("$@")

    clear
    echo -e "${GREEN}=== 配置预览 ===${NC}"
    echo ""
    echo "规则组: $rule_name (端口: $port)"
    echo "权重配置变更:"

    # 获取当前权重（从第一个相关规则文件读取）
    local current_weights
    local first_rule_file=""
    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$port" ]; then
                first_rule_file="$rule_file"
                if [ -n "$WEIGHTS" ]; then
                    if [[ "$WEIGHTS" == *","* ]]; then
                        # 完整权重字符串
                        IFS=',' read -ra current_weights <<< "$WEIGHTS"
                    else
                        # 单个权重值，需要查找完整权重
                        local found_full_weights=false
                        for check_rule_file in "${RULES_DIR}"/rule-*.conf; do
                            if [ -f "$check_rule_file" ]; then
                                if read_rule_file "$check_rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$port" ] && [[ "$WEIGHTS" == *","* ]]; then
                                    IFS=',' read -ra current_weights <<< "$WEIGHTS"
                                    found_full_weights=true
                                    break
                                fi
                            fi
                        done

                        if [ "$found_full_weights" = false ]; then
                            # 默认相等权重
                            for ((i=0; i<${#targets[@]}; i++)); do
                                current_weights[i]=1
                            done
                        fi
                    fi
                else
                    # 默认相等权重
                    for ((i=0; i<${#targets[@]}; i++)); do
                        current_weights[i]=1
                    done
                fi
                break
            fi
        fi
    done

    # 解析新权重
    IFS=',' read -ra new_weights <<< "$weight_input"

    # 计算总权重
    local total_weight=0
    for weight in "${new_weights[@]}"; do
        total_weight=$((total_weight + weight))
    done

    # 显示变更详情
    for ((i=0; i<${#targets[@]}; i++)); do
        local old_weight="${current_weights[i]:-1}"
        local new_weight="${new_weights[i]}"
        local percentage
        if command -v bc >/dev/null 2>&1; then
            percentage=$(echo "scale=1; $new_weight * 100 / $total_weight" | bc 2>/dev/null || echo "0.0")
        else
            percentage=$(awk "BEGIN {printf \"%.1f\", $new_weight * 100 / $total_weight}")
        fi

        if [ "$old_weight" != "$new_weight" ]; then
            echo -e "  $((i+1)). ${targets[i]}: $old_weight → ${GREEN}$new_weight${NC} ${BLUE}($percentage%)${NC}"
        else
            echo -e "  $((i+1)). ${targets[i]}: $new_weight ${BLUE}($percentage%)${NC}"
        fi
    done

    echo ""
    read -p "确认应用此配置? [y/n]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 应用权重配置到该端口的所有相关规则
        apply_port_group_weight_config "$port" "$weight_input"
    else
        echo -e "${YELLOW}已取消配置更改${NC}"
        read -p "按回车键返回..."
    fi
}

# 应用端口组权重配置
apply_port_group_weight_config() {
    local port="$1"
    local weight_input="$2"

    local updated_count=0

    # 更新该端口的所有相关规则文件
    for rule_file in "${RULES_DIR}"/rule-*.conf; do
        if [ -f "$rule_file" ]; then
            if read_rule_file "$rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$port" ]; then
                # 更新规则文件中的权重配置
                # 对于第一个规则，存储完整权重；对于其他规则，存储对应的单个权重
                local rule_index=0
                local target_weight="$weight_input"

                # 计算当前规则在同端口规则中的索引
                for check_rule_file in "${RULES_DIR}"/rule-*.conf; do
                    if [ -f "$check_rule_file" ]; then
                        if read_rule_file "$check_rule_file" && [ "$RULE_ROLE" = "1" ] && [ "$LISTEN_PORT" = "$port" ]; then
                            if [ "$check_rule_file" = "$rule_file" ]; then
                                break
                            fi
                            rule_index=$((rule_index + 1))
                        fi
                    fi
                done

                # 根据规则索引确定要存储的权重
                if [ $rule_index -eq 0 ]; then
                    # 第一个规则存储完整权重
                    target_weight="$weight_input"
                else
                    # 其他规则存储对应位置的单个权重
                    IFS=',' read -ra weight_array <<< "$weight_input"
                    target_weight="${weight_array[$rule_index]:-1}"
                fi

                if grep -q "^WEIGHTS=" "$rule_file"; then
                    # 更新现有的WEIGHTS字段
                    if command -v sed >/dev/null 2>&1; then
                        sed -i.bak "s/^WEIGHTS=.*/WEIGHTS=\"$target_weight\"/" "$rule_file" && rm -f "$rule_file.bak"
                    else
                        # 如果没有sed，使用awk替代
                        awk -v new_weights="WEIGHTS=\"$target_weight\"" '
                            /^WEIGHTS=/ { print new_weights; next }
                            { print }
                        ' "$rule_file" > "$rule_file.tmp" && mv "$rule_file.tmp" "$rule_file"
                    fi
                else
                    # 如果没有WEIGHTS字段，在文件末尾添加
                    echo "WEIGHTS=\"$target_weight\"" >> "$rule_file"
                fi
                updated_count=$((updated_count + 1))
            fi
        fi
    done

    if [ $updated_count -gt 0 ]; then
        echo -e "${GREEN}✓ 已更新 $updated_count 个规则文件的权重配置${NC}"
        echo -e "${YELLOW}正在重启服务以应用更改...${NC}"

        if service_restart; then
            echo -e "${GREEN}✓ 服务重启成功，权重配置已生效${NC}"
        else
            echo -e "${RED}✗ 服务重启失败，请检查配置${NC}"
        fi
    else
        echo -e "${RED}✗ 未找到相关规则文件${NC}"
    fi

    read -p "按回车键返回..."
}
