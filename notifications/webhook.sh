#!/bin/bash

# 网络参数：防止重复source时的readonly冲突
if [[ -z "${WEBHOOK_MAX_RETRIES:-}" ]]; then
    readonly WEBHOOK_MAX_RETRIES=2
    readonly WEBHOOK_CONNECT_TIMEOUT=5
    readonly WEBHOOK_MAX_TIMEOUT=15
fi

# 各平台text消息的payload构造与成功响应判断字段不同，集中在这里分派

webhook_is_enabled() {
    local enabled=$(jq -r '.notifications.webhook.enabled // false' "$CONFIG_FILE")
    [ "$enabled" = "true" ]
}

# 按平台构造text消息payload：用 jq -n --arg 生成，避免手搓JSON转义出非法字符串
webhook_build_payload() {
    local platform="$1"
    local message="$2"

    case "$platform" in
        feishu)
            # 飞书：msg_type/content.text 结构
            jq -nc --arg m "$message" '{msg_type: "text", content: {text: $m}}'
            ;;
        wecom|dingtalk|*)
            # 企业微信/钉钉：msgtype/text.content 结构一致
            jq -nc --arg m "$message" '{msgtype: "text", text: {content: $m}}'
            ;;
    esac
}

webhook_is_success() {
    local platform="$1"
    local response="$2"

    case "$platform" in
        feishu)
            # 飞书成功响应同时含 code:0 与 StatusCode:0（后者为兼容存量逻辑的冗余字段），两者择一即可
            echo "$response" | grep -qE '"code":0|"StatusCode":0'
            ;;
        wecom|dingtalk|*)
            # 企业微信/钉钉成功返回 errcode:0
            echo "$response" | grep -q '"errcode":0'
            ;;
    esac
}

send_webhook_message() {
    local message="$1"

    local webhook_url=$(jq -r '.notifications.webhook.webhook_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    local platform=$(jq -r '.notifications.webhook.platform // "wecom"' "$CONFIG_FILE" 2>/dev/null || echo "wecom")

    if [ -z "$webhook_url" ]; then
        log_notification "Webhook地址未配置"
        return 1
    fi

    # jq 构造 payload：保证 JSON 合法，反斜杠/引号/换行均被正确转义
    local json_data=$(webhook_build_payload "$platform" "$message")
    if [ -z "$json_data" ]; then
        log_notification "Webhook payload构造失败"
        return 1
    fi

    local retry_count=0

    # 重试机制；curl -d @- 从stdin读 payload，避免命令行参数过长被截断
    while [ $retry_count -le $WEBHOOK_MAX_RETRIES ]; do
        local response=$(printf '%s' "$json_data" | curl -s --connect-timeout $WEBHOOK_CONNECT_TIMEOUT --max-time $WEBHOOK_MAX_TIMEOUT \
            -H "Content-Type: application/json" \
            -d @- \
            "$webhook_url" 2>/dev/null)

        if webhook_is_success "$platform" "$response"; then
            if [ $retry_count -gt 0 ]; then
                log_notification "Webhook消息发送成功 (重试第${retry_count}次后成功)"
            else
                log_notification "Webhook消息发送成功"
            fi
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -le $WEBHOOK_MAX_RETRIES ]; then
            sleep 2  # 避免频繁请求被限流
        fi
    done

    log_notification "Webhook消息发送失败 (已重试${WEBHOOK_MAX_RETRIES}次)"
    return 1
}

# 标准通知接口：主脚本通过此函数调用Webhook通知
webhook_send_status_notification() {
    local status_enabled=$(jq -r '.notifications.webhook.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$status_enabled" != "true" ]; then
        log_notification "Webhook状态通知未启用"
        return 1
    fi

    local server_name=$(jq -r '.notifications.webhook.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "$(hostname)")
    local message=$(format_text_status_message "$server_name")
    if send_webhook_message "$message"; then
        log_notification "Webhook状态通知发送成功"
        return 0
    else
        log_notification "Webhook状态通知发送失败"
        return 1
    fi
}

# 向后兼容
webhook_send_status() {
    webhook_send_status_notification
}

webhook_test() {
    echo -e "${BLUE}=== 发送测试消息 ===${NC}"
    echo

    if ! webhook_is_enabled; then
        echo -e "${RED}请先配置Webhook信息${NC}"
        sleep 2
        return 1
    fi

    echo "正在发送测试消息..."

    # 使用真实状态消息测试：确保配置正确性
    if webhook_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

webhook_configure() {
    while true; do
        local status_notifications_enabled=$(jq -r '.notifications.webhook.status_notifications.enabled // false' "$CONFIG_FILE")
        local webhook_url=$(jq -r '.notifications.webhook.webhook_url // ""' "$CONFIG_FILE")
        local platform=$(jq -r '.notifications.webhook.platform // "wecom"' "$CONFIG_FILE")

        local config_status="[未配置]"
        if [ -n "$webhook_url" ] && [ "$webhook_url" != "" ] && [ "$webhook_url" != "null" ]; then
            config_status="[已配置]"
        fi

        local enable_status="[关闭]"
        if [ "$status_notifications_enabled" = "true" ]; then
            enable_status="[开启]"
        fi

        local status_interval=$(jq -r '.notifications.webhook.status_notifications.interval' "$CONFIG_FILE")

        echo -e "${BLUE}=== Webhook通知配置 ===${NC}"
        local interval_display="未设置"
        if [ -n "$status_interval" ] && [ "$status_interval" != "null" ]; then
            interval_display="每${status_interval}"
        fi
        echo -e "当前状态: ${enable_status} | ${config_status} | 平台: ${platform} | 状态通知: ${interval_display}"
        echo
        echo "1. 配置Webhook信息 (平台 + Webhook URL + 服务器名称)"
        echo "2. 通知设置管理"
        echo "3. 发送测试消息"
        echo "4. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-4]: " choice

        case $choice in
            1) webhook_configure_webhook ;;
            2) webhook_manage_settings ;;
            3) webhook_test ;;
            4) webhook_view_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

webhook_configure_webhook() {
    echo -e "${BLUE}=== 配置Webhook信息 ===${NC}"
    echo
    echo -e "${GREEN}配置步骤说明:${NC}"
    echo "1. 在群平台中添加群机器人"
    echo "2. 选择对应平台，获取机器人的Webhook URL"
    echo "3. 设置服务器名称用于标识"
    echo
    echo -e "${YELLOW}注意：请妥善保管Webhook地址，避免泄露！${NC}"
    echo

    local current_webhook=$(jq -r '.notifications.webhook.webhook_url' "$CONFIG_FILE")
    local current_server_name=$(jq -r '.notifications.webhook.server_name' "$CONFIG_FILE")
    local current_platform=$(jq -r '.notifications.webhook.platform // "wecom"' "$CONFIG_FILE")

    if [ "$current_webhook" != "" ] && [ "$current_webhook" != "null" ]; then
        # 安全显示：隐藏URL中间部分防止泄露
        local masked_webhook="${current_webhook:0:50}...${current_webhook: -20}"
        echo -e "${GREEN}当前Webhook: $masked_webhook${NC}"
    fi
    if [ "$current_server_name" != "" ] && [ "$current_server_name" != "null" ]; then
        echo -e "${GREEN}当前服务器名: $current_server_name${NC}"
    fi
    echo -e "${GREEN}当前平台: $current_platform${NC}"
    echo

    # 平台选择：不同平台的text payload结构与成功响应字段不同
    echo "请选择群机器人平台:"
    echo "1. 企业微信  2. 飞书  3. 钉钉"
    local platform_choice
    read -p "请选择(回车默认企业微信) [1-3]: " platform_choice
    case $platform_choice in
        1|"") platform="wecom" ;;
        2) platform="feishu" ;;
        3) platform="dingtalk" ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; webhook_configure_webhook; return ;;
    esac

    read -p "请输入Webhook URL: " webhook_url
    if [ -z "$webhook_url" ]; then
        echo -e "${RED}Webhook URL不能为空${NC}"
        sleep 2
        webhook_configure_webhook
        return
    fi

    # 验证Webhook URL格式：放开域名限制，只校验 https 前缀，兼容企业微信/飞书/钉钉及自建反代
    if ! [[ "$webhook_url" =~ ^https://[^[:space:]]+$ ]]; then
        echo -e "${RED}Webhook URL格式错误，必须以 https:// 开头${NC}"
        sleep 3
        webhook_configure_webhook
        return
    fi

    local default_server_name=$(hostname)
    read -r -p "请输入服务器名称 (回车默认: $default_server_name): " server_name
    if [ -z "$server_name" ]; then
        server_name="$default_server_name"
    fi

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval
    interval=$(select_notification_interval)

    # 值经 --arg 传入：server_name 等自由文本里的引号会破坏 jq 表达式
    if ! update_config --arg platform "$platform" --arg url "$webhook_url" --arg name "$server_name" --arg interval "$interval" \
        ".notifications.webhook.platform = \$platform |
        .notifications.webhook.webhook_url = \$url |
        .notifications.webhook.server_name = \$name |
        .notifications.webhook.enabled = true |
        .notifications.webhook.status_notifications.enabled = true |
        .notifications.webhook.status_notifications.interval = \$interval"; then
        echo -e "${RED}✗ 基本配置保存失败，请检查配置文件 JSON 格式和写入权限${NC}"
        return 1
    fi

    echo -e "${GREEN}基本配置保存成功！${NC}"
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    setup_webhook_notification_cron

    echo
    echo "正在发送测试通知..."

    # 配置完成后立即测试：验证配置正确性
    if webhook_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

webhook_manage_settings() {
    while true; do
        echo -e "${BLUE}=== 通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "2. 开启/关闭切换"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1) webhook_configure_interval ;;
            2) webhook_toggle_status_notifications ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

webhook_configure_interval() {
    local current_interval=$(jq -r '.notifications.webhook.status_notifications.interval' "$CONFIG_FILE")

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval_display="未设置"
    if [ -n "$current_interval" ] && [ "$current_interval" != "null" ]; then
        interval_display="$current_interval"
    fi
    echo -e "当前间隔: $interval_display"
    echo
    local interval=$(select_notification_interval)

    update_config ".notifications.webhook.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    setup_webhook_notification_cron

    sleep 2
}

webhook_toggle_status_notifications() {
    local current_status=$(jq -r '.notifications.webhook.status_notifications.enabled // false' "$CONFIG_FILE")

    if [ "$current_status" = "true" ]; then
        update_config ".notifications.webhook.status_notifications.enabled = false"
        echo -e "${GREEN}状态通知已关闭${NC}"
    else
        update_config ".notifications.webhook.status_notifications.enabled = true"
        echo -e "${GREEN}状态通知已开启${NC}"
    fi

    setup_webhook_notification_cron
    sleep 2
}

webhook_view_logs() {
    echo -e "${BLUE}=== 通知日志 ===${NC}"
    echo

    local log_file="$CONFIG_DIR/logs/notification.log"
    if [ ! -f "$log_file" ]; then
        echo -e "${YELLOW}暂无通知日志${NC}"
        sleep 2
        return
    fi

    echo "最近20条通知日志:"
    echo "────────────────────────────────────────────────────────"
    tail -n 20 "$log_file"
    echo "────────────────────────────────────────────────────────"
    echo
    read -p "按回车键返回..."
}
