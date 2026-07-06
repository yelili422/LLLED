#!/bin/bash

# HCTL硬盘映射检测脚本 v4.0.0
# 检测硬盘HCTL信息并生成LED映射配置
# 供led_daemon.sh的refresh_hctl_mapping()调用

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
LED_CONFIG="$CONFIG_DIR/led_mapping.conf"
HCTL_CONFIG="$CONFIG_DIR/hctl_mapping.conf"
UGREEN_CLI="$SCRIPT_DIR/ugreen_leds_cli"

declare -A CURRENT_HCTL_MAP

UPDATE_MAPPING=false
SAVE_CONFIG=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --update-mapping)
            UPDATE_MAPPING=true
            shift
            ;;
        --save-config)
            SAVE_CONFIG=true
            shift
            ;;
        --help|-h)
            echo "HCTL硬盘映射检测脚本 v4.0.0"
            echo "用法: $0 [--update-mapping] [--save-config]"
            echo "  --update-mapping    更新HCTL映射"
            echo "  --save-config       保存映射到配置文件"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 检测可用硬盘LED
detect_available_disk_leds() {
    local disk_leds=()

    for i in {1..15}; do
        local led_name="disk$i"
        if timeout 3 "$UGREEN_CLI" "$led_name" -status >/dev/null 2>&1; then
            disk_leds+=("$led_name")
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
                break
            fi
        fi
    done

    echo "${disk_leds[@]}"
}

# 检测HCTL硬盘映射
detect_disk_mapping_hctl() {
    local disk_leds=($(detect_available_disk_leds))

    [[ ${#disk_leds[@]} -eq 0 ]] && disk_leds=("disk1" "disk2" "disk3" "disk4" "disk5" "disk6" "disk7" "disk8")

    local hctl_info
    hctl_info=$(lsblk -S -x hctl -o name,hctl,serial,model,size 2>/dev/null)

    [[ -z "$hctl_info" ]] && return 1

    CURRENT_HCTL_MAP=()
    local line_count=0
    local successful_mappings=0

    while IFS= read -r line; do
        ((line_count++))
        [[ $line_count -eq 1 ]] && continue
        [[ -z "${line// }" ]] && continue

        read -r name hctl serial model size <<< "$line"
        [[ -z "$name" || -z "$hctl" ]] && continue

        local disk_device="/dev/$name"
        [[ ! -b "$disk_device" ]] && continue

        local hctl_host="${hctl%%:*}"
        local led_position=$((hctl_host + 1))
        local target_led="disk${led_position}"

        local led_available=false
        for available_led in "${disk_leds[@]}"; do
            if [[ "$available_led" == "$target_led" ]]; then
                led_available=true
                break
            fi
        done

        if [[ "$led_available" == "true" ]]; then
            CURRENT_HCTL_MAP["$disk_device"]="$hctl|$target_led|${serial:-N/A}|${model:-Unknown}|${size:-N/A}"
            ((successful_mappings++))
        fi
    done <<< "$hctl_info"

    return 0
}

# 保存HCTL映射到配置文件
save_hctl_mapping_config() {
    mkdir -p "$CONFIG_DIR"

    # 备份旧配置
    if [[ -f "$HCTL_CONFIG" ]]; then
        cp "$HCTL_CONFIG" "${HCTL_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    cat > "$HCTL_CONFIG" << EOF
# HCTL硬盘映射配置文件
# 版本: 4.0.0
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 此文件由smart_disk_activity_hctl.sh自动生成

CONFIG_VERSION="4.0.0"
LAST_UPDATE="$(date '+%Y-%m-%d %H:%M:%S')"
AUTO_GENERATED=true

EOF

    for disk_device in "${!CURRENT_HCTL_MAP[@]}"; do
        local mapping_info="${CURRENT_HCTL_MAP[$disk_device]}"
        echo "HCTL_MAPPING[$disk_device]=\"$mapping_info\"" >> "$HCTL_CONFIG"
    done

    return 0
}

# 主函数
main() {
    detect_disk_mapping_hctl || return 1

    if [[ "$UPDATE_MAPPING" == "true" || "$SAVE_CONFIG" == "true" ]]; then
        save_hctl_mapping_config
    fi

    return 0
}

main "$@"
