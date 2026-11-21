#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="1.4.4"
readonly SCRIPT_NAME="端口流量狗"
readonly SCRIPT_PATH="$(realpath "$0")"
readonly CONFIG_DIR="/etc/port-traffic-dog"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly LOG_FILE="$CONFIG_DIR/logs/traffic.log"
readonly TRAFFIC_DATA_FILE="$CONFIG_DIR/traffic_data.json"
# 伪端口 00 走 /proc/net/dev 增量，无 nftables 规则
readonly VPS_PORT_ID="00"
readonly VPS_DATA_FILE="$CONFIG_DIR/vps_traffic.json"

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'
readonly SHORT_CONNECT_TIMEOUT=5
readonly SHORT_MAX_TIMEOUT=7
readonly SCRIPT_URL="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh"
readonly SHORTCUT_COMMAND="dog"

detect_system() {
    if [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release 2>/dev/null; then
        echo "ubuntu"
        return
    fi

    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi

    echo "unknown"
}

install_missing_tools() {
    local missing_tools=("$@")
    local system_type=$(detect_system)
    local pkg_cmd
    case $system_type in
        "ubuntu") pkg_cmd="apt" ;;
        "debian") pkg_cmd="apt-get" ;;
        *)
            echo -e "${RED}不支持的系统类型: $system_type${NC}"
            echo "支持的系统: Ubuntu, Debian"
            echo "请手动安装: ${missing_tools[*]}"
            exit 1
            ;;
    esac

    echo -e "${YELLOW}检测到缺少工具: ${missing_tools[*]}${NC}"
    echo "正在自动安装..."

    $pkg_cmd update -qq
    for tool in "${missing_tools[@]}"; do
        case $tool in
            "nft") $pkg_cmd install -y nftables ;;
            "tc") $pkg_cmd install -y iproute2 ;;
            "ss") $pkg_cmd install -y iproute2 ;;
            "jq") $pkg_cmd install -y jq ;;
            "awk") $pkg_cmd install -y gawk ;;
            "bc") $pkg_cmd install -y bc ;;
            "cron")
                $pkg_cmd install -y cron
                systemctl enable cron 2>/dev/null || true
                systemctl start cron 2>/dev/null || true
                ;;
            *) $pkg_cmd install -y "$tool" ;;
        esac
    done

    echo -e "${GREEN}依赖工具安装完成${NC}"
}

check_dependencies() {
    local silent_mode=${1:-false}
    local missing_tools=()
    local required_tools=("nft" "tc" "ss" "jq" "awk" "bc" "unzip" "cron")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        install_missing_tools "${missing_tools[@]}"

        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                still_missing+=("$tool")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            echo -e "${RED}安装失败，仍缺少工具: ${still_missing[*]}${NC}"
            echo "请手动安装后重试"
            exit 1
        fi
    fi

    if [ "$silent_mode" != "true" ]; then
        echo -e "${GREEN}依赖检查通过${NC}"
    fi

    setup_script_permissions
    setup_cron_environment
    local active_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${active_ports[@]}"; do
        setup_port_auto_reset_cron "$port" >/dev/null 2>&1 || true
    done
}

setup_script_permissions() {
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi

    if [ -f "/usr/local/bin/port-traffic-dog.sh" ]; then
        chmod +x "/usr/local/bin/port-traffic-dog.sh" 2>/dev/null || true
    fi
}

setup_cron_environment() {
    # cron 环境补全 PATH；@reboot 恢复重启丢失的 nftables 监控规则
    local current_cron=$(crontab -l 2>/dev/null || true)
    local temp_cron=$(mktemp)
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > "$temp_cron"
    echo "$current_cron" | grep -v "^PATH=" | grep -v "# 端口流量狗开机自恢复" >> "$temp_cron" || true
    echo "@reboot $SCRIPT_PATH --restore-monitoring >/dev/null 2>&1  # 端口流量狗开机自恢复" >> "$temp_cron"
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限运行${NC}"
        exit 1
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR" "$(dirname "$LOG_FILE")"

    download_notification_modules >/dev/null 2>&1 || true

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "global": {
    "billing_mode": "double"
  },
  "ports": {},
  "nftables": {
    "table_name": "port_traffic_monitor",
    "family": "inet"
  },
  "notifications": {
    "telegram": {
      "enabled": false,
      "bot_token": "",
      "chat_id": "",
      "api_host": "https://api.telegram.org",
      "server_name": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    },
    "webhook": {
      "enabled": false,
      "platform": "wecom",
      "webhook_url": "",
      "server_name": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    }
  }
}
EOF
    fi

    setup_exit_hooks
    migrate_ports_schema
    migrate_notifications_schema
    ensure_vps_port_config
    setup_expiry_check_cron
    ensure_monitoring_state
}

ensure_vps_port_config() {
    if ! jq -e --arg vps "$VPS_PORT_ID" '.ports[$vps]' "$CONFIG_FILE" >/dev/null 2>&1; then
        update_config --arg vps "$VPS_PORT_ID" --arg now "$(get_beijing_time -Iseconds)" \
            '.ports[$vps] = {
                "name": "整机流量",
                "enabled": true,
                "billing_mode": "double",
                "bandwidth_limit": {"enabled": false, "rate": "unlimited"},
                "quota": {"enabled": true, "monthly_limit": "unlimited"},
                "remark": "",
                "created_at": $now
            }'
        log_notification "整机流量监控已启用"
    fi
    setup_vps_collect_cron
}

setup_expiry_check_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗截止日期检查" > "$temp_cron" || true
    echo "5 0 * * * $SCRIPT_PATH --check-expiry >/dev/null 2>&1  # 端口流量狗截止日期检查" >> "$temp_cron"
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"
}

remove_expiry_check_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗截止日期检查" > "$temp_cron" || true
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"
}

setup_vps_collect_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗整机流量采集" > "$temp_cron" || true
    echo "* * * * * $SCRIPT_PATH --collect-vps-traffic >/dev/null 2>&1  # 端口流量狗整机流量采集" >> "$temp_cron"
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_vps_collect_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗整机流量采集" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

init_nftables() {
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    NFT_TABLE_CACHE=""
    # 表与链已就绪时直接返回，避免无谓触发 nft add
    local existing
    existing=$(nft list table $family $table_name 2>/dev/null || true)
    if [ -n "$existing" ] \
        && grep -q "^[[:space:]]*chain input {" <<< "$existing" \
        && grep -q "^[[:space:]]*chain output {" <<< "$existing" \
        && grep -q "^[[:space:]]*chain forward {" <<< "$existing"; then
        NFT_TABLE_CACHE="$existing"
        return 0
    fi

    nft add table $family $table_name 2>/dev/null || true
    nft add chain $family $table_name input { type filter hook input priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name output { type filter hook output priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name forward { type filter hook forward priority 0\; } 2>/dev/null || true
}

format_bytes() {
    local bytes=$1

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi

    if [ $bytes -ge 1073741824 ]; then
        local gb=$(echo "scale=2; $bytes / 1073741824" | bc)
        echo "${gb}GB"
    elif [ $bytes -ge 1048576 ]; then
        local mb=$(echo "scale=2; $bytes / 1048576" | bc)
        echo "${mb}MB"
    elif [ $bytes -ge 1024 ]; then
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

get_beijing_time() {
    TZ='Asia/Shanghai' date "$@"
}

# jq 失败时不能把空临时文件 mv 成配置：调用点在 if / || 里时 set -e 被抑制，必须显式检查返回码
update_config() {
    (
        local tmp_file
        exec 7>"${CONFIG_FILE}.lock" || return 1
        flock -x 7 || return 1
        tmp_file=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1

        if jq -e "$@" "$CONFIG_FILE" > "$tmp_file" && [ -s "$tmp_file" ] &&
           mv -fT -- "$tmp_file" "$CONFIG_FILE"; then
            return 0
        fi
        rm -f -- "$tmp_file"
        return 1
    )
}

get_port_display_name() {
    local port=$1
    if [ "$port" = "$VPS_PORT_ID" ]; then
        echo "整机流量"
    elif is_port_group "$port"; then
        echo "端口组 $port"
    else
        echo "端口 $port"
    fi
}

show_port_list() {
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        return 1
    fi

    echo "当前监控的端口:"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). $(get_port_display_name "$port") $status_label"
    done
    echo "0. 返回上级菜单"
    return 0
}

parse_multi_choice_input() {
    local input="$1"
    local max_choice="$2"
    local -n result_array=$3

    IFS=',' read -ra CHOICES <<< "$input"
    result_array=()

    for choice in "${CHOICES[@]}"; do
        choice=$(echo "$choice" | tr -d ' ')
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            result_array+=("$choice")
        else
            echo -e "${RED}无效选择: $choice${NC}"
        fi
    done
}

read_user_choice() {
    local parent_menu="$1"
    local prompt="$2"
    local -n _ruc_choice=$3

    read -p "$prompt" _ruc_choice
    _ruc_choice=$(echo "$_ruc_choice" | tr -d ' ')
    if [ "$_ruc_choice" = "0" ]; then
        "$parent_menu"
        return 1
    fi
    return 0
}

parse_comma_separated_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra result_array <<< "$input"

    for i in "${!result_array[@]}"; do
        result_array[$i]=$(echo "${result_array[$i]}" | tr -d ' ')
    done
}

parse_port_range_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra PARTS <<< "$input"
    result_array=()

    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | tr -d ' ')

        if is_port_range "$part"; then
            local start_port=$(echo "$part" | cut -d'-' -f1)
            local end_port=$(echo "$part" | cut -d'-' -f2)

            if [ "$start_port" -gt "$end_port" ]; then
                echo -e "${RED}错误：端口段 $part 起始端口大于结束端口${NC}"
                return 1
            fi

            if [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ] || [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
                echo -e "${RED}错误：端口段 $part 包含无效端口，必须在1-65535范围内${NC}"
                return 1
            fi

            result_array+=("$part")

        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -ge 1 ] && [ "$part" -le 65535 ]; then
                result_array+=("$part")
            else
                echo -e "${RED}错误：端口号 $part 无效，必须是1-65535之间的数字${NC}"
                return 1
            fi
        else
            echo -e "${RED}错误：无效的端口格式 $part${NC}"
            return 1
        fi
    done

    return 0
}

expand_single_value_to_array() {
    local -n source_array=$1
    local target_size=$2

    if [ ${#source_array[@]} -eq 1 ]; then
        local single_value="${source_array[0]}"
        source_array=()
        for ((i=0; i<target_size; i++)); do
            source_array+=("$single_value")
        done
    fi
}

get_beijing_month_year() {
    local current_day=$(TZ='Asia/Shanghai' date +%d | sed 's/^0//')
    local current_month=$(TZ='Asia/Shanghai' date +%m | sed 's/^0//')
    local current_year=$(TZ='Asia/Shanghai' date +%Y)
    echo "$current_day $current_month $current_year"
}

# 任何写操作后必须清空快照缓存；MISSING 标记表不存在
get_nft_table_dump() {
    if [ -z "${NFT_TABLE_CACHE:-}" ]; then
        local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
        local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
        NFT_TABLE_CACHE=$(nft list table $family $table_name 2>/dev/null || true)
        [ -z "$NFT_TABLE_CACHE" ] && NFT_TABLE_CACHE="MISSING"
    fi
    [ "$NFT_TABLE_CACHE" != "MISSING" ]
}

nft_counter_exists() {
    get_nft_table_dump || return 1
    grep -q "^[[:space:]]*counter $1 {" <<< "$NFT_TABLE_CACHE"
}

get_nftables_counter_data() {
    local port=$1
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    local input_bytes=0
    local output_bytes=0

    if [ "$port" = "$VPS_PORT_ID" ]; then
        # 整机伪端口按计费口径预乘（双向乘2/单向乘1）
        local vps_raw=($(get_vps_monthly_raw))
        local vps_rx=${vps_raw[0]:-0}
        local vps_tx=${vps_raw[1]:-0}
        if [ "$billing_mode" = "double" ]; then
            input_bytes=$((vps_rx * 2))
            output_bytes=$((vps_tx * 2))
        else
            input_bytes=0
            output_bytes=$vps_tx
        fi
        echo "$input_bytes $output_bytes"
        return 0
    fi

    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    # 兼容 nft>=1.0.x 单行与旧版分行格式；缺失按 0
    if get_nft_table_dump; then
        local parsed
        parsed=$(printf '%s\n' "$NFT_TABLE_CACHE" | awk -v in_name="$in_name" -v out_name="$out_name" '
            $1 == "counter" { cur = $2; next }
            $1 == "quota" || $1 == "chain" || $1 == "table" || $1 == "set" || $1 == "map" { cur = ""; next }
            $1 == "}" { cur = ""; next }
            $1 == "packets" && $3 == "bytes" {
                if (cur == in_name) ib = $4
                else if (cur == out_name) ob = $4
                next
            }
            $1 == "bytes" && $3 == "bytes" {
                if (cur == in_name) ib = $2
                else if (cur == out_name) ob = $2
            }
            END {
                # 保持字符串透传，数值运算会导致 awk 采用科学计数法丢失大数值精度
                print (ib == "" ? 0 : ib), (ob == "" ? 0 : ob)
            }')
        read -r input_bytes output_bytes <<< "$parsed"
    fi

    # 单向口径不返回 in 计数器
    [ "$billing_mode" != "double" ] && input_bytes=0
    echo "$input_bytes $output_bytes"
}

save_traffic_data() {
    local temp_file=$(mktemp)
    local active_ports=($(get_active_ports 2>/dev/null || true))

    # 伪端口 00 数据存 vps_traffic.json，不写入 nft 备份
    local ports_for_backup=()
    for port in "${active_ports[@]}"; do
        [ "$port" = "$VPS_PORT_ID" ] && continue
        ports_for_backup+=("$port")
    done

    if [ ${#ports_for_backup[@]} -eq 0 ]; then
        rm -f "$TRAFFIC_DATA_FILE"
        rm -f "$temp_file"
        return 0
    fi

    echo '{}' > "$temp_file"

    for port in "${ports_for_backup[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local current_input=${traffic_data[0]}
        local current_output=${traffic_data[1]}

        if [ $current_input -gt 0 ] || [ $current_output -gt 0 ]; then
            jq ".\"$port\" = {\"input\": $current_input, \"output\": $current_output, \"backup_time\": \"$(get_beijing_time -Iseconds)\"}" \
                "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        fi
    done

    mv "$temp_file" "$TRAFFIC_DATA_FILE"
}

setup_exit_hooks() {
    trap 'save_traffic_data_on_exit' EXIT
    trap 'save_traffic_data_on_exit; exit 1' INT TERM
}

save_traffic_data_on_exit() {
    save_traffic_data >/dev/null 2>&1
}

restore_monitoring_if_needed() {
    local active_ports=($(get_active_ports 2>/dev/null || true))

    # 排除伪端口 00，防止误判触发全量规则重建
    local real_ports=()
    for port in "${active_ports[@]}"; do
        [ "$port" = "$VPS_PORT_ID" ] && continue
        real_ports+=("$port")
    done

    if [ ${#real_ports[@]} -eq 0 ]; then
        return 0
    fi

    # 单次表快照校验链与规则完整性
    local need_restore=false
    if ! get_nft_table_dump; then
        need_restore=true
    else
        local port
        for port in "${real_ports[@]}"; do
            local out_name=$(get_counter_name "$(get_counter_key "$port")" out)

            if ! grep -q "^[[:space:]]*counter $out_name {" <<< "$NFT_TABLE_CACHE" \
                || ! grep -q "counter name \"$out_name\"" <<< "$NFT_TABLE_CACHE"; then
                need_restore=true
                break
            fi
        done
    fi

    if [ "$need_restore" = "true" ]; then
        restore_traffic_data_from_backup
        restore_all_monitoring_rules >/dev/null 2>&1 || true
    fi
}

restore_traffic_data_from_backup() {
    if [ ! -f "$TRAFFIC_DATA_FILE" ]; then
        return 0
    fi

    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local backup_ports=($(jq -r 'keys[]' "$TRAFFIC_DATA_FILE" 2>/dev/null || true))

    for port in "${backup_ports[@]}"; do
        [ "$port" = "$VPS_PORT_ID" ] && continue
        jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1 || continue

        local backup_input=$(jq -r ".\"$port\".input // 0" "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")
        local backup_output=$(jq -r ".\"$port\".output // 0" "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")

        if [ $backup_input -gt 0 ] || [ $backup_output -gt 0 ]; then
            restore_counter_value "$port" "$backup_input" "$backup_output"
        fi
    done

    rm -f "$TRAFFIC_DATA_FILE"
}

restore_counter_value() {
    local port=$1
    local target_input=$2
    local target_output=$3

    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    # 内核计数器优先保留；nftables 0.9.3 语法不兼容带花括号的初值
    if [ "$billing_mode" = "double" ]; then
        if ! nft_counter_exists "$in_name" \
            && ! nft add counter $family $table_name "$in_name" packets 0 bytes $target_input 2>/dev/null; then
            log_notification "恢复计数器 $in_name 失败 (端口 $port)"
        fi
    fi
    if ! nft_counter_exists "$out_name" \
        && ! nft add counter $family $table_name "$out_name" packets 0 bytes $target_output 2>/dev/null; then
        log_notification "恢复计数器 $out_name 失败 (端口 $port)"
    fi
}

restore_all_monitoring_rules() {
    local active_ports=($(get_active_ports))

    for port in "${active_ports[@]}"; do
        if [ "$port" = "$VPS_PORT_ID" ]; then
            local vps_limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
            local vps_rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
            if [ "$vps_limit_enabled" = "true" ] && [ "$vps_rate_limit" != "unlimited" ]; then
                local vps_tc_limit=$(convert_bandwidth_to_tc "$vps_rate_limit")
                if [ -n "$vps_tc_limit" ]; then
                    apply_tc_limit "$port" "$vps_tc_limit" || true
                fi
            fi
            setup_port_auto_reset_cron "$port"
            continue
        fi

        add_nftables_rules "$port"

        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$monthly_limit"
        fi

        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit" || true
            fi
        fi

        check_and_apply_expiry "$port"

        setup_port_auto_reset_cron "$port"
    done
}

calculate_total_traffic() {
    local input_bytes=$1
    local output_bytes=$2
    local billing_mode=${3:-"double"}
    case $billing_mode in
        "double")
            echo $((input_bytes + output_bytes))
            ;;
        "single"|*)
            echo $output_bytes
            ;;
    esac
}

get_port_status_label() {
    local port=$1
    local port_config=$(jq -r ".ports.\"$port\"" "$CONFIG_FILE" 2>/dev/null)

    # 空 remark 注入 0x01 占位，防止 IFS 空白折叠吞掉字段
    local fields
    fields=$(printf '%s' "$port_config" | jq -r '[
        "S",
        (.remark // "" | if . == "" then "\u0001" else . end),
        .billing_mode // "double",
        (.bandwidth_limit.enabled // false),
        .bandwidth_limit.rate // "unlimited",
        (.quota.enabled // true),
        .quota.monthly_limit // "unlimited",
        (.quota.reset_day // "null"),
        (.expiry.expire_date // null)
    ] | @tsv' 2>/dev/null) || fields=""

    local remark billing_mode limit_enabled rate_limit quota_enabled monthly_limit reset_day_raw expire_date_raw
    if [ -n "$fields" ]; then
        IFS=$'\t' read -r _sentinel remark billing_mode limit_enabled rate_limit quota_enabled monthly_limit reset_day_raw expire_date_raw <<< "$fields"
        [ "$remark" = $'\x01' ] && remark=""
    else
        remark=""; billing_mode="double"; limit_enabled="false"
        rate_limit="unlimited"; quota_enabled="true"; monthly_limit="unlimited"; reset_day_raw="null"; expire_date_raw="null"
    fi
    local reset_day="null"
    
    if [ "$monthly_limit" != "unlimited" ] && [ "$reset_day_raw" != "null" ]; then
        reset_day="${reset_day_raw:-1}"  # 未配置时默认为1
    fi

    local status_tags=()

    if [ -n "$remark" ] && [ "$remark" != "null" ] && [ "$remark" != "" ]; then
        status_tags+=("[备注:$remark]")
    fi

    if [ "$quota_enabled" = "true" ]; then
        if [ "$monthly_limit" != "unlimited" ]; then
            local current_usage=$(get_port_monthly_usage "$port")
            local limit_bytes=$(parse_size_to_bytes "$monthly_limit")

            local quota_display="$monthly_limit"
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向${quota_display}]")
            else
                status_tags+=("[单向${quota_display}]")
            fi

            if [ "$reset_day" != "null" ]; then
                local time_info=($(get_beijing_month_year))
                local current_day=${time_info[0]}
                local current_month=${time_info[1]}
                local next_month=$current_month

                if [ $current_day -ge $reset_day ]; then
                    next_month=$((current_month + 1))
                    if [ $next_month -gt 12 ]; then
                        next_month=1
                    fi
                fi

                status_tags+=("[${next_month}月${reset_day}日重置]")
            fi

            if [ -n "$limit_bytes" ] && [ "$limit_bytes" -gt 0 ] && [ "$current_usage" -ge "$limit_bytes" ]; then
                status_tags+=("[已超限]")
            fi
        else
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向无限制]")
            else
                status_tags+=("[单向无限制]")
            fi
        fi
    fi

    if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
        status_tags+=("[限制带宽${rate_limit}]")
    fi

    if [ "$expire_date_raw" != "null" ] && [ -n "$expire_date_raw" ]; then
        local today_bj
        today_bj=$(get_beijing_time '+%Y-%m-%d')
        if [[ "$today_bj" > "$expire_date_raw" || "$today_bj" == "$expire_date_raw" ]]; then
            status_tags+=("[已截止]")
        else
            status_tags+=("[截止${expire_date_raw}]")
        fi
    fi

    if [ ${#status_tags[@]} -gt 0 ]; then
        printf '%s' "${status_tags[@]}"
        echo
    fi
}

get_port_monthly_usage() {
    local port=$1
    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode"
}

validate_bandwidth() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+kbps$ ]] || [[ "$lower_input" =~ ^[0-9]+mbps$ ]] || [[ "$lower_input" =~ ^[0-9]+gbps$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_quota() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+(mb|gb|tb|m|g|t)$ ]]; then
        return 0
    else
        return 1
    fi
}

parse_size_to_bytes() {
    local size_str=$1
    local number=$(echo "$size_str" | grep -o '^[0-9]\+' || true)
    local unit=$(echo "$size_str" | grep -o '[A-Za-z]\+$' | tr '[:lower:]' '[:upper:]' || true)

    [ -z "$number" ] && echo "0" && return 0

    case $unit in
        "MB"|"M") echo $((number * 1048576)) ;;
        "GB"|"G") echo $((number * 1073741824)) ;;
        "TB"|"T") echo $((number * 1099511627776)) ;;
        *) echo "0" ;;
    esac
}

get_active_ports() {
    jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n
}

get_monitored_ports() {
    jq -r --arg vps "$VPS_PORT_ID" '.ports | keys[] | select(. != $vps)' "$CONFIG_FILE" 2>/dev/null | sort -n
}

# 排除 ifb 避免与物理网卡入向镜像重复计数
list_vps_interfaces() {
    list_shaping_interfaces | grep -v "^ifb" || true
}

vps_lock() {
    local timeout="${1:-}"
    mkdir -p "$CONFIG_DIR"
    exec 8>"$CONFIG_DIR/.vps.lock"
    if [ -n "$timeout" ]; then
        flock -w "$timeout" 8
    else
        flock 8
    fi
}

vps_unlock() {
    flock -u 8 2>/dev/null || true
    exec 8>&- || true
}

vps_read_data() {
    cat "$VPS_DATA_FILE" 2>/dev/null || echo '{}'
}

vps_write_data() {
    local data="$1"
    local temp_file=$(mktemp)
    printf '%s' "$data" > "$temp_file"
    mv "$temp_file" "$VPS_DATA_FILE"
}

vps_read_iface_raw() {
    local iface=$1
    awk -v dev="$iface:" '$1 == dev {print $2, $10}' /proc/net/dev 2>/dev/null
}

# /proc/net/dev 增量采集并累加至 monthly；lifetime_raw 为不随重置清零的基准
collect_vps_traffic() {
    command -v jq >/dev/null 2>&1 || return 0

    local ifaces=($(list_vps_interfaces 2>/dev/null || true))
    if [ ${#ifaces[@]} -eq 0 ]; then
        return 0
    fi

    local current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
    local now=$(get_beijing_time +%s)

    # 尝试加锁 2 秒，防 cron/推送并发持锁阻塞交互
    vps_lock 2 || return 0

    local data=$(vps_read_data)
    local last_boot_id=$(printf '%s' "$data" | jq -r '.lifetime_raw.boot_id // ""' 2>/dev/null || echo "")
    local file_exists=false
    [ -f "$VPS_DATA_FILE" ] && file_exists=true

    local new_data="$data"
    local iface raw_line current_rx current_tx last_rx last_tx delta_rx delta_tx

    for iface in "${ifaces[@]}"; do
        raw_line=$(vps_read_iface_raw "$iface")
        # 网卡热插拔下线时跳过
        [ -z "$raw_line" ] && continue

        current_rx=$(echo "$raw_line" | awk '{print $1}')
        current_tx=$(echo "$raw_line" | awk '{print $2}')
        [[ "$current_rx" =~ ^[0-9]+$ ]] || continue
        [[ "$current_tx" =~ ^[0-9]+$ ]] || continue

        last_rx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        last_tx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)

        if [ "$file_exists" = "false" ]; then
            # 首次采集仅记录基准
            delta_rx=0
            delta_tx=0
        elif [ "$last_boot_id" != "$current_boot_id" ]; then
            # boot_id 变更表示宿主机重启，开机至今计数全量计入本月
            delta_rx=$current_rx
            delta_tx=$current_tx
        elif [ "$current_rx" -lt "$last_rx" ] || [ "$current_tx" -lt "$last_tx" ]; then
            # 未重启但计数回退判定为网卡重置，重校准基准
            log_notification "整机流量：网卡 $iface 计数器未重启发生回退（疑似NIC重建），已按当前值校准"
            delta_rx=$current_rx
            delta_tx=$current_tx
        else
            delta_rx=$((current_rx - last_rx))
            delta_tx=$((current_tx - last_tx))
        fi

        new_data=$(printf '%s' "$new_data" | jq -c --arg i "$iface" \
            --argjson lrx "$current_rx" --argjson ltx "$current_tx" \
            --argjson drx "$delta_rx" --argjson dtx "$delta_tx" '
            .lifetime_raw.ifaces[$i] = {"rx_bytes": $lrx, "tx_bytes": $ltx} |
            .monthly.ifaces[$i] = ((.monthly.ifaces[$i] // {"rx_bytes": 0, "tx_bytes": 0}) |
                .rx_bytes += $drx | .tx_bytes += $dtx)' 2>/dev/null) || new_data="$data"
    done

    new_data=$(printf '%s' "$new_data" | jq -c --arg boot "$current_boot_id" --argjson now "$now" '
        .lifetime_raw.boot_id = $boot |
        .lifetime_raw.updated_at = $now |
        .monthly.reset_at = (.monthly.reset_at // $now)' 2>/dev/null) || new_data=""

    # jq 成功后原子 mv 写入，防读取半包数据
    if [ -n "$new_data" ]; then
        vps_write_data "$new_data"
    else
        log_notification "整机流量：增量计算失败，本轮数据未落盘"
    fi

    vps_unlock
}

get_vps_monthly_raw() {
    local data=$(vps_read_data)
    local total_rx=$(printf '%s' "$data" | jq -r '[.monthly.ifaces[]?.rx_bytes] | add // 0' 2>/dev/null || echo 0)
    local total_tx=$(printf '%s' "$data" | jq -r '[.monthly.ifaces[]?.tx_bytes] | add // 0' 2>/dev/null || echo 0)
    [[ "$total_rx" =~ ^[0-9]+$ ]] || total_rx=0
    [[ "$total_tx" =~ ^[0-9]+$ ]] || total_tx=0
    echo "$total_rx $total_tx"
}

get_vps_interface_names() {
    local data=$(vps_read_data)
    printf '%s' "$data" | jq -r '.monthly.ifaces // {} | keys[]' 2>/dev/null || true
}

is_port_range() {
    local port=$1
    [[ "$port" =~ ^[0-9]+-[0-9]+$ ]]
}

is_port_group() {
    [[ "$1" == *,* ]]
}

split_port_range() {
    local range=$1 start end
    IFS='-' read -r start end <<< "$range"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 1
    echo "$start $end"
}

validate_port_spec() {
    local spec=$1
    if is_port_range "$spec"; then
        local se
        se=$(split_port_range "$spec") || { echo -e "${RED}错误：无效端口段 $spec${NC}" >&2; return 1; }
        local start=${se% *}
        local end=${se#* }
        if [ "$start" -gt "$end" ]; then
            echo -e "${RED}错误：端口段 $spec 起始大于结束${NC}" >&2; return 1
        fi
        if [ "$start" -lt 1 ] || [ "$end" -gt 65535 ]; then
            echo -e "${RED}错误：端口段 $spec 越界，需在1-65535${NC}" >&2; return 1
        fi
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        if [ "$spec" -lt 1 ] || [ "$spec" -gt 65535 ]; then
            echo -e "${RED}错误：端口号 $spec 无效，需1-65535${NC}" >&2; return 1
        fi
    else
        echo -e "${RED}错误：无效端口格式 $spec${NC}" >&2; return 1
    fi
    return 0
}

# 区间重叠校验：防止同一端口被两套规则重复统计
check_units_overlap() {
    local intervals=() uk s e
    for uk in "$@"; do
        while read -r s e; do
            [ -n "$s" ] && intervals+=("$s $e")
        done < <(expand_unit_intervals "$uk")
    done

    local i j sa ea sb eb
    for ((i=0; i<${#intervals[@]}; i++)); do
        sa=${intervals[$i]% *}
        ea=${intervals[$i]#* }
        for ((j=i+1; j<${#intervals[@]}; j++)); do
            sb=${intervals[$j]% *}
            eb=${intervals[$j]#* }
            if [ "$sa" -le "$eb" ] && [ "$sb" -le "$ea" ]; then
                echo -e "${RED}错误：端口区间 $sa-$ea 与 $sb-$eb 重叠${NC}" >&2
                return 1
            fi
        done
    done
    return 0
}

normalize_unit_key() {
    local input=$1
    input=$(printf '%s' "$input" | tr -d ' ')

    local members=()
    IFS=',' read -ra members <<< "$input"
    local -A seen=()
    local clean=()
    local m
    for m in "${members[@]}"; do
        [ -z "$m" ] && { echo -e "${RED}错误：空端口项${NC}" >&2; return 1; }
        validate_port_spec "$m" || return 1
        # 去前导零归一化 key，避免重复建表
        if is_port_range "$m"; then
            local se start end
            se=$(split_port_range "$m")
            start=$((10#${se% *}))
            end=$((10#${se#* }))
            m="$start-$end"
        else
            m=$((10#$m))
        fi
        if [ -z "${seen[$m]:-}" ]; then
            seen[$m]=1
            clean+=("$m")
        fi
    done
    if [ ${#clean[@]} -eq 0 ]; then
        echo -e "${RED}错误：空单元${NC}" >&2; return 1
    fi
    if [ ${#clean[@]} -eq 1 ]; then
        echo "${clean[0]}"
        return 0
    fi
    local sorted
    sorted=$(printf '%s\n' "${clean[@]}" | awk -F'-' '
        { if (NF==2) k=$1; else k=$0; print k"\t"$0 }
    ' | sort -n -k1,1 | cut -f2- | paste -sd,)
    echo "$sorted"
}

expand_unit_intervals() {
    local key=$1
    local members=()
    IFS=',' read -ra members <<< "$key"
    local m se start end
    for m in "${members[@]}"; do
        [ -z "$m" ] && continue
        if is_port_range "$m"; then
            se=$(split_port_range "$m") || continue
            echo "${se% *} ${se#* }"
        else
            echo "$m $m"
        fi
    done
}

parse_monitor_units() {
    local input=$1
    local -n _pmu_units=$2

    _pmu_units=()
    # mapfile -d 保留末尾分号空字段以严格拦截非法输入
    local raw_units=()
    mapfile -d ';' -t raw_units <<< "$input"
    # 去除 here-string 附加的换行符
    local i
    for ((i=0; i<${#raw_units[@]}; i++)); do
        raw_units[$i]="${raw_units[$i]%$'\n'}"
    done

    local unit_keys=()
    local ru
    for ru in "${raw_units[@]}"; do
        if [ -z "$(printf '%s' "$ru" | tr -d ' ')" ]; then
            echo -e "${RED}错误：空监控项${NC}" >&2; return 1
        fi
        local key
        key=$(normalize_unit_key "$ru") || return 1
        unit_keys+=("$key")
    done

    if [ ${#unit_keys[@]} -eq 0 ]; then
        echo -e "${RED}错误：没有有效的监控项${NC}" >&2; return 1
    fi

    local -A uk_seen=()
    local k
    for k in "${unit_keys[@]}"; do
        if [ -n "${uk_seen[$k]:-}" ]; then
            echo -e "${RED}错误：监控项 $k 重复${NC}" >&2; return 1
        fi
        uk_seen[$k]=1
    done

    check_units_overlap "${unit_keys[@]}" || return 1

    _pmu_units=("${unit_keys[@]}")
    return 0
}

port_selectors() {
    local key=$1
    [ "$key" = "$VPS_PORT_ID" ] && return 0
    local members=()
    IFS=',' read -ra members <<< "$key"
    local m
    for m in "${members[@]}"; do
        [ -n "$m" ] && echo "$m"
    done
}

# 组 rule_id 限制在 [1, 0x1FFF]，避开端口段偏移 [0x2000, 0xFFFF]
hash_port_key() {
    local key=$1 salt=${2:-0}
    local h=$salt i ch
    local chars
    chars=$(printf '%s' "$key")
    for ((i=0; i<${#chars}; i++)); do
        ch=$(printf '%d' "'${chars:$i:1}")
        h=$(( (h*31 + ch) % 0x2000 ))
    done
    echo $(( h == 0 ? 1 : h ))
}

# 分配唯一 rule_id (tc class)，冲突则递增 salt 重哈希
assign_group_rule_id() {
    local key=$1
    local salt=0 id
    local existing
    existing=$(jq -r '[.ports[].rule_id] | map(. // empty)' "$CONFIG_FILE" 2>/dev/null || echo '[]')
    while :; do
        id=$(hash_port_key "$key" "$salt")
        if printf '%s' "$existing" | jq -e --argjson id "$id" 'index($id) == null' >/dev/null 2>&1; then
            echo "$id"
            return 0
        fi
        salt=$((salt + 1))
        # bash 的 [ ] 不支持十六进制字面量，必须用十进制 8192
        if [ $salt -ge 8192 ]; then
            id=$(hash_port_key "$key" 1)
            echo "$id"
            return 0
        fi
    done
}

derive_counter_key() {
    local key=$1
    if is_port_group "$key"; then
        echo "g$(hash_port_key "$key")"
    elif is_port_range "$key"; then
        printf '%s' "$key" | tr '-' '_'
    else
        echo "$key"
    fi
}

derive_rule_id() {
    local key=$1
    if is_port_group "$key"; then
        assign_group_rule_id "$key"
    elif is_port_range "$key"; then
        local mark=$(generate_port_range_mark "$key")
        echo $(( 0x2000 + mark % 0xE000 ))
    else
        echo "$key"
    fi
}

get_counter_name() {  # $1=counter_key $2=in|out
    echo "port_$1_$2"
}
get_quota_name() {    # $1=counter_key
    echo "port_${1}_quota"
}
get_expiry_name() {   # $1=counter_key，规则 comment 标识，remove/check 按此匹配
    echo "expiry_block_$1"
}
get_tc_class_id() {   # $1=rule_id（数值）
    echo "1:$(printf '%x' "$1")"
}

get_counter_key() {
    local key=$1
    local ck
    ck=$(jq -r --arg k "$key" '.ports[$k].counter_key // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$ck" ] || [ "$ck" = "null" ]; then
        ck=$(derive_counter_key "$key")
    fi
    echo "$ck"
}

get_rule_id() {
    local key=$1
    local rid
    rid=$(jq -r --arg k "$key" '.ports[$k].rule_id // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$rid" ] || [ "$rid" = "null" ]; then
        rid=$(derive_rule_id "$key")
    fi
    echo "$rid"
}

# 存量配置迁移：补齐 counter_key 与 rule_id
migrate_ports_schema() {
    [ -f "$CONFIG_FILE" ] || return 0
    local need
    need=$(jq -r '[.ports | to_entries[] | select((.value.counter_key // null) == null)] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [ "$need" -eq 0 ] && return 0

    # 清洗 CRLF 换行符，避免污染 jq 参数与字符串匹配
    local keys=()
    mapfile -t keys < <(jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | tr -d '\r' || true)

    local k
    for k in "${keys[@]}"; do
        k=${k%$'\r'}
        local ck rid
        ck=$(derive_counter_key "$k")
        rid=$(derive_rule_id "$k")
        update_config --arg k "$k" --arg ck "$ck" --argjson rid "$rid" \
            '.ports[$k].counter_key = $ck | .ports[$k].rule_id = $rid'
    done
    log_notification "配置已迁移到监控单元结构（counter_key + rule_id）"
}

# 通知结构迁移：补齐 api_host，重命名 webhook，清理 email
migrate_notifications_schema() {
    [ -f "$CONFIG_FILE" ] || return 0
    local need_migrate
    need_migrate=$(jq -r '
        ([.notifications.telegram.api_host // empty] | length == 0) or
        (.notifications.wecom // null) != null or
        (.notifications.email // null) != null
    ' "$CONFIG_FILE" 2>/dev/null || echo "true")
    [ "$need_migrate" = "false" ] && return 0

    # 单次 jq 原子迁移，避免中途失败产生中间态
    update_config '
        .notifications.telegram.api_host = (.notifications.telegram.api_host // "https://api.telegram.org")
        | .notifications.webhook = (.notifications.wecom // .notifications.webhook // {})
        | .notifications.webhook.platform = (.notifications.webhook.platform // "wecom")
        | del(.notifications.wecom)
        | del(.notifications.email)
    '
    log_notification "通知配置已迁移（telegram 加 api_host，wecom 重命名为 webhook）"

    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
    setup_telegram_notification_cron 2>/dev/null || true
    setup_webhook_notification_cron 2>/dev/null || true
}

generate_port_range_mark() {
    local port_range=$1
    local start_port=$(echo "$port_range" | cut -d'-' -f1)
    local end_port=$(echo "$port_range" | cut -d'-' -f2)
    echo $(( (start_port * 1000 + end_port) % 65536 ))
}

# 突发窗口取 10ms，下限 4*MTU 保底，上限 64KB
calculate_tc_burst() {
    local base_rate_kbps=$1
    local rate_bytes_per_sec=$((base_rate_kbps * 1000 / 8))
    local burst_10ms=$((rate_bytes_per_sec / 100))        # 10ms缓冲
    local min_burst=$((4 * 1500))                          # 4个以太网MTU保底(约6KB)
    local max_burst=$((64 * 1024))                         # 64KB最大突发上限

    local burst_calc=$burst_10ms
    if [ $burst_calc -lt $min_burst ]; then
        burst_calc=$min_burst
    elif [ $burst_calc -gt $max_burst ]; then
        burst_calc=$max_burst
    fi
    echo $burst_calc
}

# 协议开销与长延迟补偿：tc 按含帧头/包头的线速计数，用户测速只算有效载荷，
# 补偿15%可在兼顾近端合理性的同时消除跨洋/长RTT链路（如美西）的重传与抖动折损
calculate_effective_rate_kbps() {
    local target_rate_kbps=$1
    echo $(( target_rate_kbps * 115 / 100 ))
}

format_tc_burst() {
    local burst_bytes=$1
    if [ $burst_bytes -lt 1024 ]; then
        echo "${burst_bytes}"
    elif [ $burst_bytes -lt 1048576 ]; then
        echo "$((burst_bytes / 1024))k"
    else
        echo "$((burst_bytes / 1048576))m"
    fi
}

parse_tc_rate_to_kbps() {
    local total_limit=$1
    if [[ "$total_limit" =~ gbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/gbit$//')
        echo $((rate * 1000000))
    elif [[ "$total_limit" =~ mbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/mbit$//')
        echo $((rate * 1000))
    else
        echo $(echo "$total_limit" | sed 's/kbit$//')
    fi
}

convert_bandwidth_to_tc() {
    local rate="$1"
    local lower=$(echo "$rate" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" =~ kbps$ ]]; then
        echo "${lower/%kbps/kbit}"
    elif [[ "$lower" =~ mbps$ ]]; then
        echo "${lower/%mbps/mbit}"
    elif [[ "$lower" =~ gbps$ ]]; then
        echo "${lower/%gbps/gbit}"
    fi
}

generate_tc_class_id() {
    local port=$1
    local rule_id=$(get_rule_id "$port")
    get_tc_class_id "$rule_id"
}

get_daily_total_traffic() {
    local total_bytes=0
    local ports=($(get_monitored_ports))
    for port in "${ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local port_total=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        total_bytes=$(( total_bytes + port_total ))
    done
    format_bytes $total_bytes
}

format_vps_traffic_line() {
    local format_type="$1"
    local ifaces=($(get_vps_interface_names))
    if [ ${#ifaces[@]} -eq 0 ]; then
        return 0
    fi

    local billing_mode=$(jq -r ".ports.\"$VPS_PORT_ID\".billing_mode // \"double\"" "$CONFIG_FILE")
    local status_label=$(get_port_status_label "$VPS_PORT_ID")
    local data=$(vps_read_data)
    local result=""

    for iface in "${ifaces[@]}"; do
        local m_rx=$(printf '%s' "$data" | jq -r --arg i "$iface" '.monthly.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        local m_tx=$(printf '%s' "$data" | jq -r --arg i "$iface" '.monthly.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$m_rx" =~ ^[0-9]+$ ]] || m_rx=0
        [[ "$m_tx" =~ ^[0-9]+$ ]] || m_tx=0

        local input_bytes=0
        local output_bytes=0
        if [ "$billing_mode" = "double" ]; then
            input_bytes=$((m_rx * 2))
            output_bytes=$((m_tx * 2))
        else
            output_bytes=$m_tx
        fi
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local input_formatted=$(format_bytes $input_bytes)
        local output_formatted=$(format_bytes $output_bytes)

        if [ "$format_type" = "display" ]; then
            result+="整机总流量:${GREEN}${iface}${NC} | 总流量:${GREEN}$total_formatted${NC} | 上行(入站): ${GREEN}$input_formatted${NC} | 下行(出站):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}
"
        elif [ "$format_type" = "markdown" ]; then
            result+="**整机总流量**:**${iface}** | **总流量**:**${total_formatted}** | **上行**:**${input_formatted}** | **下行**:**${output_formatted}** | ${status_label}
"
        else
            result+="整机总流量:${iface} | 总流量:${total_formatted} | 上行(入站): ${input_formatted} | 下行(出站):${output_formatted} | ${status_label}
"
        fi
    done

    printf '%s' "$result"
}

format_port_list() {
    local format_type="$1"
    local active_ports=($(get_monitored_ports))
    local result=""

    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local output_formatted=$(format_bytes $output_bytes)
        local status_label=$(get_port_status_label "$port")

        local input_formatted=$(format_bytes $input_bytes)

        if [ "$format_type" = "display" ]; then
            echo -e "${GREEN}$(get_port_display_name "$port")${NC} | 总流量:${GREEN}$total_formatted${NC} | 上行(入站): ${GREEN}$input_formatted${NC} | 下行(出站):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}"
        elif [ "$format_type" = "markdown" ]; then
            result+="> **$(get_port_display_name "$port")** | 总流量:**${total_formatted}** | 上行:**${input_formatted}** | 下行:**${output_formatted}** | ${status_label}
"
        else
            result+="
$(get_port_display_name "$port") | 总流量:${total_formatted} | 上行(入站): ${input_formatted} | 下行(出站):${output_formatted} | ${status_label}"
        fi
    done

    if [ "$format_type" = "message" ] || [ "$format_type" = "markdown" ]; then
        echo "$result"
    fi
}

show_main_menu() {
    clear

    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)
    collect_vps_traffic

    echo -e "${BLUE}=== 端口流量狗 v$SCRIPT_VERSION ===${NC}"
    echo -e "${GREEN}了解更多:${NC}https://zywe.de | ${GREEN}项目开源:${NC}https://github.com/zywe03/realm-xwPF"
    echo -e "${GREEN}一只轻巧的‘守护犬’，时刻守护你的端口流量 | 快捷命令: dog${NC}"
    echo

    local vps_lines=$(format_vps_traffic_line "display")
    [ -n "$vps_lines" ] && echo -e "$vps_lines"
    echo -e "${GREEN}状态: 监控中${NC} | ${BLUE}监控项: ${port_count}个${NC} | ${YELLOW}端口总流量: $daily_total${NC}"
    echo "────────────────────────────────────────────────────────"

    if [ $port_count -gt 0 ]; then
        format_port_list "display"
    else
        echo -e "${YELLOW}暂无监控端口${NC}"
    fi

    echo "────────────────────────────────────────────────────────"

    echo -e "${BLUE}1.${NC} 添加/删除端口监控     ${BLUE}2.${NC} 端口限制设置管理"
    echo -e "${BLUE}3.${NC} 流量重置管理          ${BLUE}4.${NC} 一键导出/导入配置"
    echo -e "${BLUE}5.${NC} 安装依赖(更新)脚本    ${BLUE}6.${NC} 卸载脚本"
    echo -e "${BLUE}7.${NC} 通知管理"
    echo -e "${BLUE}0.${NC} 退出"
    echo
    read -p "请选择操作 [0-7]: " choice

    case $choice in
        1) manage_port_monitoring ;;
        2) manage_traffic_limits ;;
        3) manage_traffic_reset ;;
        4) manage_configuration ;;
        5) install_update_script ;;
        6) uninstall_script ;;
        7) manage_notifications ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请输入0-7${NC}"; sleep 1; show_main_menu ;;
    esac
}

manage_port_monitoring() {
    echo -e "${BLUE}=== 端口监控管理 ===${NC}"
    echo "1. 添加端口监控"
    echo "2. 删除端口监控"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) add_port_monitoring ;;
        2) remove_port_monitoring ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_port_monitoring ;;
    esac
}

add_port_monitoring() {
    echo -e "${BLUE}=== 添加端口监控 ===${NC}"
    echo

    echo -e "${GREEN}当前系统端口使用情况:${NC}"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"

    declare -A program_ports=()
    while read line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local_addr=$(echo "$line" | awk '{print $5}')
            port=$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2 || true)
            program=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")

            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                else
                    if [[ ! "${program_ports[$program]}" =~ (^|.*\|)$port(\||$) ]]; then
                        program_ports[$program]="${program_ports[$program]}|$port"
                    fi
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

    if [ ${#program_ports[@]} -gt 0 ]; then
        for program in $(printf '%s\n' "${!program_ports[@]}" | sort); do
            ports="${program_ports[$program]}"
            printf "%-10s | %-9s\n" "$program" "$ports"
        done
    else
        echo "无活跃端口"
    fi

    echo "────────────────────────────────────────────────────────"
    echo

    read_user_choice manage_port_monitoring "请输入要监控的端口（;分隔独立监控项，,分隔同组共享端口，-表端口段，如 443,80;22222） [0返回]: " port_input || return

    local PORTS=()
    if ! parse_monitor_units "$port_input" PORTS; then
        sleep 2
        manage_port_monitoring
        return
    fi
    local valid_ports=()

    for port in "${PORTS[@]}"; do
        if jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}监控项 $port 已在监控列表中，跳过${NC}"
            continue
        fi

        valid_ports+=("$port")
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的监控项可添加${NC}"
        sleep 2
        manage_port_monitoring
        return
    fi

    local existing_keys=($(get_monitored_ports))
    if ! check_units_overlap "${valid_ports[@]}" "${existing_keys[@]}"; then
        sleep 2
        manage_port_monitoring
        return
    fi

    echo
    echo -e "${GREEN}说明:${NC}"
    echo "1. 双向流量统计"
    echo "   总流量 = in*2 + out*2"
    echo
    echo "2. 单向流量统计"
    echo "   仅统计出站流量，总流量 = out"
    echo
    echo "请选择统计模式:"
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    read -p "请选择(回车默认1) [1-2]: " billing_choice

    local billing_mode="double"
    case $billing_choice in
        1|"") billing_mode="double" ;;
        2) billing_mode="single" ;;
        *) billing_mode="double" ;;
    esac

    echo
    local port_list=$(IFS=','; echo "${valid_ports[*]}")
    while true; do
        echo "为端口 $port_list 设置流量配额（总量控制）:"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额值"
            continue
        fi

        expand_single_value_to_array QUOTAS ${#valid_ports[@]}
        if [ ${#QUOTAS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    echo
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"
    echo "请输入当前规则备注(可选，直接回车跳过):"
    echo "(多端口排序分别备注使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -r -p "备注: " remark_input

    local REMARKS=()
    if [ -n "$remark_input" ]; then
        parse_comma_separated_input "$remark_input" REMARKS

        expand_single_value_to_array REMARKS ${#valid_ports[@]}
        if [ ${#REMARKS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}备注数量与端口数量不匹配${NC}"
            sleep 2
            add_port_monitoring
            return
        fi
    fi

    local added_count=0
    for i in "${!valid_ports[@]}"; do
        local port="${valid_ports[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
        local remark=""
        if [ ${#REMARKS[@]} -gt $i ]; then
            remark=$(echo "${REMARKS[$i]}" | tr -d ' ')
        fi

        local quota_enabled="true"
        local monthly_limit="unlimited"

        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            monthly_limit="$quota"
        fi

        local quota_config
        if [ "$monthly_limit" != "unlimited" ]; then
            quota_config="{
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\",
                \"reset_day\": 1
            }"
        else
            quota_config="{
                \"enabled\": $quota_enabled,
                \"monthly_limit\": \"$monthly_limit\"
            }"
        fi

        local display_name=$(get_port_display_name "$port")

        local ck rid
        ck=$(derive_counter_key "$port")
        rid=$(derive_rule_id "$port")

        # 备注与名称是自由文本：拼进 jq 程序时引号/反斜杠会让整个表达式解析失败
        local port_config="{
            \"enabled\": true,
            \"billing_mode\": \"$billing_mode\",
            \"bandwidth_limit\": {
                \"enabled\": false,
                \"rate\": \"unlimited\"
            },
            \"quota\": $quota_config,
            \"counter_key\": \"$ck\",
            \"rule_id\": $rid,
            \"created_at\": \"$(get_beijing_time -Iseconds)\"
        }"

        if ! update_config --arg k "$port" --arg name "$display_name" --arg remark "$remark" \
            ".ports[\$k] = ($port_config | .name = \$name | .remark = \$remark)"; then
            echo -e "${RED}✗ $display_name 监控配置保存失败，已跳过该端口；请检查配置文件 JSON 格式和写入权限${NC}"
            continue
        fi
        add_nftables_rules "$port"

        if [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$quota"
        fi

        echo -e "${GREEN}$display_name 监控添加成功${NC}"
        setup_port_auto_reset_cron "$port"
        added_count=$((added_count + 1))
    done

    echo
    echo -e "${GREEN}成功添加 $added_count 个监控项${NC}"

    sleep 2
    manage_port_monitoring
}

remove_port_monitoring() {
    echo -e "${BLUE}=== 删除端口监控 ===${NC}"
    echo

    local active_ports=($(get_monitored_ports))

    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无可删除的监控端口"
        sleep 2
        manage_port_monitoring
        return
    fi

    echo "当前监控的端口:"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). $(get_port_display_name "$port") $status_label"
    done
    echo "0. 返回上级菜单"
    echo

    read_user_choice manage_port_monitoring "请选择要删除的端口（多端口使用逗号,分隔） [0返回]: " choice_input || return

    local valid_choices=()
    local ports_to_delete=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_delete+=("$port")
    done

    if [ ${#ports_to_delete[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可删除${NC}"
        sleep 2
        remove_port_monitoring
        return
    fi

    echo
    echo "将删除以下端口的监控:"
    for port in "${ports_to_delete[@]}"; do
        echo "  端口 $port"
    done
    echo

    read -p "确认删除这些端口的监控? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        for port in "${ports_to_delete[@]}"; do
            remove_nftables_rules "$port"
            remove_nftables_quota "$port"
            remove_expiry_block "$port"
            remove_tc_limit "$port"
            update_config "del(.ports.\"$port\")"

            local history_file="$CONFIG_DIR/reset_history.log"
            if [ -f "$history_file" ]; then
                grep -v "|$port|" "$history_file" > "${history_file}.tmp" 2>/dev/null || true
                mv "${history_file}.tmp" "$history_file" 2>/dev/null || true
            fi

            local notification_log="$CONFIG_DIR/logs/notification.log"
            if [ -f "$notification_log" ]; then
                grep -v "端口 $port " "$notification_log" > "${notification_log}.tmp" 2>/dev/null || true
                mv "${notification_log}.tmp" "$notification_log" 2>/dev/null || true
            fi

            remove_port_auto_reset_cron "$port"

            echo -e "${GREEN}端口 $port 监控及相关数据删除成功${NC}"
            deleted_count=$((deleted_count + 1))
        done

        echo
        echo -e "${GREEN}成功删除 $deleted_count 个端口监控${NC}"

        echo "正在清理网络状态..."
        for port in "${ports_to_delete[@]}"; do
            echo "清理 $(get_port_display_name "$port") 连接状态..."
            local sel
            while read -r sel; do
                [ -z "$sel" ] && continue
                if is_port_range "$sel"; then
                    local start_port=$(echo "$sel" | cut -d'-' -f1)
                    local end_port=$(echo "$sel" | cut -d'-' -f2)
                    for ((p=start_port; p<=end_port; p++)); do
                        conntrack -D -p tcp --dport $p 2>/dev/null || true
                        conntrack -D -p udp --dport $p 2>/dev/null || true
                    done
                else
                    conntrack -D -p tcp --dport $sel 2>/dev/null || true
                    conntrack -D -p udp --dport $sel 2>/dev/null || true
                fi
            done < <(port_selectors "$port")
        done

        echo -e "${GREEN}网络状态已清理，现有连接的限制应该已解除${NC}"
        echo -e "${YELLOW}提示：新建连接将不受任何限制${NC}"

        local remaining_ports=($(get_monitored_ports))
        if [ ${#remaining_ports[@]} -eq 0 ]; then
            echo -e "${YELLOW}所有端口已删除（整机流量监控保持开启），自动重置功能已停用${NC}"
        fi
    else
        echo "取消删除"
    fi

    sleep 2
    manage_port_monitoring
}

add_nftables_rules() {
    local port=$1

    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    remove_port_rules_by_pattern "$port"

    if [ "$billing_mode" = "double" ]; then
        nft_counter_exists "$in_name" || \
            nft add counter $family $table_name "$in_name" 2>/dev/null || true
    fi
    nft_counter_exists "$out_name" || \
        nft add counter $family $table_name "$out_name" 2>/dev/null || true

    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        local mark_clause=""
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            mark_clause=" meta mark set $mark_id"
        fi

        if [ "$billing_mode" = "double" ]; then
            nft add rule $family $table_name input tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name input udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name input tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name input udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp dport $sel$mark_clause counter name "$in_name" 2>/dev/null || true
            nft add rule $family $table_name output tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
        else
            nft add rule $family $table_name output tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name output udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward tcp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
            nft add rule $family $table_name forward udp sport $sel$mark_clause counter name "$out_name" 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

remove_port_rules_by_pattern() {
    local port=$1

    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local search_pattern="port_${counter_key}_"

    local deleted_count=0
    local handles=()
    mapfile -t handles < <(nft -a list table $family $table_name 2>/dev/null | \
        grep -E "counter name \"$search_pattern" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' || true)

    local handle
    for handle in "${handles[@]}"; do
        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done
}

remove_nftables_rules() {
    local port=$1

    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)

    remove_port_rules_by_pattern "$port"

    nft delete counter $family $table_name "$in_name" 2>/dev/null || true
    nft delete counter $family $table_name "$out_name" 2>/dev/null || true
}

set_port_bandwidth_limit() {
    echo -e "${BLUE}设置端口带宽限制${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read_user_choice manage_traffic_limits "请选择要限制的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

    local valid_choices=()
    local ports_to_limit=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_limit+=("$port")
    done

    if [ ${#ports_to_limit[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置限制${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    echo
    local display_list
    for port in "${ports_to_limit[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done
    echo "为 $display_list 设置带宽限制（速率控制）:"
    echo "请输入限制值（0为无限制）（要带单位Kbps/Mbps/Gbps）:"
    echo "(多端口排序分别限制使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "带宽限制: " limit_input

    local LIMITS=()
    parse_comma_separated_input "$limit_input" LIMITS

    expand_single_value_to_array LIMITS ${#ports_to_limit[@]}
    if [ ${#LIMITS[@]} -ne ${#ports_to_limit[@]} ]; then
        echo -e "${RED}限制值数量与端口数量不匹配${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    local success_count=0
    for i in "${!ports_to_limit[@]}"; do
        local port="${ports_to_limit[$i]}"
        local limit=$(echo "${LIMITS[$i]}" | tr -d ' ')

        if [ "$limit" = "0" ] || [ -z "$limit" ]; then
            remove_tc_limit "$port"
            update_config ".ports.\"$port\".bandwidth_limit.enabled = false |
                .ports.\"$port\".bandwidth_limit.rate = \"unlimited\""
            echo -e "${GREEN}$(get_port_display_name "$port") 带宽限制已移除${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        remove_tc_limit "$port"

        if ! validate_bandwidth "$limit"; then
            echo -e "${RED}$(get_port_display_name "$port") 格式错误，请使用如：500Kbps, 100Mbps, 1Gbps${NC}"
            continue
        fi

        local tc_limit=$(convert_bandwidth_to_tc "$limit")

        if apply_tc_limit "$port" "$tc_limit"; then
            update_config ".ports.\"$port\".bandwidth_limit.enabled = true |
                .ports.\"$port\".bandwidth_limit.rate = \"$limit\""

            echo -e "${GREEN}$(get_port_display_name "$port") 带宽限制设置成功: $limit${NC}"
        else
            echo -e "${RED}端口 $port 限速规则应用失败，请检查 tc/nftables 环境${NC}"
            continue
        fi
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的带宽限制${NC}"
    sleep 3
    manage_traffic_limits
}

set_port_quota_limit() {
    echo -e "${BLUE}=== 设置端口流量配额 ===${NC}"
    echo

    local active_ports=($(get_active_ports))
    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read_user_choice manage_traffic_limits "请选择要设置配额的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

    local valid_choices=()
    local ports_to_quota=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_quota+=("$port")
    done

    if [ ${#ports_to_quota[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置配额${NC}"
        sleep 2
        set_port_quota_limit
        return
    fi

    echo
    local display_list
    for port in "${ports_to_quota[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done
    while true; do
        echo "为 $display_list 设置流量配额（总量控制）:"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额值"
            continue
        fi

        expand_single_value_to_array QUOTAS ${#ports_to_quota[@]}
        if [ ${#QUOTAS[@]} -ne ${#ports_to_quota[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    local success_count=0
    for i in "${!ports_to_quota[@]}"; do
        local port="${ports_to_quota[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')

        if [ "$quota" = "0" ] || [ -z "$quota" ]; then
            remove_nftables_quota "$port"
            jq ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"unlimited\" |
                del(.ports.\"$port\".quota.reset_day)" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 流量配额设置为无限制${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        remove_nftables_quota "$port"
        apply_nftables_quota "$port" "$quota"

        local current_monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        
        if [ "$current_monthly_limit" = "unlimited" ]; then
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"$quota\" |
                .ports.\"$port\".quota.reset_day = 1"
        else
            update_config ".ports.\"$port\".quota.enabled = true |
                .ports.\"$port\".quota.monthly_limit = \"$quota\""
        fi
        
        setup_port_auto_reset_cron "$port"
        echo -e "${GREEN}$(get_port_display_name "$port") 流量配额设置成功: $quota${NC}"
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的流量配额${NC}"
    sleep 3
    manage_traffic_limits
}

manage_traffic_limits() {
    echo -e "${BLUE}=== 端口限制设置管理 ===${NC}"
    echo "1. 设置端口带宽限制（速率控制）"
    echo "2. 设置端口流量配额（总量控制）"
    echo "3. 修改端口统计方式（双向/单向）"
    echo "4. 设置端口截止日期（到期阻断）"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-4]: " choice

    case $choice in
        1) set_port_bandwidth_limit ;;
        2) set_port_quota_limit ;;
        3) change_port_billing_mode ;;
        4) set_port_expiry_date ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_traffic_limits ;;
    esac
}

change_port_billing_mode() {
    echo -e "${BLUE}=== 修改端口统计方式 ===${NC}"
    
    local active_ports=$(jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n)
    if [ -z "$active_ports" ]; then
        echo -e "${RED}没有正在监控的端口${NC}"
        sleep 2
        manage_traffic_limits
        return
    fi
    
    echo -e "${YELLOW}当前监控的端口列表：${NC}"
    local port_list=()
    local idx=1
    for port in $active_ports; do
        local current_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local mode_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
        echo -e "  $idx. $(get_port_display_name "$port") - 当前模式: ${BLUE}${mode_display}${NC}"
        port_list+=("$port")
        ((idx++))
    done
    echo "  0. 返回上级菜单"
    echo
    
    read -p "请选择要修改的端口 [0-$((idx-1))]: " port_choice
    
    if [ "$port_choice" = "0" ]; then
        manage_traffic_limits
        return
    fi
    
    if ! [[ "$port_choice" =~ ^[0-9]+$ ]] || [ "$port_choice" -lt 1 ] || [ "$port_choice" -gt ${#port_list[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        sleep 1
        change_port_billing_mode
        return
    fi
    
    local target_port="${port_list[$((port_choice-1))]}"
    local current_mode=$(jq -r ".ports.\"$target_port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local current_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
    local target_label=$(get_port_display_name "$target_port")

    echo
    echo -e "$target_label 当前统计方式: ${BLUE}$current_display${NC}"
    echo
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    echo "0. 取消"
    echo
    read -p "请选择统计模式 [0-2]: " mode_choice
    
    local new_mode=""
    case $mode_choice in
        1) new_mode="double" ;;
        2) new_mode="single" ;;
        0|"") change_port_billing_mode; return ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; change_port_billing_mode; return ;;
    esac
    
    local new_display=$([ "$new_mode" = "double" ] && echo "双向" || echo "单向")
    
    echo
    echo -e "${YELLOW}正在应用 $new_display 模式...${NC}"
    
    local traffic_data=($(get_nftables_counter_data "$target_port"))
    local saved_input=${traffic_data[0]:-0}
    local saved_output=${traffic_data[1]:-0}
    echo -e "  读取流量: 上行=$(format_bytes $saved_input), 下行=$(format_bytes $saved_output)"
    
    remove_nftables_rules "$target_port"
    
    local tmp_file=$(mktemp)
    jq ".ports.\"$target_port\".billing_mode = \"$new_mode\"" "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
    
    restore_counter_value "$target_port" "$saved_input" "$saved_output"
    
    add_nftables_rules "$target_port"
    
    local quota_enabled=$(jq -r ".ports.\"$target_port\".quota.enabled // false" "$CONFIG_FILE")
    local quota_limit=$(jq -r ".ports.\"$target_port\".quota.monthly_limit // \"\"" "$CONFIG_FILE")
    if [ "$quota_enabled" = "true" ] && [ -n "$quota_limit" ] && [ "$quota_limit" != "null" ] && [ "$quota_limit" != "unlimited" ]; then
        apply_nftables_quota "$target_port" "$quota_limit"
    fi
    
    echo -e "${GREEN}✓ ${target_label}已应用 $new_display 模式，流量数据已保留${NC}"
    sleep 2
    
    change_port_billing_mode
}

apply_nftables_quota() {
    local port=$1
    local quota_limit=$2

    # 整机配额仅监控告警，不做内核 drop 阻断以防锁死 SSH
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local quota_name=$(get_quota_name "$counter_key")

    local quota_bytes=$(parse_size_to_bytes "$quota_limit")

    # 以当前已用量作为配额初始 offset，防止配额修改立即误阻断
    local current_traffic=($(get_nftables_counter_data "$port"))
    local current_input=${current_traffic[0]}
    local current_output=${current_traffic[1]}
    local current_total=$(calculate_total_traffic "$current_input" "$current_output" "$billing_mode")

    nft delete quota $family $table_name $quota_name 2>/dev/null || true
    nft add quota $family $table_name $quota_name { over $quota_bytes bytes used $current_total bytes } 2>/dev/null || true

    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if [ "$billing_mode" = "double" ]; then
            nft insert rule $family $table_name input tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name input udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp dport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
        else
            nft insert rule $family $table_name output tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name output udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward tcp sport $sel quota name "$quota_name" drop 2>/dev/null || true
            nft insert rule $family $table_name forward udp sport $sel quota name "$quota_name" drop 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

remove_nftables_quota() {
    local port=$1

    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local quota_name=$(get_quota_name "$counter_key")

    local deleted_count=0
    local handles=()
    mapfile -t handles < <(nft -a list table $family $table_name 2>/dev/null | \
        grep "quota name \"$quota_name\"" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' || true)

    local handle
    for handle in "${handles[@]}"; do
        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done

    nft delete quota $family $table_name "$quota_name" 2>/dev/null || true
}

validate_expiry_date() {
    local input="$1"
    if [ "$input" = "0" ]; then
        return 0
    fi
    if ! [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        return 1
    fi
    date -d "$input" >/dev/null 2>&1 || return 1
    return 0
}

set_port_expiry_date() {
    echo -e "${BLUE}=== 设置端口截止日期 ===${NC}"
    echo

    local active_ports=($(get_active_ports))
    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read_user_choice manage_traffic_limits "请选择要设置截止日期的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

    local valid_choices=()
    local ports_to_set=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        if [ "$port" = "$VPS_PORT_ID" ]; then
            echo -e "${YELLOW}整机流量不支持设置截止日期${NC}"
            continue
        fi
        ports_to_set+=("$port")
    done

    if [ ${#ports_to_set[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置截止日期${NC}"
        sleep 2
        set_port_expiry_date
        return
    fi

    echo
    local display_list
    for port in "${ports_to_set[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done

    while true; do
        echo "为 $display_list 设置截止日期 (格式: YYYY-MM-DD，输入 0 取消截止限制):"
        echo "(多端口分别设置请用逗号,分隔；输入单个值将应用到所有选择的端口):"
        read -p "截止日期: " expiry_input

        if [ -z "$expiry_input" ]; then
            echo -e "${YELLOW}输入不能为空，请输入日期或 0${NC}"
            continue
        fi

        local EXPIRIES=()
        parse_comma_separated_input "$expiry_input" EXPIRIES

        local invalid=false
        for exp in "${EXPIRIES[@]}"; do
            if ! validate_expiry_date "$exp"; then
                echo -e "${RED}日期格式错误: $exp，请使用 YYYY-MM-DD 格式（如 2026-12-31）或 0 取消${NC}"
                invalid=true
                break
            fi
        done
        [ "$invalid" = true ] && continue

        expand_single_value_to_array EXPIRIES ${#ports_to_set[@]}
        if [ ${#EXPIRIES[@]} -ne ${#ports_to_set[@]} ]; then
            echo -e "${RED}截止日期数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    for i in "${!ports_to_set[@]}"; do
        local port="${ports_to_set[$i]}"
        local expiry_val="${EXPIRIES[$i]}"

        if [ "$expiry_val" = "0" ]; then
            update_config "del(.ports.\"$port\".expiry)"
            remove_expiry_block "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 已取消截止日期限制${NC}"
            log_notification "$(get_port_display_name "$port") 已取消截止日期限制"
        else
            update_config ".ports.\"$port\".expiry = {\"expire_date\": \"$expiry_val\"}"
            check_and_apply_expiry "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 截止日期设置成功: $expiry_val${NC}"
            log_notification "$(get_port_display_name "$port") 截止日期设置为 $expiry_val"
        fi
    done

    sleep 2
    manage_traffic_limits
}

apply_expiry_block() {
    local port=$1
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local expiry_comment=$(get_expiry_name "$counter_key")

    remove_expiry_block "$port"

    while IFS= read -r sel; do
        [ -z "$sel" ] && continue
        nft insert rule $family $table_name input tcp dport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name input udp dport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name forward tcp dport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name forward udp dport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name output tcp sport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name output udp sport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name forward tcp sport $sel drop comment "$expiry_comment" 2>/dev/null || true
        nft insert rule $family $table_name forward udp sport $sel drop comment "$expiry_comment" 2>/dev/null || true
    done < <(port_selectors "$port")
}

remove_expiry_block() {
    local port=$1
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local expiry_comment=$(get_expiry_name "$counter_key")

    local handles=()
    mapfile -t handles < <(nft -a list table $family $table_name 2>/dev/null | \
        grep "comment \"$expiry_comment\"" | \
        sed -n 's/.*# handle \([0-9]\+\)$/\1/p' || true)

    for handle in "${handles[@]}"; do
        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                break
            fi
        done
    done
}

check_and_apply_expiry() {
    local port=$1
    [ "$port" = "$VPS_PORT_ID" ] && return 0

    local expire_date=$(jq -r ".ports.\"$port\".expiry.expire_date // empty" "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$expire_date" ] || [ "$expire_date" = "null" ]; then
        remove_expiry_block "$port"
        return 0
    fi

    local today_bj
    today_bj=$(get_beijing_time '+%Y-%m-%d')
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local expiry_comment=$(get_expiry_name "$counter_key")

    # 避免 grep -q 早退触发 nft SIGPIPE (pipefail 退出码 141)
    local is_blocked=false
    local block_count
    block_count=$(nft list table $family $table_name 2>/dev/null | grep -c "comment \"$expiry_comment\"" || true)
    if [ "${block_count:-0}" -gt 0 ]; then
        is_blocked=true
    fi

    if [[ "$today_bj" > "$expire_date" || "$today_bj" == "$expire_date" ]]; then
        if [ "$is_blocked" = true ]; then
            return 0
        fi
        apply_expiry_block "$port"
        log_notification "$(get_port_display_name "$port") 已达截止日期 ($expire_date)，连接已阻断"
    else
        if [ "$is_blocked" = true ]; then
            remove_expiry_block "$port"
            log_notification "$(get_port_display_name "$port") 截止日期已调整为 ($expire_date)，阻断已解除"
        fi
    fi
}

check_all_expiry() {
    local active_ports=($(get_monitored_ports))
    for port in "${active_ports[@]}"; do
        check_and_apply_expiry "$port"
    done
}

list_shaping_interfaces() {
    ls /sys/class/net | grep -v -E "^(lo|ifb|docker0|br-.*|veth.*|virbr.*|wg.*|tun.*|tap.*)$"
}

get_vps_tc_ceiling() {
    local enabled=$(jq -r ".ports.\"$VPS_PORT_ID\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
    local rate=$(jq -r ".ports.\"$VPS_PORT_ID\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
    if [ "$enabled" = "true" ] && [ "$rate" != "unlimited" ]; then
        local tc_rate=$(convert_bandwidth_to_tc "$rate")
        if [ -n "$tc_rate" ]; then
            echo "$(calculate_effective_rate_kbps $(parse_tc_rate_to_kbps "$tc_rate"))kbit"
        fi
    fi
}

# default 类 0x30 与端口 48 同号；端口 48 存在时不创建 1:30 避免冲突
vps_default_class_in_use() {
    local enabled=$(jq -r '.ports."48".bandwidth_limit.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false)
    local rate=$(jq -r '.ports."48".bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE" 2>/dev/null || echo unlimited)
    [ "$enabled" = "true" ] && [ "$rate" != "unlimited" ]
}

# 整机限速压父类 1:1，端口子类速率自动与整机取 min
apply_vps_tc_limit() {
    local total_limit=$1

    local raw_rate_kbps=$(parse_tc_rate_to_kbps "$total_limit")
    local effective_rate_kbps=$(calculate_effective_rate_kbps "$raw_rate_kbps")
    local effective_limit="${effective_rate_kbps}kbit"

    local dev
    local ok_count=0
    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "qdisc htb 1:"; then
            tc qdisc replace dev $dev root handle 1: htb default 30 2>/dev/null || true
        fi
        if tc class replace dev $dev parent 1: classid 1:1 htb rate $effective_limit ceil $effective_limit 2>/dev/null; then
            ok_count=$((ok_count + 1))
        else
            log_notification "整机限速：压父类失败 (网卡 $dev)"
        fi
        if ! vps_default_class_in_use; then
            if ! tc class show dev $dev 2>/dev/null | grep -q "class htb 1:30"; then
                tc class add dev $dev parent 1:1 classid 1:30 htb rate $effective_limit ceil $effective_limit 2>/dev/null || true
            else
                tc class change dev $dev parent 1:1 classid 1:30 htb rate $effective_limit ceil $effective_limit 2>/dev/null || true
            fi
        fi
    done
    [ $ok_count -eq 0 ] && return 1

    if ! ip link show ifb0 >/dev/null 2>&1; then
        modprobe ifb numifbs=1 2>/dev/null || true
        ip link add ifb0 type ifb 2>/dev/null || true
        ip link set ifb0 up 2>/dev/null || true
    fi
    # ifb 为 NOARP 设备，operstate 恒为 UNKNOWN，仅检测 UP flag
    if ! ip link show ifb0 2>/dev/null | grep -q "<.*UP.*>"; then
        log_notification "ifb0 创建失败，整机入向限速未生效"
        return 0
    fi

    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "^qdisc ingress"; then
            tc qdisc add dev $dev handle ffff: ingress 2>/dev/null || true
        fi
        # 重定向规则只装一次，避免规则叠加
        if ! tc filter show dev $dev parent ffff: 2>/dev/null | grep -q "mirred.*ifb0"; then
            tc filter add dev $dev parent ffff: protocol ip u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
            tc filter add dev $dev parent ffff: protocol ipv6 u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
        fi
    done

    if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb 1:"; then
        tc qdisc add dev ifb0 root handle 1: htb default 1 2>/dev/null || true
    fi
    tc class replace dev ifb0 parent 1: classid 1:1 htb rate $effective_limit ceil $effective_limit 2>/dev/null || true
    return 0
}

# 解除整机限速；若无端口限速则拆除 ifb 避免常驻耗 CPU
remove_vps_tc_limit() {
    local dev
    local default_busy=false
    vps_default_class_in_use && default_busy=true

    for dev in $(list_shaping_interfaces); do
        tc class replace dev $dev parent 1: classid 1:1 htb rate 100gbit 2>/dev/null || true
        if [ "$default_busy" = "false" ]; then
            tc class change dev $dev parent 1:1 classid 1:30 htb rate 100gbit ceil 100gbit 2>/dev/null || true
        fi
    done
    if ip link show ifb0 >/dev/null 2>&1; then
        tc class replace dev ifb0 parent 1: classid 1:1 htb rate 100gbit 2>/dev/null || true
    fi

    if [ "$default_busy" = "false" ]; then
        local port_classes=0
        for dev in $(list_shaping_interfaces); do
            port_classes=$((port_classes + $(tc class show dev $dev 2>/dev/null | grep "parent 1:1" | grep -vc "class htb 1:30 " || true)))
        done
        local ifb_classes=0
        if ip link show ifb0 >/dev/null 2>&1; then
            ifb_classes=$(tc class show dev ifb0 2>/dev/null | grep -c "parent 1:1" || true)
        fi
        if [ "$port_classes" -eq 0 ] && [ "$ifb_classes" -eq 0 ]; then
            for dev in $(list_shaping_interfaces); do
                tc qdisc del dev $dev root 2>/dev/null || true
                tc qdisc del dev $dev ingress 2>/dev/null || true
            done
            if ip link show ifb0 >/dev/null 2>&1; then
                tc qdisc del dev ifb0 root 2>/dev/null || true
                ip link set ifb0 down 2>/dev/null || true
                ip link del ifb0 2>/dev/null || true
            fi
        fi
    fi
    return 0
}

apply_tc_limit() {
    local port=$1
    local total_limit=$2

    if [ "$port" = "$VPS_PORT_ID" ]; then
        apply_vps_tc_limit "$total_limit"
        return $?
    fi

    # 已有根 qdisc 时 add 静默失败，已有 htb 时 replace 无法生效，须先探测再建
    local root_rate="100gbit"
    local vps_ceiling=$(get_vps_tc_ceiling)
    [ -n "$vps_ceiling" ] && root_rate="$vps_ceiling"

    local dev
    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "qdisc htb 1:"; then
            tc qdisc replace dev $dev root handle 1: htb default 30 2>/dev/null || true
        fi
        tc class replace dev $dev parent 1: classid 1:1 htb rate $root_rate 2>/dev/null || true
    done

    local class_id=$(generate_tc_class_id "$port")
    # 变更限速档位须先拆后建，避免 class 被引用导致删除失败
    remove_egress_filters "$port"

    local raw_rate_kbps=$(parse_tc_rate_to_kbps "$total_limit")
    local effective_rate_kbps=$(calculate_effective_rate_kbps "$raw_rate_kbps")
    local effective_limit="${effective_rate_kbps}kbit"
    local burst_bytes=$(calculate_tc_burst "$effective_rate_kbps")
    local burst_size=$(format_tc_burst "$burst_bytes")

    local ok_count=0
    for dev in $(list_shaping_interfaces); do
        tc qdisc del dev $dev parent $class_id 2>/dev/null || true
        tc class del dev $dev classid $class_id 2>/dev/null || true
        if tc class add dev $dev parent 1:1 classid $class_id htb rate $effective_limit ceil $effective_limit burst $burst_size 2>/dev/null; then
            attach_leaf_qdisc $dev "$class_id" "$effective_rate_kbps"
            add_egress_filters "$dev" "$port" "$class_id"
            ok_count=$((ok_count + 1))
        else
            log_notification "创建限速类 $class_id 失败 (端口 $port, 网卡 $dev)"
        fi
    done
    [ $ok_count -eq 0 ] && return 1

    apply_ingress_shaping "$port" "$total_limit"
    return 0
}

# 出向分类器：单端口 u32 直配，端口段匹配 fw mark
add_egress_filters() {
    local dev=$1
    local port=$2
    local class_id=$3

    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            tc filter add dev $dev protocol ip parent 1:0 prio 1 handle $mark_id fw flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio 2 handle $mark_id fw flowid $class_id 2>/dev/null || true
        else
            local filter_prio=$((sel % 1000 + 1))
            tc filter add dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
            tc filter add dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

remove_egress_filters() {
    local port=$1
    local dev

    for dev in $(list_shaping_interfaces); do
        local sel
        while read -r sel; do
            [ -z "$sel" ] && continue
            if is_port_range "$sel"; then
                local mark_id=$(generate_port_range_mark "$sel")
                local mark_hex=$(printf '0x%x' "$mark_id")
                tc filter del dev $dev protocol ip parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio 2 handle $mark_hex fw 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio 2 handle $mark_id fw 2>/dev/null || true
            else
                local filter_prio=$((sel % 1000 + 1))
                tc filter del dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                    match ip protocol 6 0xff match ip sport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio $filter_prio u32 \
                    match ip protocol 6 0xff match ip dport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                    match ip protocol 17 0xff match ip sport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                    match ip protocol 17 0xff match ip dport $sel 0xffff 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                    match u8 6 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                    match u8 6 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                    match u8 17 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
                tc filter del dev $dev protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                    match u8 17 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
            fi
        done < <(port_selectors "$port")
    done
}

check_cake_support() {
    if modprobe sch_cake 2>/dev/null; then
        return 0
    fi
    if tc qdisc add dev lo root cake 2>/dev/null; then
        tc qdisc del dev lo root 2>/dev/null || true
        return 0
    fi
    return 1
}

attach_leaf_qdisc() {
    local dev=$1
    local class_id=$2
    local rate_kbps=$3

    # 优先 CAKE (带 ack-filter)，不支持时回退 fq_codel
    if check_cake_support && tc qdisc replace dev "$dev" parent "$class_id" cake bandwidth "${rate_kbps}kbit" ethernet ack-filter 2>/dev/null; then
        return 0
    fi

    tc qdisc replace dev "$dev" parent "$class_id" fq_codel 2>/dev/null || true
}

# 入向流量经 ifb0 镜像重定向借用出向整形
apply_ingress_shaping() {
    local port=$1
    local total_limit=$2

    if ! ip link show ifb0 >/dev/null 2>&1; then
        modprobe ifb numifbs=1 2>/dev/null || true
        ip link add ifb0 type ifb 2>/dev/null || true
        ip link set ifb0 up 2>/dev/null || true
    fi
    # ifb 为 NOARP 设备，operstate 恒为 UNKNOWN，仅检测 UP flag
    if ! ip link show ifb0 2>/dev/null | grep -q "<.*UP.*>"; then
        log_notification "ifb0 创建失败，端口 $port 入向限速未生效"
        return 1
    fi

    # 所有非 lo 网卡挂 ingress；qdisc show 判据须过滤 ingress 行
    local dev
    for dev in $(list_shaping_interfaces); do
        if ! tc qdisc show dev $dev 2>/dev/null | grep -q "^qdisc ingress"; then
            tc qdisc add dev $dev handle ffff: ingress 2>/dev/null || true
        fi
        # 重定向规则只装一次，避免规则叠加
        if ! tc filter show dev $dev parent ffff: 2>/dev/null | grep -q "mirred.*ifb0"; then
            tc filter add dev $dev parent ffff: protocol ip u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
            tc filter add dev $dev parent ffff: protocol ipv6 u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null || true
        fi
    done

    if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb 1:"; then
        tc qdisc add dev ifb0 root handle 1: htb default 1 2>/dev/null || true
    fi
    local ifb_root_rate="100gbit"
    local vps_ceiling=$(get_vps_tc_ceiling)
    [ -n "$vps_ceiling" ] && ifb_root_rate="$vps_ceiling"
    tc class replace dev ifb0 parent 1: classid 1:1 htb rate $ifb_root_rate 2>/dev/null || true

    local class_id=$(generate_tc_class_id "$port")
    # 拆除须按 filter -> leaf -> class 顺序，防 class 被引用报错
    remove_ingress_filters "$port"
    tc qdisc del dev ifb0 parent $class_id 2>/dev/null || true
    tc class del dev ifb0 classid $class_id 2>/dev/null || true
    local raw_rate_kbps=$(parse_tc_rate_to_kbps "$total_limit")
    local effective_rate_kbps=$(calculate_effective_rate_kbps "$raw_rate_kbps")
    local effective_limit="${effective_rate_kbps}kbit"
    local burst_bytes=$(calculate_tc_burst "$effective_rate_kbps")
    local burst_size=$(format_tc_burst "$burst_bytes")
    if ! tc class add dev ifb0 parent 1:1 classid $class_id htb rate $effective_limit ceil $effective_limit burst $burst_size 2>/dev/null; then
        log_notification "创建入向限速类 $class_id 失败 (端口 $port)"
        return 1
    fi
    attach_leaf_qdisc ifb0 "$class_id" "$effective_rate_kbps"

    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            tc filter add dev ifb0 protocol ip parent 1:0 prio 1 handle $mark_id fw flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio 2 handle $mark_id fw flowid $class_id 2>/dev/null || true
        else
            local filter_prio=$((sel % 1000 + 1))
            tc filter add dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip dport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip sport $sel 0xffff flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 42 flowid $class_id 2>/dev/null || true
            tc filter add dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 40 flowid $class_id 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
    return 0
}

remove_ingress_filters() {
    local port=$1

    local sel
    while read -r sel; do
        [ -z "$sel" ] && continue
        if is_port_range "$sel"; then
            local mark_id=$(generate_port_range_mark "$sel")
            local mark_hex=$(printf '0x%x' "$mark_id")
            tc filter del dev ifb0 protocol ip parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio 2 handle $mark_hex fw 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio 2 handle $mark_id fw 2>/dev/null || true
        else
            local filter_prio=$((sel % 1000 + 1))
            tc filter del dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip dport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio $filter_prio u32 \
                match ip protocol 6 0xff match ip sport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip dport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
                match ip protocol 17 0xff match ip sport $sel 0xffff 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 2000)) u32 \
                match u8 6 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 42 2>/dev/null || true
            tc filter del dev ifb0 protocol ipv6 parent 1:0 prio $((filter_prio + 3000)) u32 \
                match u8 17 0xff at 6 match u16 $sel 0xffff at 40 2>/dev/null || true
        fi
    done < <(port_selectors "$port")
}

remove_ingress_shaping() {
    local port=$1

    if ! ip link show ifb0 >/dev/null 2>&1; then
        return 0
    fi

    local class_id=$(generate_tc_class_id "$port")
    remove_ingress_filters "$port"
    tc qdisc del dev ifb0 parent $class_id 2>/dev/null || true
    tc class del dev ifb0 classid $class_id 2>/dev/null || true

    if [ -n "$(get_vps_tc_ceiling)" ]; then
        return 0
    fi

    # ifb0 无限速类时连同各网卡 ingress 根一并拆除
    if [ "$(tc class show dev ifb0 2>/dev/null | grep -c "parent 1:1" || true)" -eq 0 ]; then
        local dev
        for dev in $(list_shaping_interfaces); do
            tc qdisc del dev $dev ingress 2>/dev/null || true
        done
        tc qdisc del dev ifb0 root 2>/dev/null || true
        ip link set ifb0 down 2>/dev/null || true
        ip link del ifb0 2>/dev/null || true
    fi
}

remove_tc_limit() {
    local port=$1

    if [ "$port" = "$VPS_PORT_ID" ]; then
        remove_vps_tc_limit
        return 0
    fi

    local class_id=$(generate_tc_class_id "$port")

    remove_egress_filters "$port"
    local dev remaining=0
    for dev in $(list_shaping_interfaces); do
        tc qdisc del dev $dev parent $class_id 2>/dev/null || true
        tc class del dev $dev classid $class_id 2>/dev/null || true
    done

    remove_ingress_shaping "$port"

    for dev in $(list_shaping_interfaces); do
        remaining=$((remaining + $(tc class show dev $dev 2>/dev/null | grep -c "parent 1:1" || true)))
    done
    if [ "$remaining" -eq 0 ]; then
        for dev in $(list_shaping_interfaces); do
            tc qdisc del dev $dev root 2>/dev/null || true
        done
    fi
}

manage_traffic_reset() {
    echo -e "${BLUE}流量重置管理${NC}"
    echo "1. 重置流量月重置日设置"
    echo "2. 立即重置"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) set_reset_day ;;
        2) immediate_reset ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_traffic_reset ;;
    esac
}

set_reset_day() {
    echo -e "${BLUE}=== 重置流量月重置日设置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read_user_choice manage_traffic_reset "请选择要设置重置日期的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

    local valid_choices=()
    local ports_to_set=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_set+=("$port")
    done

    if [ ${#ports_to_set[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置${NC}"
        sleep 2
        set_reset_day
        return
    fi

    echo
    local display_list
    for port in "${ports_to_set[@]}"; do
        display_list="${display_list:+$display_list,}$(get_port_display_name "$port")"
    done
    echo "为 $display_list 设置月重置日期:"
    echo "请输入月重置日（多端口使用逗号,分隔）(0代表不重置):"
    echo "(只输入一个值，应用到所有端口):"
    read -p "月重置日 [0-31]: " reset_day_input

    local RESET_DAYS=()
    parse_comma_separated_input "$reset_day_input" RESET_DAYS

    expand_single_value_to_array RESET_DAYS ${#ports_to_set[@]}
    if [ ${#RESET_DAYS[@]} -ne ${#ports_to_set[@]} ]; then
        echo -e "${RED}重置日期数量与端口数量不匹配${NC}"
        sleep 2
        set_reset_day
        return
    fi

    local success_count=0
    for i in "${!ports_to_set[@]}"; do
        local port="${ports_to_set[$i]}"
        local reset_day=$(echo "${RESET_DAYS[$i]}" | tr -d ' ')

        if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || [ "$reset_day" -lt 0 ] || [ "$reset_day" -gt 31 ]; then
            echo -e "${RED}$(get_port_display_name "$port") 重置日期无效: $reset_day，必须是0-31之间的数字${NC}"
            continue
        fi

        if [ "$reset_day" = "0" ]; then
            jq "del(.ports.\"$port\".quota.reset_day)" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 已取消自动重置${NC}"
        else
            local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
            if [ "$monthly_limit" = "unlimited" ]; then
                echo -e "${YELLOW}$(get_port_display_name "$port") 未设置流量配额，请先通过「端口限制设置管理→设置端口流量配额」设置配额后再设置重置日${NC}"
                continue
            fi
            update_config ".ports.\"$port\".quota.reset_day = $reset_day"
            setup_port_auto_reset_cron "$port"
            echo -e "${GREEN}$(get_port_display_name "$port") 月重置日设置成功: 每月${reset_day}日${NC}"
        fi
        
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的月重置日期${NC}"

    sleep 2
    manage_traffic_reset
}

immediate_reset() {
    echo -e "${BLUE}=== 立即重置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read_user_choice manage_traffic_reset "请选择要立即重置的端口（多端口使用逗号,分隔） [0返回,1-${#active_ports[@]}]: " choice_input || return

    local valid_choices=()
    local ports_to_reset=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_reset+=("$port")
    done

    if [ ${#ports_to_reset[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可重置${NC}"
        sleep 2
        immediate_reset
        return
    fi

    echo
    echo "将重置以下端口的流量统计:"
    local total_all_traffic=0
    for port in "${ports_to_reset[@]}"; do
        [ "$port" = "$VPS_PORT_ID" ] && collect_vps_traffic

        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)

        echo "  $(get_port_display_name "$port"): $total_formatted"
        total_all_traffic=$((total_all_traffic + total_bytes))
    done

    echo
    echo "总计流量: $(format_bytes $total_all_traffic)"
    echo -e "${YELLOW}警告：重置后流量统计将清零，此操作不可撤销！${NC}"
    read -p "确认重置选定端口的流量统计? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local reset_count=0
        for port in "${ports_to_reset[@]}"; do
            [ "$port" = "$VPS_PORT_ID" ] && collect_vps_traffic
            local traffic_data=($(get_nftables_counter_data "$port"))
            local input_bytes=${traffic_data[0]}
            local output_bytes=${traffic_data[1]}
            local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
            local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

            reset_port_nftables_counters "$port"
            record_reset_history "$port" "$total_bytes"

            echo -e "${GREEN}$(get_port_display_name "$port") 流量统计重置成功${NC}"
            reset_count=$((reset_count + 1))
        done

        echo
        echo -e "${GREEN}成功重置 $reset_count 个端口的流量统计${NC}"
        echo "重置前总流量: $(format_bytes $total_all_traffic)"
    else
        echo "取消重置"
    fi

    sleep 3
    manage_traffic_reset
}

auto_reset_port() {
    local port="$1"

    [ "$port" = "$VPS_PORT_ID" ] && collect_vps_traffic

    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

    reset_port_nftables_counters "$port"
    record_reset_history "$port" "$total_bytes"

    local port_label=$(get_port_display_name "$port")

    log_notification "$port_label 自动重置完成，重置前流量: $(format_bytes $total_bytes)"

    echo "$port_label 自动重置完成"
}

reset_port_nftables_counters() {
    local port=$1

    if [ "$port" = "$VPS_PORT_ID" ]; then
        vps_lock
        local data=$(vps_read_data)
        local new_data=$(printf '%s' "$data" | jq -c --arg now "$(get_beijing_time +%s)" \
            '.monthly = {ifaces: {}, reset_at: ($now | tonumber)}' 2>/dev/null) || new_data="$data"
        vps_write_data "$new_data"
        vps_unlock
        return 0
    fi

    NFT_TABLE_CACHE=""
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_key=$(get_counter_key "$port")
    local in_name=$(get_counter_name "$counter_key" in)
    local out_name=$(get_counter_name "$counter_key" out)
    local quota_name=$(get_quota_name "$counter_key")

    nft reset counter $family $table_name "$in_name" >/dev/null 2>&1 || true
    nft reset counter $family $table_name "$out_name" >/dev/null 2>&1 || true
    nft reset quota $family $table_name "$quota_name" >/dev/null 2>&1 || true
}

record_reset_history() {
    local port=$1
    local traffic_bytes=$2
    local timestamp=$(get_beijing_time +%s)
    local history_file="$CONFIG_DIR/reset_history.log"

    mkdir -p "$(dirname "$history_file")"

    echo "$timestamp|$port|$traffic_bytes" >> "$history_file"

    if [ $(wc -l < "$history_file" 2>/dev/null || echo 0) -gt 100 ]; then
        tail -n 100 "$history_file" > "${history_file}.tmp"
        mv "${history_file}.tmp" "$history_file"
    fi
}

manage_configuration() {
    echo -e "${BLUE}=== 配置文件管理 ===${NC}"
    echo
    echo "请选择操作:"
    echo "1. 导出配置包"
    echo "2. 导入配置包"
    echo "0. 返回上级菜单"
    echo
    read -p "请输入选择 [0-2]: " choice

    case $choice in
        1) export_config ;;
        2) import_config ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_configuration ;;
    esac
}

export_config() {
    echo -e "${BLUE}=== 导出配置包 ===${NC}"
    echo

    if [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${RED}错误：配置目录不存在${NC}"
        sleep 2
        manage_configuration
        return
    fi

    local timestamp=$(get_beijing_time +%Y%m%d-%H%M%S)
    local backup_name="port-traffic-dog-config-${timestamp}.tar.gz"
    local backup_path="/root/${backup_name}"

    echo "正在导出配置包..."
    echo "包含内容："
    echo "  - 主配置文件 (config.json)"
    echo "  - 端口监控数据"
    echo "  - 整机流量数据"
    echo "  - 通知配置"
    echo "  - 日志文件"
    echo

    local temp_dir=$(mktemp -d)
    local package_dir="$temp_dir/port-traffic-dog-config"

    collect_vps_traffic

    cp -r "$CONFIG_DIR" "$package_dir"

    cat > "$package_dir/package_info.txt" << EOF
===================
导出时间: $(get_beijing_time '+%Y-%m-%d %H:%M:%S')
脚本版本: $SCRIPT_VERSION
配置目录: $CONFIG_DIR
导出主机: $(hostname)
包含端口: $(jq -r '.ports | keys | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "无")
EOF

    cd "$temp_dir"
    tar -czf "$backup_path" port-traffic-dog-config/ 2>/dev/null

    rm -rf "$temp_dir"

    if [ -f "$backup_path" ]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        echo -e "${GREEN}配置包导出成功${NC}"
        echo
        echo "文件信息："
        echo "  文件名: $backup_name"
        echo "  路径: $backup_path"
        echo "  大小: $file_size"
    else
        echo -e "${RED}配置包导出失败${NC}"
    fi

    echo
    read -p "按回车键返回..."
    manage_configuration
}

import_config() {
    echo -e "${BLUE}=== 导入配置包 ===${NC}"
    echo

    echo "请输入配置包路径 (支持绝对路径或相对路径):"
    echo "例如: /root/port-traffic-dog-config-20241227-143022.tar.gz"
    echo
    read -p "配置包路径: " package_path

    if [ -z "$package_path" ]; then
        echo -e "${RED}错误：路径不能为空${NC}"
        sleep 2
        import_config
        return
    fi

    if [ ! -f "$package_path" ]; then
        echo -e "${RED}错误：配置包文件不存在${NC}"
        echo "路径: $package_path"
        sleep 2
        import_config
        return
    fi

    if [[ ! "$package_path" =~ \.tar\.gz$ ]]; then
        echo -e "${RED}错误：配置包必须是 .tar.gz 格式${NC}"
        sleep 2
        import_config
        return
    fi

    echo
    echo "正在验证配置包..."

    local temp_dir=$(mktemp -d)

    cd "$temp_dir"
    if ! tar -tzf "$package_path" >/dev/null 2>&1; then
        echo -e "${RED}错误：配置包文件损坏或格式错误${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    
    tar -xzf "$package_path" 2>/dev/null

    
    local config_dir_name=$(ls | head -n1)
    if [ ! -d "$config_dir_name" ]; then
        echo -e "${RED}错误：配置包结构异常${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    local extracted_config="$temp_dir/$config_dir_name"

    if [ ! -f "$extracted_config/config.json" ]; then
        echo -e "${RED}错误：配置包中缺少 config.json 文件${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    echo -e "${GREEN}配置包验证通过${NC}"
    echo

    if [ -f "$extracted_config/package_info.txt" ]; then
        echo -e "${GREEN}端口流量狗配置包信息：${NC}"
        cat "$extracted_config/package_info.txt"
        echo
    fi

    local import_ports=$(jq -r '.ports | keys | join(", ")' "$extracted_config/config.json" 2>/dev/null || echo "无")
    echo "包含端口: $import_ports"
    echo

    
    echo -e "${YELLOW}警告：导入配置将会：${NC}"
    echo "  1. 停止当前所有端口监控"
    echo "  2. 替换为新的配置"
    echo "  3. 重新应用监控规则"
    echo
    read -p "确认导入配置包? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消导入"
        rm -rf "$temp_dir"
        sleep 1
        manage_configuration
        return
    fi

    echo
    echo "开始导入配置..."

    echo "正在停止当前端口监控..."
    local current_ports=($(get_active_ports 2>/dev/null || true))
    for port in "${current_ports[@]}"; do
        remove_nftables_rules "$port" 2>/dev/null || true
        remove_tc_limit "$port" 2>/dev/null || true
    done

    
    echo "正在导入新配置..."
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$CONFIG_DIR")"
    cp -r "$extracted_config" "$CONFIG_DIR"

    
    echo "正在重新应用监控规则..."

    
    init_nftables

    ensure_vps_port_config

    
    local new_ports=($(get_active_ports))
    for port in "${new_ports[@]}"; do
        add_nftables_rules "$port"

        local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // false" "$CONFIG_FILE")
        local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            apply_nftables_quota "$port" "$monthly_limit"
        fi

        
        local limit_enabled=$(jq -r ".ports.\"$port\".bandwidth_limit.enabled // false" "$CONFIG_FILE")
        local rate_limit=$(jq -r ".ports.\"$port\".bandwidth_limit.rate // \"unlimited\"" "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                apply_tc_limit "$port" "$tc_limit" || true
            fi
        fi
    done

    echo "正在更新通知模块..."
    download_notification_modules >/dev/null 2>&1 || true

    rm -rf "$temp_dir"

    echo
    echo -e "${GREEN}配置导入完成${NC}"
    echo
    echo "导入结果："
    echo "  导入端口数: ${#new_ports[@]} 个"
    if [ ${#new_ports[@]} -gt 0 ]; then
        echo "  端口列表: $(IFS=','; echo "${new_ports[*]}")"
    fi
    echo
    echo -e "${YELLOW}提示：${NC}"
    echo "  - 所有端口监控规则已重新应用"
    echo "  - 通知配置已恢复"
    echo "  - 历史数据已恢复"

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 先写临时文件再原子替换：curl -o 会直接截断目标，下载中断时半截文件会覆盖原文件
download_with_sources() {
    local url="$1" target="$2"
    local tmp_dir tmp
    tmp_dir=$(mktemp -d "${target}.download.XXXXXX") || return 1
    tmp="$tmp_dir/file"

    if curl -fsSL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] &&
       mv -fT -- "$tmp" "$target"; then
        rmdir "$tmp_dir"
        echo -e "${GREEN}下载成功${NC}"
        return 0
    fi

    rm -f -- "$tmp"
    rmdir "$tmp_dir"
    echo -e "${RED}下载失败${NC}"
    return 1
}

download_notification_modules() {
    local notifications_dir="$CONFIG_DIR/notifications"
    local temp_dir=$(mktemp -d)
    local repo_url="https://github.com/zywe03/realm-xwPF/archive/refs/heads/main.zip"

    if download_with_sources "$repo_url" "$temp_dir/repo.zip" &&
       (cd "$temp_dir" && unzip -q repo.zip) &&
       rm -rf "$notifications_dir" &&
       cp -r "$temp_dir/realm-xwPF-main/notifications" "$notifications_dir" &&
       chmod +x "$notifications_dir"/*.sh; then
        rm -rf "$temp_dir"
        return 0
    else
        rm -rf "$temp_dir"
        return 1
    fi
}

install_update_script() {
    echo -e "${BLUE}安装依赖(更新)脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}正在检查系统依赖...${NC}"
    check_dependencies true

    echo -e "${YELLOW}正在检查脚本更新...${NC}"
    local remote_ver=$(curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT \
        "$SCRIPT_URL" 2>/dev/null | \
        grep -E '^readonly SCRIPT_VERSION=' | head -1 | cut -d'"' -f2)

    if [ -z "$remote_ver" ]; then
        echo -e "${RED}无法获取远端版本，请检查网络连接${NC}"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        echo -e "${GREEN}✓ 脚本已是最新版本 ($SCRIPT_VERSION)${NC}"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    echo -e "${YELLOW}发现脚本新版本: ${SCRIPT_VERSION} → ${remote_ver}${NC}"
    read -p "是否更新脚本？(y/n) [默认: y]: " update_choice
    update_choice="${update_choice:-y}"
    if ! [[ "$update_choice" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}使用现有版本${NC}"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    local temp_file=$(mktemp)
    if ! download_with_sources "$SCRIPT_URL" "$temp_file"; then
        echo -e "${RED} 下载失败，请检查网络连接${NC}"
        rm -f "$temp_file"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    if [ ! -s "$temp_file" ] || ! grep -q "端口流量狗" "$temp_file" 2>/dev/null; then
        echo -e "${RED} 下载文件验证失败${NC}"
        rm -f "$temp_file"
        echo "────────────────────────────────────────────────────────"
        read -p "按回车键返回..."
        show_main_menu
        return
    fi

    mv "$temp_file" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    create_shortcut_command

    echo -e "${YELLOW}正在更新通知模块...${NC}"
    download_notification_modules >/dev/null 2>&1 || true

    echo -e "${GREEN}脚本已更新到 ${remote_ver}${NC}"
    echo -e "${GREEN}通知模块已更新${NC}"
    echo -e "${YELLOW}正在重启脚本使新版本生效...${NC}"
    sleep 1
    exec bash "$SCRIPT_PATH"
}

create_shortcut_command() {
    if [ ! -f "/usr/local/bin/$SHORTCUT_COMMAND" ]; then
        cat > "/usr/local/bin/$SHORTCUT_COMMAND" << EOF
#!/bin/bash
exec bash "$SCRIPT_PATH" "\$@"
EOF
        chmod +x "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        echo -e "${GREEN}快捷命令 '$SHORTCUT_COMMAND' 创建成功${NC}"
    fi
}

uninstall_script() {
    echo -e "${BLUE}卸载脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}将要删除以下内容:${NC}"
    echo "  - 脚本文件: $SCRIPT_PATH"
    echo "  - 快捷命令: /usr/local/bin/$SHORTCUT_COMMAND"
    echo "  - 配置目录: $CONFIG_DIR"
    echo "  - 所有nftables规则"
    echo "  - 所有TC限制规则"
    echo "  - 整机流量监控及数据"
    echo "  - 通知定时任务"
    echo
    echo -e "${RED}警告：此操作将完全删除端口流量狗及其所有数据！${NC}"
    read -p "确认卸载? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"

        local active_ports=($(get_active_ports 2>/dev/null || true))
        for port in "${active_ports[@]}"; do
            remove_nftables_rules "$port" 2>/dev/null || true
            remove_tc_limit "$port" 2>/dev/null || true
        done

        local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE" 2>/dev/null || echo "port_traffic_monitor")
        local family=$(jq -r '.nftables.family' "$CONFIG_FILE" 2>/dev/null || echo "inet")
        nft delete table $family $table_name >/dev/null 2>&1 || true

        remove_telegram_notification_cron 2>/dev/null || true
        remove_webhook_notification_cron 2>/dev/null || true
        remove_restore_cron 2>/dev/null || true
        remove_vps_collect_cron 2>/dev/null || true
        remove_expiry_check_cron 2>/dev/null || true

        rm -rf "$CONFIG_DIR" 2>/dev/null || true
        rm -f "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        rm -f "$SCRIPT_PATH" 2>/dev/null || true

        echo -e "${GREEN}卸载完成！${NC}"
        echo -e "${YELLOW}感谢使用端口流量狗！${NC}"
        exit 0
    else
        echo "取消卸载"
        sleep 1
        show_main_menu
    fi
}

manage_notifications() {
    echo -e "${BLUE}=== 通知管理 ===${NC}"
    echo "1. Telegram机器人通知"
    echo "2. Webhook通知 (企业微信/飞书/钉钉)"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) manage_telegram_notifications ;;
        2) manage_webhook_notifications ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_notifications ;;
    esac
}

manage_telegram_notifications() {
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"

    if [ -f "$telegram_script" ]; then
        export_notification_functions
        source "$telegram_script"
        telegram_configure
        manage_notifications
    else
        echo -e "${RED}Telegram 通知模块不存在${NC}"
        echo "请检查文件: $telegram_script"
        sleep 2
        manage_notifications
    fi
}

manage_webhook_notifications() {
    local webhook_script="$CONFIG_DIR/notifications/webhook.sh"

    if [ -f "$webhook_script" ]; then
        export_notification_functions
        source "$webhook_script"
        webhook_configure
        manage_notifications
    else
        echo -e "${RED}Webhook 通知模块不存在${NC}"
        echo "请检查文件: $webhook_script"
        sleep 2
        manage_notifications
    fi
}

setup_telegram_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true

    local telegram_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$telegram_enabled" = "true" ]; then
        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")
        case "$status_interval" in
            "1m")  echo "* * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

setup_webhook_notification_cron() {
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗Webhook通知" > "$temp_cron" || true

    local webhook_enabled=$(jq -r '.notifications.webhook.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$webhook_enabled" = "true" ]; then
        local webhook_interval=$(jq -r '.notifications.webhook.status_notifications.interval' "$CONFIG_FILE")
        case "$webhook_interval" in
            "1m")  echo "* * * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "15m") echo "*/15 * * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "30m") echo "*/30 * * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "1h")  echo "0 * * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "2h")  echo "0 */2 * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "6h")  echo "0 */6 * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "12h") echo "0 */12 * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
            "24h") echo "0 0 * * * $script_path --send-webhook-status >/dev/null 2>&1  # 端口流量狗Webhook通知" >> "$temp_cron" ;;
        esac
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

select_notification_interval() {
    echo "请选择状态通知发送间隔:" >&2
    echo "1. 1分钟   2. 15分钟  3. 30分钟  4. 1小时" >&2
    echo "5. 2小时   6. 6小时   7. 12小时  8. 24小时" >&2
    read -p "请选择(回车默认1小时) [1-8]: " interval_choice >&2

    local interval="1h"
    case $interval_choice in
        1) interval="1m" ;;
        2) interval="15m" ;;
        3) interval="30m" ;;
        4|"") interval="1h" ;;
        5) interval="2h" ;;
        6) interval="6h" ;;
        7) interval="12h" ;;
        8) interval="24h" ;;
        *) interval="1h" ;;
    esac

    echo "$interval"
}

remove_telegram_notification_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_webhook_notification_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗Webhook通知" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_restore_cron() {
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# 端口流量狗开机自恢复" > "$temp_cron" || true
    crontab "$temp_cron"
    rm -f "$temp_cron"
}

export_notification_functions() {
    export -f setup_telegram_notification_cron
    export -f setup_webhook_notification_cron
    export -f select_notification_interval
}

setup_port_auto_reset_cron() {
    local port="$1"
    local script_path="$SCRIPT_PATH"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "端口流量狗自动重置端口$port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
    local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
    local reset_day_raw=$(jq -r ".ports.\"$port\".quota.reset_day" "$CONFIG_FILE")
    
    if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ] && [ "$reset_day_raw" != "null" ]; then
        local reset_day="${reset_day_raw:-1}"
        echo "5 0 $reset_day * * $script_path --reset-port $port >/dev/null 2>&1  # 端口流量狗自动重置端口$port" >> "$temp_cron"
    fi

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

remove_port_auto_reset_cron() {
    local port="$1"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "端口流量狗自动重置端口$port" | grep -v "port-traffic-dog.*--reset-port $port" > "$temp_cron" || true

    crontab "$temp_cron"
    rm -f "$temp_cron"
}

format_status_message() {
    local server_name="${1:-$(hostname)}"  # 接受服务器名称参数
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="<b>${notification_icon} 端口流量狗 v${SCRIPT_VERSION}</b> | ⏰ ${timestamp}
了解更多:<code>https://zywe.de</code> | 项目开源:<code>https://github.com/zywe03/realm-xwPF</code>
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog
---
$(format_vps_traffic_line "plain")
状态: 监控中 | 监控项: ${port_count}个 | 端口总流量: ${daily_total}
────────────────────────────────────────
<pre>$(format_port_list "message")</pre>
────────────────────────────────────────
🔗 服务器: <i>${server_name}</i>"

    echo "$message"
}

format_text_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="${notification_icon} 端口流量狗 v${SCRIPT_VERSION} | ⏰ ${timestamp}
了解更多: https://zywe.de | 项目开源: https://github.com/zywe03/realm-xwPF
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog
---
$(format_vps_traffic_line "plain")
状态: 监控中 | 监控项: ${port_count}个 | 端口总流量: ${daily_total}
────────────────────────────────────────
$(format_port_list "message")
────────────────────────────────────────
🔗 服务器: ${server_name}"

    echo "$message"
}

format_markdown_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local notification_icon="🔔"
    local active_ports=($(get_monitored_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="**${notification_icon} 端口流量狗 v${SCRIPT_VERSION}** | ⏰ ${timestamp}
了解更多: \`https://zywe.de\` | 项目开源: \`https://github.com/zywe03/realm-xwPF\`
一只轻巧的'守护犬'，时刻守护你的端口流量 | 快捷命令: dog
---
$(format_vps_traffic_line "markdown")
**状态**: 监控中 | **监控项**: ${port_count}个 | **端口总流量**: ${daily_total}
────────────────────────────────────────
$(format_port_list "markdown")
────────────────────────────────────────
🔗 **服务器**: ${server_name}"

    echo "$message"
}

log_notification() {
    local message="$1"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local log_file="$CONFIG_DIR/logs/notification.log"

    mkdir -p "$(dirname "$log_file")"

    echo "[$timestamp] $message" >> "$log_file"

    if [ -f "$log_file" ] && [ $(wc -l < "$log_file") -gt 1000 ]; then
        tail -n 500 "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"
    fi
}

send_status_notification() {
    local success_count=0
    local total_count=0

    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
    if [ -f "$telegram_script" ]; then
        source "$telegram_script"
        total_count=$((total_count + 1))
        if telegram_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    local webhook_script="$CONFIG_DIR/notifications/webhook.sh"
    if [ -f "$webhook_script" ]; then
        source "$webhook_script"
        total_count=$((total_count + 1))
        if webhook_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    if [ $total_count -eq 0 ]; then
        log_notification "通知模块不存在"
        echo -e "${RED}通知模块不存在${NC}"
        return 1
    elif [ $success_count -gt 0 ]; then
        echo -e "${GREEN}状态通知发送成功 ($success_count/$total_count)${NC}"
        return 0
    else
        echo -e "${RED}状态通知发送失败${NC}"
        return 1
    fi
}

ensure_monitoring_state() {
    mkdir -p "$CONFIG_DIR"
    exec 9>"$CONFIG_DIR/.restore.lock"
    flock 9
    init_nftables
    restore_monitoring_if_needed
    flock -u 9 2>/dev/null || true
    exec 9>&-
}

main() {
    check_root

    if [ $# -gt 0 ]; then
        case $1 in
            --collect-vps-traffic)
                collect_vps_traffic
                exit 0
                ;;
            --restore-monitoring)
                ensure_monitoring_state
                collect_vps_traffic
                exit 0
                ;;
            --check-expiry)
                ensure_monitoring_state
                check_all_expiry
                exit 0
                ;;
            --reset-port)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--reset-port 需要指定端口号${NC}"
                    exit 1
                fi
                ensure_monitoring_state
                collect_vps_traffic
                auto_reset_port "$2"
                save_traffic_data
                exit 0
                ;;
            --send-telegram-status)
                local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
                ensure_monitoring_state
                collect_vps_traffic
                save_traffic_data
                if [ -f "$telegram_script" ]; then
                    source "$telegram_script"
                    telegram_send_status_notification
                fi
                exit 0
                ;;
            --send-webhook-status)
                local webhook_script="$CONFIG_DIR/notifications/webhook.sh"
                ensure_monitoring_state
                collect_vps_traffic
                save_traffic_data
                if [ -f "$webhook_script" ]; then
                    source "$webhook_script"
                    webhook_send_status_notification
                fi
                exit 0
                ;;
            --send-status)
                ensure_monitoring_state
                collect_vps_traffic
                save_traffic_data
                send_status_notification
                exit 0
                ;;
        esac
    fi

    check_dependencies
    init_config
    create_shortcut_command

    if [ $# -gt 0 ]; then
        case $1 in
            --check-deps)
                echo -e "${GREEN}依赖检查通过${NC}"
                exit 0
                ;;
            --version)
                echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
                echo -e "${GREEN}了解更多:${NC} https://zywe.de"
                echo -e "${GREEN}项目开源:${NC} https://github.com/zywe03/realm-xwPF"
                exit 0
                ;;
            --install)
                install_update_script
                exit 0
                ;;
            --uninstall)
                uninstall_script
                exit 0
                ;;
            *)
                echo -e "${YELLOW}用法: $0 [选项]${NC}"
                echo "选项:"
                echo "  --check-deps              检查依赖工具"
                echo "  --version                 显示版本信息"
                echo "  --install                 安装/更新脚本"
                echo "  --uninstall               卸载脚本"
                echo "  --send-status             发送所有启用的状态通知"
                echo "  --send-telegram-status    发送Telegram状态通知"
                echo "  --send-webhook-status     发送Webhook状态通知"
                echo "  --reset-port PORT         重置指定监控项流量（支持端口/端口段/端口组）"
                echo "  --collect-vps-traffic     采集整机流量(整机流量监控用)"
                echo "  --restore-monitoring      重建丢失的监控规则(开机自恢复用)"
                echo "  --check-expiry            检查端口截止日期并阻断到期端口(每日cron用)"
                echo
                echo -e "${GREEN}快捷命令: $SHORTCUT_COMMAND${NC}"
                exit 1
                ;;
        esac
    fi

    show_main_menu
}

main "$@"
