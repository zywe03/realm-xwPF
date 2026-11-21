
# 子脚本按需更新：比对远端 SCRIPT_VERSION，本地已是最新则跳过下载。
# 取不到远端版本(网络不通)时沿用本地文件，不阻断功能
_update_sub_script() {
    local script_url="$1"
    local target_path="$2"
    local display_name="$3"

    mkdir -p "$(dirname "$target_path")"

    if [ ! -f "$target_path" ]; then
        echo -e "${GREEN}正在下载${display_name}...${NC}"
        if download_from_sources "$script_url" "$target_path"; then
            chmod +x "$target_path"
            return 0
        else
            echo -e "${RED}请检查网络连接${NC}"
            return 1
        fi
    fi

    local remote_ver=$(curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT \
        "$script_url" 2>/dev/null | \
        grep -E '^SCRIPT_VERSION=' | head -1 | cut -d'"' -f2)
    local local_ver=$(grep -E '^SCRIPT_VERSION=' "$target_path" 2>/dev/null | head -1 | cut -d'"' -f2)

    if [ -n "$remote_ver" ] && [ "$remote_ver" != "$local_ver" ]; then
        echo -e "${GREEN}发现${display_name}新版本: ${local_ver:-无} → ${remote_ver}，正在更新...${NC}"
        if download_from_sources "$script_url" "$target_path"; then
            chmod +x "$target_path"
        else
            echo -e "${RED}更新失败，使用现有版本${NC}"
        fi
    fi
    return 0
}

download_realm_ocr_script() {
    local script_url="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xw_realm_OCR.sh"
    local target_path="/etc/realm/xw_realm_OCR.sh"

    _update_sub_script "$script_url" "$target_path" "realm配置识别脚本"
}

import_realm_config() {
    local ocr_script="/etc/realm/xw_realm_OCR.sh"

    if ! download_realm_ocr_script; then
        echo -e "${RED}无法下载配置识别脚本，功能暂时不可用${NC}"
        read -p "按回车键返回..."
        return 1
    fi

    bash "$ocr_script" "$RULES_DIR"

    echo ""
    read -p "按回车键返回..."
}

rules_management_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 转发配置管理 ===${NC}"
        echo ""

        local enabled_count=0
        local disabled_count=0
        if [ -d "$RULES_DIR" ]; then
            for rule_file in "${RULES_DIR}"/rule-*.conf; do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file"; then
                        if [ "$ENABLED" = "true" ]; then
                            enabled_count=$((enabled_count + 1))
                        else
                            disabled_count=$((disabled_count + 1))
                        fi
                    fi
                fi
            done
        fi

        local status=$(svc_status_text)
        local total_count=$((enabled_count + disabled_count))
        if [ "$status" = "active" ]; then
            echo -e "服务状态: ${GREEN}●${NC} 运行中"
        elif [ "$total_count" -eq 0 ]; then
            echo -e "服务状态: ${RED}●${NC} 已停止（添加规则后启动）"
        else
            echo -e "服务状态: ${RED}●${NC} 已停止"
        fi

        if [ "$enabled_count" -gt 0 ] || [ "$disabled_count" -gt 0 ]; then
            local total_count=$((enabled_count + disabled_count))
            echo -e "配置模式: ${GREEN}多规则模式${NC} (${GREEN}$enabled_count${NC} 启用 / ${YELLOW}$disabled_count${NC} 禁用 / 共 $total_count 个)"

            if [ "$enabled_count" -gt 0 ]; then
                local has_relay_rules=false
                local relay_count=0
                for rule_file in $(get_sorted_rule_files); do
                    if [ -f "$rule_file" ]; then
                        if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "1" ]; then
                            if [ "$has_relay_rules" = false ]; then
                                echo -e "${GREEN}中转服务器:${NC}"
                                has_relay_rules=true
                            fi
                            relay_count=$((relay_count + 1))
                            local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                            local display_target=$(smart_display_target "$REMOTE_HOST")
                            local rule_display_name="$RULE_NAME"
                            local display_ip="${NAT_LISTEN_IP:-::}"
                            local through_display="${THROUGH_IP:-::}"
                            echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT"
                            local note_display=""
                            if [ -n "$RULE_NOTE" ]; then
                                note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                            fi
                            get_rule_status_display "$security_display" "$note_display"

                        fi
                    fi
                done

                local has_exit_rules=false
                local exit_count=0
                for rule_file in $(get_sorted_rule_files); do
                    if [ -f "$rule_file" ]; then
                        if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "2" ]; then
                            if [ "$has_exit_rules" = false ]; then
                                if [ "$has_relay_rules" = true ]; then
                                    echo ""
                                fi
                                echo -e "${GREEN}服务端服务器 (双端Realm架构):${NC}"
                                has_exit_rules=true
                            fi
                            exit_count=$((exit_count + 1))
                            local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                            local target_host="${FORWARD_TARGET%:*}"
                            local target_port="${FORWARD_TARGET##*:}"
                            local display_target=$(smart_display_target "$target_host")
                            local rule_display_name="$RULE_NAME"
                            local display_ip="::"
                            echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $display_target:$target_port"
                            local note_display=""
                            if [ -n "$RULE_NOTE" ]; then
                                note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                            fi
                            get_rule_status_display "$security_display" "$note_display"

                        fi
                    fi
                done
            fi

            if [ "$disabled_count" -gt 0 ]; then
                echo -e "${YELLOW}禁用的规则:${NC}"
                for rule_file in $(get_sorted_rule_files); do
                    if [ -f "$rule_file" ]; then
                        if read_rule_file "$rule_file" && [ "$ENABLED" = "false" ]; then
                            if [ "$RULE_ROLE" = "2" ]; then
                                local target_host="${FORWARD_TARGET%:*}"
                                local target_port="${FORWARD_TARGET##*:}"
                                local display_target=$(smart_display_target "$target_host")
                                echo -e "  • ${GRAY}$RULE_NAME${NC}: $LISTEN_PORT → $display_target:$target_port (已禁用)"
                            else
                                local display_target=$(smart_display_target "$REMOTE_HOST")
                                local through_display="${THROUGH_IP:-::}"
                                echo -e "  • ${GRAY}$RULE_NAME${NC}: $LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT (已禁用)"
                            fi
                        fi
                    fi
                done
            fi
        else
            echo -e "配置模式: ${BLUE}暂无配置${NC}"
        fi
        echo ""

        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 一键导出/导入配置"
        echo -e "${GREEN}2.${NC} 添加新配置"
        echo -e "${GREEN}3.${NC} 编辑现有规则"
        echo -e "${GREEN}4.${NC} 删除配置"
        echo -e "${GREEN}5.${NC} 启用/禁用中转规则"
        echo -e "${BLUE}6.${NC} 负载均衡管理"
        echo -e "${YELLOW}7.${NC} 开启/关闭 MPTCP"
        echo -e "${CYAN}8.${NC} 开启/关闭 Proxy Protocol"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""

        read -p "请输入选择 [0-8]: " choice
        echo ""

        case $choice in
            1)
                while true; do
                    clear
                    echo -e "${GREEN}=== 配置文件管理 ===${NC}"
                    echo ""
                    echo "请选择操作:"
                    echo -e "${GREEN}1.${NC} 导出配置包(包含查看配置)"
                    echo -e "${GREEN}2.${NC} 导入配置包"
                    echo -e "${GREEN}3.${NC} 识别realm配置文件并导入"
                    echo -e "${GREEN}0.${NC} 返回上级菜单"
                    echo ""
                    read -p "请输入选择 [0-3]: " sub_choice
                    echo ""

                    case $sub_choice in
                        1)
                            export_config_with_view
                            ;;
                        2)
                            import_config_package
                            ;;
                        3)
                            import_realm_config
                            ;;
                        0)
                            break
                            ;;
                        *)
                            echo -e "${RED}无效选择，请重新输入${NC}"
                            read -p "按回车键继续..."
                            ;;
                    esac
                done
                ;;
            2)
                interactive_add_rule
                if [ $? -eq 0 ]; then
                    echo -e "${YELLOW}正在重启服务以应用新配置...${NC}"
                    service_restart
                fi
                read -p "按回车键继续..."
                ;;
            3)
                edit_rule_interactive
                ;;
            4)
                echo -e "${YELLOW}=== 删除配置 ===${NC}"
                echo ""
                if list_rules_with_info "management"; then
                    echo ""
                    read -p "请输入要删除的规则ID(多ID使用逗号,分隔): " rule_input

                    if [ -z "$rule_input" ]; then
                        echo -e "${RED}错误: 请输入规则ID${NC}"
                    else
                        if [[ "$rule_input" == *","* ]]; then
                            batch_delete_rules "$rule_input"
                        else
                            if [[ "$rule_input" =~ ^[0-9]+$ ]]; then
                                delete_rule "$rule_input"
                            else
                                echo -e "${RED}无效的规则ID${NC}"
                            fi
                        fi

                        if [ $? -eq 0 ]; then
                            echo -e "${YELLOW}正在重启服务以应用配置更改...${NC}"
                            service_restart
                        fi
                    fi
                fi
                read -p "按回车键继续..."
                ;;
            5)
                echo -e "${YELLOW}=== 启用/禁用中转规则 ===${NC}"
                echo ""
                if list_rules_with_info "management"; then
                    echo ""
                    read -p "请输入要切换状态的规则ID: " rule_id
                    if [[ "$rule_id" =~ ^[0-9]+$ ]]; then
                        toggle_rule "$rule_id"
                        if [ $? -eq 0 ]; then
                            echo -e "${YELLOW}正在重启服务以应用状态更改...${NC}"
                            service_restart
                        fi
                    else
                        echo -e "${RED}无效的规则ID${NC}"
                    fi
                fi
                read -p "按回车键继续..."
                ;;
            6)
                load_balance_management_menu
                ;;
            7)
                mptcp_management_menu
                ;;
            8)
                proxy_management_menu
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-8${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

uninstall_realm() {
    echo -e "${RED}⚠️  警告: 即将分阶段卸载 Realm 端口转发服务${NC}"
    echo ""

    echo -e "${YELLOW}=== 第一阶段：Realm 相关全部服务和配置文件 ===${NC}"
    read -p "确认删除 Realm 服务和配置？(y/n): " confirm_realm
    if [[ "$confirm_realm" =~ ^[Yy]$ ]]; then
        uninstall_realm_stage_one
        echo -e "${GREEN}✓ 第一阶段完成${NC}"
    else
        echo -e "${BLUE}第一阶段已取消${NC}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}=== 第二阶段：xwPF 脚本相关全部文件 ===${NC}"
    read -p "确认删除脚本文件？(y/n): " confirm_script
    if [[ "$confirm_script" =~ ^[Yy]$ ]]; then
        uninstall_script_files
        echo -e "${GREEN}🗑️  完全卸载完成${NC}"
    else
        echo -e "${BLUE}脚本文件保留，可继续使用 pf 命令${NC}"
    fi
}

uninstall_realm_stage_one() {
    svc_is_active && svc_stop
    [ "$(svc_enabled_text)" = "enabled" ] && svc_disable
    # 停止健康检查服务（通过xwFailover.sh）
    if [ -f "/etc/realm/xwFailover.sh" ]; then
        bash "/etc/realm/xwFailover.sh" stop >/dev/null 2>&1
    fi
    pgrep "realm" >/dev/null 2>&1 && { pkill -f "realm"; sleep 2; pkill -9 -f "realm" 2>/dev/null; }

    cleanup_files_by_paths "$REALM_PATH" "$CONFIG_DIR" "$SYSTEMD_PATH" "/etc/realm"
    [ -f "/etc/init.d/realm" ] && rm -f "/etc/init.d/realm"
    cleanup_files_by_pattern "realm" "/var/log /tmp /var/tmp"

    [ -f "/etc/sysctl.d/90-enable-MPTCP.conf" ] && rm -f "/etc/sysctl.d/90-enable-MPTCP.conf"
    command -v ip >/dev/null 2>&1 && ip mptcp endpoint flush 2>/dev/null
    svc_daemon_reload
}

uninstall_script_files() {
    rm -f "$INSTALL_DIR/xwPF.sh"
    [ -d "$LIB_DIR" ] && rm -rf "$LIB_DIR"

    local exec_dirs=("/usr/local/bin" "/usr/bin" "/bin" "/opt/bin" "/root/bin")
    for dir in "${exec_dirs[@]}"; do
        [ -f "$dir/pf" ] && grep -q "xwPF" "$dir/pf" 2>/dev/null && rm -f "$dir/pf"
        [ -L "$dir/pf" ] && rm -f "$dir/pf"
    done
}

cleanup_files_by_paths() {
    for path in "$@"; do
        if [ -f "$path" ]; then
            rm -f "$path"
        elif [ -d "$path" ]; then
            rm -rf "$path"
        fi
    done
}

cleanup_files_by_pattern() {
    local pattern="$1"
    local search_dirs="${2:-/}"

    IFS=' ' read -ra dirs_array <<< "$search_dirs"
    for dir in "${dirs_array[@]}"; do
        [ -d "$dir" ] && find "$dir" -name "*${pattern}*" -type f 2>/dev/null | while read -r file; do
            [ -f "$file" ] && rm -f "$file"
        done &
    done
    wait
}

smart_display_target() {
    local target="$1"

    if [[ "$target" == *","* ]]; then
        IFS=',' read -ra addresses <<< "$target"
        local display_addresses=()

        for addr in "${addresses[@]}"; do
            addr=$(echo "$addr" | xargs)  # 去除空格
            local display_addr="$addr"

            if [[ "$addr" == "127.0.0.1" ]] || [[ "$addr" == "localhost" ]]; then
                local public_ipv4=$(get_public_ip ipv4)
                if [ -n "$public_ipv4" ]; then
                    display_addr="$public_ipv4"
                fi
            elif [[ "$addr" == "::1" ]]; then
                local public_ipv6=$(get_public_ip ipv6)
                if [ -n "$public_ipv6" ]; then
                    display_addr="$public_ipv6"
                fi
            fi

            display_addresses+=("$display_addr")
        done

        local result=""
        for i in "${!display_addresses[@]}"; do
            if [ $i -gt 0 ]; then
                result="$result,"
            fi
            result="$result${display_addresses[i]}"
        done
        echo "$result"
    else
        if [[ "$target" == "127.0.0.1" ]] || [[ "$target" == "localhost" ]]; then
            local public_ipv4=$(get_public_ip ipv4)
            if [ -n "$public_ipv4" ]; then
                echo "$public_ipv4"
            else
                echo "$target"
            fi
        elif [[ "$target" == "::1" ]]; then
            local public_ipv6=$(get_public_ip ipv6)
            if [ -n "$public_ipv6" ]; then
                echo "$public_ipv6"
            else
                echo "$target"
            fi
        else
            echo "$target"
        fi
    fi
}

# 显示简要状态信息（避免网络请求）
show_brief_status() {
    echo ""
    echo -e "${BLUE}=== 当前状态 ===${NC}"

    if [ ! -f "${REALM_PATH}" ] || [ ! -x "${REALM_PATH}" ]; then
        echo -e " Realm状态：${RED} 未安装 ${NC}"
        echo -e "${YELLOW}请选择 1. 安装(更新)程序,脚本 ${NC}"
        return
    fi

    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${YELLOW}=== 配置缺失 ===${NC}"
        echo -e "${BLUE}Realm 已安装但配置缺失，请运行 安装配置/添加配置 来初始化配置${NC}"
        return
    fi

    local has_rules=false
    local enabled_count=0
    local disabled_count=0
    if [ -d "$RULES_DIR" ]; then
        for rule_file in "${RULES_DIR}"/rule-*.conf; do
            if [ -f "$rule_file" ]; then
                if read_rule_file "$rule_file"; then
                    if [ "$ENABLED" = "true" ]; then
                        has_rules=true
                        enabled_count=$((enabled_count + 1))
                    else
                        disabled_count=$((disabled_count + 1))
                    fi
                fi
            fi
        done
    fi

    local status=$(svc_status_text)
    local total_count=$((enabled_count + disabled_count))
    if [ "$status" = "active" ]; then
        echo -e "服务状态: ${GREEN}●${NC} 运行中"
    elif [ "$total_count" -eq 0 ]; then
        echo -e "服务状态: ${RED}●${NC} 已停止（添加规则后启动）"
    else
        echo -e "服务状态: ${RED}●${NC} 已停止"
    fi

    if [ "$has_rules" = true ] || [ "$disabled_count" -gt 0 ]; then
        local total_count=$((enabled_count + disabled_count))
        echo -e "配置模式: ${GREEN}多规则模式${NC} (${GREEN}$enabled_count${NC} 启用 / ${YELLOW}$disabled_count${NC} 禁用 / 共 $total_count 个)"

        if [ "$enabled_count" -gt 0 ]; then
            local has_relay_rules=false
            local relay_count=0
            for rule_file in $(get_sorted_rule_files); do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "1" ]; then
                        if [ "$has_relay_rules" = false ]; then
                            echo -e "${GREEN}中转服务器:${NC}"
                            has_relay_rules=true
                        fi
                        relay_count=$((relay_count + 1))
                        local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                        local display_target=$(smart_display_target "$REMOTE_HOST")
                        local rule_display_name="$RULE_NAME"
                        local display_ip="${NAT_LISTEN_IP:-::}"
                        local through_display="${THROUGH_IP:-::}"
                        echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT"
                        local note_display=""
                        if [ -n "$RULE_NOTE" ]; then
                            note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                        fi
                        get_rule_status_display "$security_display" "$note_display"

                    fi
                fi
            done

            local has_exit_rules=false
            local exit_count=0
            for rule_file in $(get_sorted_rule_files); do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$ENABLED" = "true" ] && [ "$RULE_ROLE" = "2" ]; then
                        if [ "$has_exit_rules" = false ]; then
                            if [ "$has_relay_rules" = true ]; then
                                echo ""
                            fi
                            echo -e "${GREEN}服务端服务器 (双端Realm架构):${NC}"
                            has_exit_rules=true
                        fi
                        exit_count=$((exit_count + 1))
                        local security_display=$(get_security_display "$SECURITY_LEVEL" "$WS_PATH" "$WS_HOST")
                        # 服务端服务器使用FORWARD_TARGET而不是REMOTE_HOST
                        local target_host="${FORWARD_TARGET%:*}"
                        local target_port="${FORWARD_TARGET##*:}"
                        local display_target=$(smart_display_target "$target_host")
                        local rule_display_name="$RULE_NAME"
                        local display_ip="::"
                        echo -e "  • ${GREEN}$rule_display_name${NC}: ${LISTEN_IP:-$display_ip}:$LISTEN_PORT → $display_target:$target_port"
                        local note_display=""
                        if [ -n "$RULE_NOTE" ]; then
                            note_display=" | 备注: ${GREEN}$RULE_NOTE${NC}"
                        fi
                        get_rule_status_display "$security_display" "$note_display"

                    fi
                fi
            done
        fi

        if [ "$disabled_count" -gt 0 ]; then
            echo -e "${YELLOW}禁用的规则:${NC}"
            for rule_file in $(get_sorted_rule_files); do
                if [ -f "$rule_file" ]; then
                    if read_rule_file "$rule_file" && [ "$ENABLED" = "false" ]; then
                        if [ "$RULE_ROLE" = "2" ]; then
                            local target_host="${FORWARD_TARGET%:*}"
                            local target_port="${FORWARD_TARGET##*:}"
                            local display_target=$(smart_display_target "$target_host")
                            echo -e "  • ${WHITE}$RULE_NAME${NC}: $LISTEN_PORT → $display_target:$target_port (已禁用)"
                        else
                            local display_target=$(smart_display_target "$REMOTE_HOST")
                            local through_display="${THROUGH_IP:-::}"
                            echo -e "  • ${WHITE}$RULE_NAME${NC}: $LISTEN_PORT → $through_display → $display_target:$REMOTE_PORT (已禁用)"
                        fi
                    fi
                fi
            done
        fi
    else
        echo -e "转发规则: ${YELLOW}暂无${NC} (可通过 '转发配置管理' 添加)"
    fi
    echo ""
}

get_security_display() {
    local security_level="$1"
    local ws_path="$2"
    local tls_server_name="$3"

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

get_gmt8_time() {
    TZ='GMT-8' date "$@"
}

download_failover_script() {
    local script_url="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwFailover.sh"
    local target_path="/etc/realm/xwFailover.sh"

    _update_sub_script "$script_url" "$target_path" "故障转移脚本"
}

download_speedtest_script() {
    local script_url="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/speedtest.sh"
    local target_path="/etc/realm/speedtest.sh"

    _update_sub_script "$script_url" "$target_path" "测速脚本"
}
speedtest_menu() {
    local speedtest_script="/etc/realm/speedtest.sh"

    if ! download_speedtest_script; then
        echo -e "${RED}无法下载测速脚本，功能暂时不可用${NC}"
        read -p "按回车键返回主菜单..."
        return 1
    fi

    echo -e "${BLUE}启动测速工具...${NC}"
    echo ""
    bash "$speedtest_script"

    echo ""
    read -p "按回车键返回主菜单..."
}

failover_management_menu() {
    local failover_script="/etc/realm/xwFailover.sh"

    if ! download_failover_script; then
        echo -e "${RED}无法下载故障转移脚本，功能暂时不可用${NC}"
        read -p "按回车键返回主菜单..."
        return 1
    fi

    bash "$failover_script" toggle
}

port_traffic_dog_menu() {
    local script_url="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh"
    local dog_script="/usr/local/bin/port-traffic-dog.sh"

    if [[ ! -f "$dog_script" || ! -x "$dog_script" ]]; then
        echo -e "${GREEN}正在下载端口流量狗脚本...${NC}"
        mkdir -p "$(dirname "$dog_script")"
        if ! download_from_sources "$script_url" "$dog_script"; then
            echo -e "${RED}无法下载端口流量狗脚本，请检查网络连接${NC}"
            read -p "按回车键返回主菜单..."
            return 1
        fi
        chmod +x "$dog_script"
    fi

    echo -e "${BLUE}启动端口流量狗...${NC}"
    echo ""
    bash "$dog_script"
    echo ""
    read -p "按回车键返回主菜单..."
}

show_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== xwPF Realm全功能一键脚本 $SCRIPT_VERSION ===${NC}"
        echo -e "${GREEN}了解更多:${NC}https://zywe.de | ${GREEN}项目开源:${NC}https://github.com/zywe03/realm-xwPF"
        echo -e "${GREEN}一个开箱即用、轻量可靠、灵活可控的 Realm 转发管理工具${NC}"
        echo -e "${GREEN}官方realm的全部功能+故障转移 | 快捷命令: pf${NC}"

        show_brief_status

        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 安装(更新)程序,脚本"
        echo -e "${BLUE}2.${NC} 转发配置管理"
        echo -e "${GREEN}3.${NC} 重启服务"
        echo -e "${GREEN}4.${NC} 停止服务"
        echo -e "${GREEN}5.${NC} 查看日志"
        echo -e "${BLUE}6.${NC} 端口流量狗（统计端口流量）"
        echo -e "${BLUE}7.${NC} 中转网络链路测试"
        echo -e "${RED}8.${NC} 卸载服务"
        echo -e "${YELLOW}0.${NC} 退出"
        echo ""

        read -p "请输入选择 [0-8]: " choice
        echo ""

        case $choice in
            1)
                smart_install
                exit 0
                ;;
            2)
                check_dependencies
                rules_management_menu
                ;;
            3)
                check_dependencies
                service_restart
                read -p "按回车键继续..."
                ;;
            4)
                check_dependencies
                service_stop
                read -p "按回车键继续..."
                ;;
            5)
                check_dependencies
                echo -e "${YELLOW}实时查看 Realm 日志 (按 Ctrl+C 返回菜单):${NC}"
                echo ""
                svc_logs
                ;;
            6)
                port_traffic_dog_menu
                ;;
            7)
                check_dependencies
                speedtest_menu
                ;;
            8)
                check_dependencies
                uninstall_realm
                read -p "按回车键继续..."
                ;;
            0)
                echo -e "${BLUE}感谢使用xwPF 网络转发管理脚本！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-8${NC}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

cleanup_temp_files() {
    local cache_file="/tmp/realm_path_cache"
    if [ -f "$cache_file" ]; then
        local size=$(stat -c%s "$cache_file" 2>/dev/null || stat -f%z "$cache_file" 2>/dev/null || echo 0)
        if [ "$size" -gt 10485760 ]; then
            tail -c 5242880 "$cache_file" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file" 2>/dev/null
        fi
    fi

    find /tmp -name "realm_config_update_needed" -mmin +5 -delete 2>/dev/null

    find /tmp -name "*realm*" -type f -mmin +60 ! -path "*/realm/config*" ! -path "*/realm/rules*" -delete 2>/dev/null
}

main() {
    cleanup_temp_files

    detect_system

    if [ "$1" = "--generate-config-only" ]; then
        generate_realm_config
        exit 0
    elif [ "$1" = "--restart-service" ]; then
        service_restart
        exit $?
    fi

    check_root

    show_menu
}
