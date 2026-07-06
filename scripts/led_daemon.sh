#!/bin/bash

# LLLED LED守护进程 - smartctl硬盘健康检测版
# 使用smartctl检测硬盘健康状态，绿色=健康，红色=异常

# 服务配置
SERVICE_NAME="ugreen-led-monitor"
LLLED_VERSION="4.0.0"

# 路径配置
SCRIPT_DIR="/opt/ugreen-led-controller"
CONFIG_DIR="$SCRIPT_DIR/config"
LOG_DIR="/var/log/llled"
PID_FILE="/var/run/${SERVICE_NAME}.pid"
LOG_FILE="$LOG_DIR/${SERVICE_NAME}.log"
UGREEN_CLI="$SCRIPT_DIR/ugreen_leds_cli"

# 配置文件路径
LED_CONFIG="$CONFIG_DIR/led_mapping.conf"
HCTL_CONFIG="$CONFIG_DIR/hctl_mapping.conf"
DISK_CONFIG="$CONFIG_DIR/disk_mapping.conf"
GLOBAL_CONFIG="$CONFIG_DIR/global_config.conf"

# 全局变量
declare -A DISK_LED_MAP
declare -A DISK_HCTL_MAP
declare -A DISK_STATUS_CACHE
declare -A LED_STATUS_CACHE
AVAILABLE_LEDS=()
actual_disk_leds=()
DAEMON_RUNNING=true
CHECK_INTERVAL=30
LAST_FORCE_UPDATE=0

# 创建必要目录
mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR"

# 日志函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "ERROR"|"WARN"|"INFO")
            echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
            ;;
        "DEBUG")
            if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
                echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
            fi
            ;;
    esac

    if [[ "${DEBUG_MODE:-false}" == "true" || "$level" != "DEBUG" ]]; then
        echo "[$timestamp] [$level] $message"
    fi
}

# 清除日志文件
clear_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "清除日志文件: $LOG_FILE"
        > "$LOG_FILE"
        log_message "INFO" "日志文件已清除"
        echo "日志已清除"
    else
        echo "日志文件不存在: $LOG_FILE"
    fi
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "需要root权限运行后台服务"
        exit 1
    fi
}

# 加载配置文件
load_configs() {
    if [[ -f "$LED_CONFIG" ]]; then
        source "$LED_CONFIG" 2>/dev/null || true
        log_message "INFO" "已加载LED映射配置: $LED_CONFIG"
    else
        log_message "WARN" "LED映射配置文件不存在: $LED_CONFIG"
    fi

    if [[ -f "$GLOBAL_CONFIG" ]]; then
        source "$GLOBAL_CONFIG" 2>/dev/null || true
        log_message "DEBUG" "已加载全局配置: $GLOBAL_CONFIG"
    else
        log_message "WARN" "全局配置文件不存在: $GLOBAL_CONFIG"
    fi

    # 设置默认值
    CHECK_INTERVAL=${CHECK_INTERVAL:-30}
    DEBUG_MODE=${DEBUG_MODE:-false}
    DEFAULT_BRIGHTNESS=${DEFAULT_BRIGHTNESS:-64}

    # 健康状态颜色 - 仅红绿两色
    DISK_COLOR_HEALTHY=${DISK_COLOR_HEALTHY:-"0 255 0"}     # 绿色 - SMART健康
    DISK_COLOR_UNHEALTHY=${DISK_COLOR_UNHEALTHY:-"255 0 0"}  # 红色 - SMART异常

    log_message "INFO" "配置加载完成 - 检查间隔: ${CHECK_INTERVAL}s"
}

# 检查LED控制程序
check_led_cli() {
    if [[ ! -x "$UGREEN_CLI" ]]; then
        log_message "ERROR" "LED控制程序不存在: $UGREEN_CLI"
        return 1
    fi

    if ! timeout 5 "$UGREEN_CLI" power -status >/dev/null 2>&1; then
        log_message "ERROR" "LED控制程序测试失败"
        return 1
    fi

    return 0
}

# 智能配置生成 - 基于HCTL顺序和LED检测
smart_config_generation() {
    log_message "INFO" "开始智能配置生成..."

    local detected_disk_leds=()
    local detected_system_leds=()

    log_message "INFO" "检测可用LED..."

    # 检测硬盘LED (disk1-disk15)
    for i in {1..15}; do
        local led_name="disk$i"
        if timeout 3 "$UGREEN_CLI" "$led_name" -status >/dev/null 2>&1; then
            detected_disk_leds+=("$led_name")
            log_message "INFO" "检测到硬盘LED: $led_name"
        else
            local fail_count=0
            for j in $((i+1)) $((i+2)) $((i+3)); do
                if ! timeout 3 "$UGREEN_CLI" "disk$j" -status >/dev/null 2>&1; then
                    ((fail_count++))
                else
                    break
                fi
            done
            if [[ $fail_count -eq 3 ]]; then
                log_message "INFO" "连续探测失败，停止硬盘LED探测"
                break
            fi
        fi
    done

    # 检测系统LED
    if timeout 3 "$UGREEN_CLI" power -status >/dev/null 2>&1; then
        detected_system_leds+=("power")
        log_message "INFO" "检测到电源LED: power"
    fi
    if timeout 3 "$UGREEN_CLI" netdev -status >/dev/null 2>&1; then
        detected_system_leds+=("netdev")
        log_message "INFO" "检测到网络LED: netdev"
    fi

    log_message "INFO" "LED检测完成 - 硬盘LED: ${#detected_disk_leds[@]}个, 系统LED: ${#detected_system_leds[@]}个"

    # 检测硬盘HCTL信息
    log_message "INFO" "检测硬盘HCTL信息..."
    local hctl_disks=()
    declare -A local_disk_hctl_map=()

    while IFS= read -r line; do
        [[ "$line" =~ ^NAME ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^([a-z]+)[[:space:]]+([0-9]+:[0-9]+:[0-9]+:[0-9]+)[[:space:]]*(.*)$ ]]; then
            local disk_name="${BASH_REMATCH[1]}"
            local hctl_addr="${BASH_REMATCH[2]}"
            local serial="${BASH_REMATCH[3]:-unknown}"

            local disk_device="/dev/$disk_name"
            hctl_disks+=("$disk_device")
            local_disk_hctl_map["$disk_device"]="$hctl_addr|$serial"

            log_message "INFO" "检测到硬盘: $disk_device (HCTL: $hctl_addr)"
        fi
    done < <(lsblk -S -x hctl -o name,hctl,serial 2>/dev/null)

    log_message "INFO" "HCTL检测完成 - 共检测到 ${#hctl_disks[@]} 个硬盘"

    # 生成LED映射配置
    log_message "INFO" "生成LED映射配置文件..."
    cat > "$LED_CONFIG" << EOF
# LED映射配置文件 - 智能生成
# 生成时间: $(date)

# LED设备地址配置
I2C_BUS=1
I2C_DEVICE_ADDR=0x3a

EOF

    if [[ ${#detected_disk_leds[@]} -gt 0 ]]; then
        echo "# 硬盘LED映射" >> "$LED_CONFIG"
        for i in "${!detected_disk_leds[@]}"; do
            local led_name="${detected_disk_leds[$i]}"
            local led_num=$((i + 1))
            local led_id=$((i + 2))

            echo "DISK${led_num}_LED=$led_id" >> "$LED_CONFIG"
            echo "$led_name=$led_id" >> "$LED_CONFIG"
        done
        echo "" >> "$LED_CONFIG"
    fi

    cat >> "$LED_CONFIG" << 'EOF'
# 系统LED
POWER_LED=0
power=0
NETDEV_LED=1
netdev=1

# 颜色配置 - smartctl健康检测
DISK_COLOR_HEALTHY="0 255 0"
DISK_COLOR_UNHEALTHY="255 0 0"
DEFAULT_BRIGHTNESS=64
EOF

    # 生成HCTL映射配置
    log_message "INFO" "生成HCTL映射配置文件..."
    cat > "$HCTL_CONFIG" << EOF
# HCTL硬盘映射配置文件 - 智能生成
# 生成时间: $(date)

EOF

    local mapped_count=0
    for i in "${!hctl_disks[@]}"; do
        local disk_device="${hctl_disks[$i]}"
        local hctl_info="${local_disk_hctl_map[$disk_device]}"

        if [[ $i -lt ${#detected_disk_leds[@]} ]]; then
            local led_name="${detected_disk_leds[$i]}"

            local model
            model=$(lsblk -dno model "$disk_device" 2>/dev/null || echo "Unknown")
            local size
            size=$(lsblk -dno size "$disk_device" 2>/dev/null || echo "Unknown")

            echo "HCTL_MAPPING[$disk_device]=\"$hctl_info|$led_name|$model|$size\"" >> "$HCTL_CONFIG"

            DISK_LED_MAP["$disk_device"]="$led_name"

            ((mapped_count++))
            log_message "INFO" "映射: $disk_device -> $led_name (HCTL: ${hctl_info%|*})"
        else
            log_message "WARN" "硬盘 $disk_device 无对应LED，跳过映射"
            echo "# $disk_device - 无对应LED" >> "$HCTL_CONFIG"
        fi
    done

    # 生成硬盘映射配置
    log_message "INFO" "生成硬盘映射配置文件..."
    cat > "$DISK_CONFIG" << EOF
# 硬盘映射配置文件 - 智能生成
# 生成时间: $(date)
# 格式: /dev/sdX=diskY

EOF

    for i in "${!hctl_disks[@]}"; do
        local disk_device="${hctl_disks[$i]}"
        if [[ $i -lt ${#detected_disk_leds[@]} ]]; then
            local led_name="${detected_disk_leds[$i]}"
            echo "$disk_device=$led_name" >> "$DISK_CONFIG"
        fi
    done

    AVAILABLE_LEDS=("${detected_disk_leds[@]}" "${detected_system_leds[@]}")
    actual_disk_leds=("${detected_disk_leds[@]}")

    log_message "INFO" "智能配置生成完成"
    log_message "INFO" "可用硬盘LED: ${detected_disk_leds[*]}"
    log_message "INFO" "检测到硬盘: ${hctl_disks[*]}"
    log_message "INFO" "成功映射: $mapped_count 个硬盘到LED"

    return 0
}

# 动态检测可用LED
detect_available_leds() {
    log_message "INFO" "动态检测可用LED..."
    AVAILABLE_LEDS=()

    local need_smart_config=false

    if [[ ! -f "$LED_CONFIG" || ! -s "$LED_CONFIG" ]]; then
        log_message "INFO" "LED映射配置不存在或为空"
        need_smart_config=true
    fi

    if [[ ! -f "$HCTL_CONFIG" || ! -s "$HCTL_CONFIG" ]]; then
        log_message "INFO" "HCTL映射配置不存在或为空"
        need_smart_config=true
    fi

    if [[ "$need_smart_config" == "true" ]]; then
        log_message "INFO" "配置文件缺失，执行智能配置生成..."
        if smart_config_generation; then
            log_message "INFO" "智能配置生成完成"
            return 0
        else
            log_message "ERROR" "智能配置生成失败"
            return 1
        fi
    fi

    actual_disk_leds=()

    log_message "INFO" "从配置文件检测硬盘LED..."

    if [[ -f "$CONFIG_DIR/led_mapping.conf" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// }" ]] && continue

            if [[ $key =~ ^disk[0-9]+$ ]]; then
                local led_name="$key"
                log_message "DEBUG" "从配置检测硬盘LED: $led_name"

                if timeout 3 "$UGREEN_CLI" "$led_name" -status >/dev/null 2>&1; then
                    AVAILABLE_LEDS+=("$led_name")
                    actual_disk_leds+=("$led_name")
                    log_message "INFO" "确认硬盘LED: $led_name"
                else
                    log_message "WARN" "硬盘LED $led_name 检测失败"
                fi
            fi
        done < "$CONFIG_DIR/led_mapping.conf"
    else
        log_message "INFO" "配置文件不存在，动态探测硬盘LED..."
        for i in {1..15}; do
            local led_name="disk$i"
            if timeout 3 "$UGREEN_CLI" "$led_name" -status >/dev/null 2>&1; then
                AVAILABLE_LEDS+=("$led_name")
                actual_disk_leds+=("$led_name")
                log_message "INFO" "探测到硬盘LED: $led_name"
            else
                local fail_count=0
                for j in $((i+1)) $((i+2)) $((i+3)); do
                    if ! timeout 3 "$UGREEN_CLI" "disk$j" -status >/dev/null 2>&1; then
                        ((fail_count++))
                    else
                        break
                    fi
                done
                if [[ $fail_count -eq 3 ]]; then
                    log_message "INFO" "连续探测失败，停止硬盘LED探测"
                    break
                fi
            fi
        done
    fi

    # 检测电源LED
    log_message "INFO" "检测电源LED..."
    if timeout 3 "$UGREEN_CLI" power -status >/dev/null 2>&1; then
        AVAILABLE_LEDS+=("power")
        log_message "INFO" "检测到电源LED: power"
    else
        log_message "WARN" "电源LED检测失败，但保留功能"
        AVAILABLE_LEDS+=("power")
    fi

    # 检测网络LED
    log_message "INFO" "检测网络LED..."
    if timeout 3 "$UGREEN_CLI" netdev -status >/dev/null 2>&1; then
        AVAILABLE_LEDS+=("netdev")
        log_message "INFO" "检测到网络LED: netdev"
    else
        log_message "WARN" "网络LED检测失败，但保留功能"
        AVAILABLE_LEDS+=("netdev")
    fi

    log_message "INFO" "LED检测完成，共 ${#AVAILABLE_LEDS[@]} 个LED: ${AVAILABLE_LEDS[*]}"
    log_message "INFO" "硬盘LED: ${actual_disk_leds[*]}"

    if [[ ${#AVAILABLE_LEDS[@]} -eq 0 ]]; then
        log_message "ERROR" "未检测到任何可用LED"
        return 1
    fi

    local led_cache="$CONFIG_DIR/detected_leds.conf"
    echo "# 检测到的LED列表 - $(date)" > "$led_cache"
    echo "DETECTED_LEDS=(${AVAILABLE_LEDS[*]})" >> "$led_cache"
    echo "DISK_LEDS=(${actual_disk_leds[*]})" >> "$led_cache"

    return 0
}

# 使用smartctl获取硬盘健康状态
get_disk_health() {
    local disk="$1"

    # 检查设备文件是否存在
    if [[ ! -b "$disk" ]]; then
        echo "not_found"
        return 1
    fi

    # 使用smartctl -H检查硬盘健康状态
    local smart_output
    smart_output=$(timeout 15 smartctl -H "$disk" 2>&1)
    local smart_exit=$?

    # smartctl超时或失败
    if [[ $smart_exit -ne 0 ]]; then
        if [[ "$smart_output" =~ "No such file or directory" ]]; then
            log_message "WARN" "硬盘 $disk 设备不存在"
            echo "not_found"
            return 1
        elif [[ $smart_exit -eq 124 ]]; then
            log_message "WARN" "硬盘 $disk smartctl检测超时"
            echo "error"
            return 1
        else
            log_message "WARN" "硬盘 $disk smartctl执行失败 (退出码: $smart_exit)"
            echo "error"
            return 1
        fi
    fi

    # 解析smartctl输出
    # 兼容多种smartctl输出格式:
    # "SMART overall-health self-assessment test result: PASSED"
    # "SMART Health Status: OK"
    if echo "$smart_output" | grep -qiE "SMART overall-health self-assessment test result: PASSED"; then
        log_message "DEBUG" "硬盘 $disk SMART状态: 健康"
        echo "healthy"
        return 0
    elif echo "$smart_output" | grep -qiE "SMART Health Status: OK"; then
        log_message "DEBUG" "硬盘 $disk SMART状态: 健康"
        echo "healthy"
        return 0
    elif echo "$smart_output" | grep -qiE "PASSED"; then
        log_message "DEBUG" "硬盘 $disk SMART状态: 健康(PASSED)"
        echo "healthy"
        return 0
    elif echo "$smart_output" | grep -qiE "FAIL"; then
        log_message "WARN" "硬盘 $disk SMART状态: 异常(FAILED)"
        echo "unhealthy"
        return 0
    elif echo "$smart_output" | grep -qiE "SMART overall-health self-assessment test result: FAILED"; then
        log_message "WARN" "硬盘 $disk SMART状态: 异常"
        echo "unhealthy"
        return 0
    else
        # 无法确定状态，尝试检查是否SMART可用
        if echo "$smart_output" | grep -qiE "SMART support is: Available"; then
            log_message "DEBUG" "硬盘 $disk SMART可用但无法解析健康状态，视为健康"
            echo "healthy"
            return 0
        elif echo "$smart_output" | grep -qiE "SMART support is: Unavailable"; then
            log_message "WARN" "硬盘 $disk 不支持SMART"
            echo "error"
            return 1
        else
            log_message "WARN" "硬盘 $disk 无法解析SMART输出，视为未知"
            echo "error"
            return 1
        fi
    fi
}

# 加载HCTL映射
load_hctl_mapping() {
    log_message "INFO" "加载HCTL映射配置..."

    if [[ ! -f "$HCTL_CONFIG" ]]; then
        log_message "WARN" "HCTL配置文件不存在: $HCTL_CONFIG"
        return 1
    fi

    DISK_LED_MAP=()
    DISK_HCTL_MAP=()

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        if [[ "$line" =~ ^HCTL_MAPPING\[([^\]]+)\]=\"([^\"]+)\"$ ]]; then
            local disk_device="${BASH_REMATCH[1]}"
            local mapping_info="${BASH_REMATCH[2]}"

            IFS='|' read -r hctl_info led_pos serial model size <<< "$mapping_info"

            if [[ -n "$disk_device" && -n "$led_pos" ]]; then
                DISK_LED_MAP["$disk_device"]="$led_pos"
                DISK_HCTL_MAP["$disk_device"]="$hctl_info|$serial|$model|$size"
                log_message "DEBUG" "加载映射: $disk_device -> $led_pos (HCTL: $hctl_info)"
            fi
        fi
    done < "$HCTL_CONFIG"

    log_message "INFO" "已加载 ${#DISK_LED_MAP[@]} 个HCTL映射"
    return 0
}

# 重新获取HCTL映射
refresh_hctl_mapping() {
    log_message "INFO" "重新生成HCTL硬盘映射配置..."

    mkdir -p "$CONFIG_DIR"

    local hctl_script="$SCRIPT_DIR/scripts/smart_disk_activity_hctl.sh"
    if [[ -x "$hctl_script" ]]; then
        log_message "INFO" "调用HCTL检测脚本生成配置: $hctl_script"

        local hctl_output
        if hctl_output=$(timeout 30 "$hctl_script" --update-mapping --save-config 2>&1); then
            log_message "INFO" "HCTL配置生成成功"
            log_message "DEBUG" "HCTL脚本输出: $hctl_output"

            if [[ -f "$HCTL_CONFIG" ]]; then
                log_message "INFO" "确认配置文件已生成: $HCTL_CONFIG"
                local file_size
                file_size=$(stat -c%s "$HCTL_CONFIG" 2>/dev/null || echo "0")
                log_message "DEBUG" "配置文件大小: $file_size 字节"
            else
                log_message "WARN" "配置文件未生成: $HCTL_CONFIG"
            fi

            if load_hctl_mapping; then
                log_message "INFO" "HCTL映射配置重新加载完成"
                return 0
            else
                log_message "ERROR" "重新加载HCTL映射配置失败"
                return 1
            fi
        else
            log_message "ERROR" "HCTL配置生成失败或超时"
            log_message "ERROR" "HCTL脚本错误输出: $hctl_output"
            return 1
        fi
    else
        log_message "ERROR" "HCTL检测脚本不存在: $hctl_script"
        return 1
    fi
}

# 设置LED状态
set_led_status() {
    local led="$1"
    local color="$2"
    local brightness="${3:-$DEFAULT_BRIGHTNESS}"

    local cache_key="$led"
    local new_status="$color|$brightness"
    local cached_status="${LED_STATUS_CACHE[$cache_key]:-}"

    if [[ "$new_status" == "$cached_status" ]]; then
        log_message "DEBUG" "LED $led 状态未变化，跳过更新"
        return 0
    fi

    if [[ "$color" == "off" || "$color" == "0 0 0" ]]; then
        if timeout 5 "$UGREEN_CLI" "$led" -off >/dev/null 2>&1; then
            LED_STATUS_CACHE["$cache_key"]="off"
            log_message "DEBUG" "LED $led 已关闭"
            return 0
        else
            log_message "WARN" "关闭LED $led 失败"
            return 1
        fi
    else
        if timeout 5 "$UGREEN_CLI" "$led" -color $color -brightness "$brightness" -on >/dev/null 2>&1; then
            LED_STATUS_CACHE["$cache_key"]="$new_status"
            log_message "DEBUG" "LED $led 已更新: $color (亮度: $brightness)"
            return 0
        else
            log_message "WARN" "设置LED $led 失败"
            return 1
        fi
    fi
}

# 更新硬盘LED状态 - 使用smartctl检测健康状态，绿色=健康，红色=异常
update_disk_leds() {
    local updated_count=0
    local need_remap=false
    local failed_disks=()

    log_message "DEBUG" "开始更新硬盘LED状态，映射数量: ${#DISK_LED_MAP[@]}"

    # 如果没有HCTL映射配置，生成一次
    if [[ ${#DISK_LED_MAP[@]} -eq 0 ]]; then
        log_message "INFO" "首次运行，加载HCTL映射..."
        if ! load_hctl_mapping; then
            log_message "INFO" "HCTL映射不存在，生成新映射..."
            if ! refresh_hctl_mapping; then
                log_message "ERROR" "生成HCTL映射失败"
                return 1
            fi
        fi
    fi

    # 遍历所有已映射的硬盘，使用smartctl检测健康状态
    for disk_device in "${!DISK_LED_MAP[@]}"; do
        local led_name="${DISK_LED_MAP[$disk_device]}"

        if [[ -z "$led_name" || "$led_name" == "none" ]]; then
            continue
        fi

        log_message "DEBUG" "检测硬盘: $disk_device -> $led_name"

        # 使用smartctl获取健康状态
        local health_status
        health_status=$(get_disk_health "$disk_device")

        # 检查状态是否有变化
        local cached_status="${DISK_STATUS_CACHE[$disk_device]:-}"

        local current_time
        current_time=$(date +%s)
        local force_update=false
        if (( current_time - LAST_FORCE_UPDATE >= 300 )); then
            force_update=true
            LAST_FORCE_UPDATE="$current_time"
            log_message "DEBUG" "执行定期强制LED状态更新"
        fi

        if [[ "$health_status" != "$cached_status" ]] || [[ "$force_update" == true ]]; then
            if [[ "$health_status" != "$cached_status" ]]; then
                log_message "INFO" "硬盘 $disk_device 健康状态变化: $cached_status -> $health_status"
            else
                log_message "DEBUG" "硬盘 $disk_device 强制更新LED状态: $health_status"
            fi

            DISK_STATUS_CACHE["$disk_device"]="$health_status"

            case "$health_status" in
                "healthy")
                    # SMART健康 -> 绿色LED
                    set_led_status "$led_name" "$DISK_COLOR_HEALTHY" "$DEFAULT_BRIGHTNESS"
                    log_message "INFO" "硬盘 $disk_device 健康，LED $led_name 设为绿色"
                    ;;
                "unhealthy")
                    # SMART异常 -> 红色LED
                    set_led_status "$led_name" "$DISK_COLOR_UNHEALTHY" "$DEFAULT_BRIGHTNESS"
                    log_message "WARN" "硬盘 $disk_device 异常，LED $led_name 设为红色"
                    ;;
                "error"|"not_found")
                    # 检测失败 -> 红色LED(警告)
                    set_led_status "$led_name" "$DISK_COLOR_UNHEALTHY" "$DEFAULT_BRIGHTNESS"
                    log_message "WARN" "硬盘 $disk_device 检测失败($health_status)，LED $led_name 设为红色"
                    failed_disks+=("$disk_device")
                    ;;
            esac

            ((updated_count++))
        else
            log_message "DEBUG" "硬盘 $disk_device 状态无变化: $health_status"
        fi
    done

    # 关闭未映射的硬盘LED
    for led in "${actual_disk_leds[@]}"; do
        local led_mapped=false
        for disk in "${!DISK_LED_MAP[@]}"; do
            if [[ "${DISK_LED_MAP[$disk]}" == "$led" ]]; then
                led_mapped=true
                break
            fi
        done

        if [[ "$led_mapped" == false ]]; then
            set_led_status "$led" "off"
            log_message "DEBUG" "关闭未映射的LED: $led"
        fi
    done

    # 如果有硬盘检测失败，尝试重新生成映射
    if [[ "$need_remap" == true && ${#failed_disks[@]} -gt 0 ]]; then
        log_message "INFO" "检测到 ${#failed_disks[@]} 个硬盘smartctl检测失败，尝试重新生成HCTL映射..."
        log_message "INFO" "失败的硬盘: ${failed_disks[*]}"

        if refresh_hctl_mapping; then
            log_message "INFO" "HCTL映射重新生成成功"
            load_hctl_mapping
        else
            log_message "ERROR" "HCTL映射重新生成失败"
        fi
    fi

    if [[ $updated_count -gt 0 ]]; then
        log_message "INFO" "硬盘LED更新完成，更新了 $updated_count 个LED"
    else
        log_message "INFO" "硬盘健康检查完成，所有LED状态正常 (映射: ${#DISK_LED_MAP[@]}个硬盘)"
    fi

    return 0
}

# 信号处理函数
handle_signal() {
    local signal="$1"
    log_message "INFO" "收到信号: $signal，准备退出..."

    DAEMON_RUNNING=false

    if [[ "${CLEANUP_ON_EXIT:-true}" == "true" ]]; then
        log_message "INFO" "清理LED状态..."
        for led in "${AVAILABLE_LEDS[@]}"; do
            if [[ "$led" =~ ^disk[0-9]+$ ]]; then
                set_led_status "$led" "off"
            fi
        done
    fi

    rm -f "$PID_FILE"
    log_message "INFO" "后台服务已停止"
    exit 0
}

# 主监控循环 - 使用smartctl定期检测硬盘健康状态
main_loop() {
    log_message "INFO" "主监控循环启动，检查间隔: ${CHECK_INTERVAL}秒"

    local last_status_log=0
    local status_log_interval=60
    local loop_count=0

    while [[ "$DAEMON_RUNNING" == "true" ]]; do
        local current_time
        current_time=$(date +%s)
        ((loop_count++))

        log_message "INFO" "开始第 $loop_count 次smartctl健康检测..."

        # 使用smartctl检测硬盘健康状态并更新LED
        if update_disk_leds; then
            log_message "INFO" "硬盘健康检测完成"
        else
            log_message "WARN" "硬盘健康检测出现问题"
        fi

        # 定期记录状态日志
        if [[ $((current_time - last_status_log)) -gt $status_log_interval ]]; then
            log_message "INFO" "状态监控正常 - 硬盘映射: ${#DISK_LED_MAP[@]}个, LED总数: ${#AVAILABLE_LEDS[@]}个, 循环次数: $loop_count"
            last_status_log=$current_time
        fi

        log_message "INFO" "第 $loop_count 次循环完成，等待 ${CHECK_INTERVAL} 秒后继续..."

        sleep "$CHECK_INTERVAL"
    done

    log_message "INFO" "主监控循环结束，总共执行 $loop_count 次循环"
}

# 直接启动守护进程
_start_daemon_direct() {
    log_message "INFO" "LLLED后台服务启动中 v$LLLED_VERSION..."

    echo $$ > "$PID_FILE"

    trap 'handle_signal TERM' TERM
    trap 'handle_signal INT' INT
    trap 'handle_signal QUIT' QUIT

    check_root
    load_configs

    if ! check_led_cli; then
        log_message "ERROR" "LED控制程序检查失败"
        exit 1
    fi

    if ! detect_available_leds; then
        log_message "ERROR" "LED检测失败"
        exit 1
    fi

    # 初始化：电源LED显示白色表示系统运行
    if timeout 5 "$UGREEN_CLI" power -color 128 128 128 -brightness 64 -on >/dev/null 2>&1; then
        log_message "INFO" "电源LED已初始化"
    fi

    # 关闭网络LED（不再使用）
    timeout 5 "$UGREEN_CLI" netdev -off >/dev/null 2>&1 || true

    # 生成HCTL映射（如果需要）
    if [[ ${#DISK_LED_MAP[@]} -eq 0 ]]; then
        log_message "INFO" "生成HCTL映射配置..."
        refresh_hctl_mapping
    fi

    log_message "INFO" "守护进程初始化完成，进入smartctl健康监控循环"

    main_loop

    rm -f "$PID_FILE"
    log_message "INFO" "守护进程结束"
}

# 启动守护进程（后台模式）
start_daemon() {
    local background_mode="${1:-false}"

    log_message "INFO" "启动LLLED后台监控服务 v$LLLED_VERSION (后台模式: $background_mode)"

    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log_message "ERROR" "服务已经运行，PID: $old_pid"
            echo "服务已经运行，PID: $old_pid"
            exit 1
        else
            log_message "WARN" "清理过期的PID文件"
            rm -f "$PID_FILE"
        fi
    fi

    if [[ "$background_mode" == "true" ]]; then
        log_message "INFO" "启动后台守护进程..."
        echo "启动后台守护进程..."

        nohup "$0" "_daemon_process" </dev/null >/dev/null 2>&1 &
        local daemon_pid=$!

        sleep 2

        if kill -0 "$daemon_pid" 2>/dev/null; then
            echo "✓ 后台服务启动成功，PID: $daemon_pid"
            log_message "INFO" "后台服务启动成功，PID: $daemon_pid"
            return 0
        else
            echo "✗ 后台服务启动失败"
            log_message "ERROR" "后台服务启动失败"
            return 1
        fi
    fi

    _start_daemon_direct
}

# 停止服务
stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_message "INFO" "停止服务，PID: $pid"
            kill -TERM "$pid"

            local count=0
            while kill -0 "$pid" 2>/dev/null && [[ $count -lt 30 ]]; do
                sleep 1
                ((count++))
            done

            if kill -0 "$pid" 2>/dev/null; then
                log_message "WARN" "强制停止服务"
                kill -KILL "$pid"
            fi

            rm -f "$PID_FILE"
            echo "服务已停止"
        else
            echo "服务未运行"
            rm -f "$PID_FILE"
        fi
    else
        echo "服务未运行"
    fi
}

# 检查状态
check_status() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "服务正在运行，PID: $pid"
            return 0
        else
            echo "服务未运行（PID文件过期）"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo "服务未运行"
        return 1
    fi
}

# 重启服务
restart_daemon() {
    stop_daemon
    sleep 2
    start_daemon
}

# 显示帮助信息
show_help() {
    echo "LLLED后台监控服务 v$LLLED_VERSION"
    echo "用法: $0 {start|stop|restart|status|clear-logs|help}"
    echo
    echo "命令说明:"
    echo "  start      - 启动后台服务"
    echo "  stop       - 停止后台服务"
    echo "  restart    - 重启后台服务"
    echo "  status     - 查看服务状态"
    echo "  clear-logs - 清除日志文件"
    echo "  help       - 显示帮助信息"
    echo
    echo "工作原理: 使用smartctl检测硬盘健康状态"
    echo "  绿色LED = SMART健康"
    echo "  红色LED = SMART异常/检测失败"
    echo
    echo "日志文件: $LOG_FILE"
    echo "配置目录: $CONFIG_DIR"
}

# 主程序入口
case "${1:-start}" in
    start)
        start_daemon true
        ;;
    _daemon_process)
        _start_daemon_direct
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        restart_daemon
        ;;
    status)
        check_status
        ;;
    clear-logs)
        clear_logs
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "未知命令: $1"
        show_help
        exit 1
        ;;
esac
