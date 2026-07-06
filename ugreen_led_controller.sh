#!/bin/bash

# LLLED LED控制工具 - smartctl健康检测版 v4.0.0
# 使用smartctl检测硬盘健康状态，绿色=健康，红色=异常
# 项目地址: https://github.com/BearHero520/LLLED

# 全局版本信息
VERSION="4.0.0"
PROJECT_NAME="LLLED智能LED控制系统"
LAST_UPDATE="2026-07-06"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查root权限
[[ $EUID -ne 0 ]] && { echo -e "${RED}需要root权限: sudo LLLED${NC}"; exit 1; }

# 系统路径配置
SCRIPT_DIR="/opt/ugreen-led-controller"
CONFIG_DIR="$SCRIPT_DIR/config"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
LOG_DIR="/var/log/llled"

# 配置文件
GLOBAL_CONFIG="$CONFIG_DIR/global_config.conf"
LED_CONFIG="$CONFIG_DIR/led_mapping.conf"
DISK_CONFIG="$CONFIG_DIR/disk_mapping.conf"
HCTL_CONFIG="$CONFIG_DIR/hctl_mapping.conf"

# 核心程序
UGREEN_CLI="$SCRIPT_DIR/ugreen_leds_cli"
LED_DAEMON="$SCRIPTS_DIR/led_daemon.sh"

# 加载全局配置
[[ -f "$GLOBAL_CONFIG" ]] && source "$GLOBAL_CONFIG"

# 检查安装
check_installation() {
    local missing_files=()

    for file in "$UGREEN_CLI" "$LED_CONFIG" "$LED_DAEMON"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done

    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo -e "${RED}系统未正确安装，缺少文件:${NC}"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        echo
        echo -e "${YELLOW}请运行安装脚本: quick_install.sh${NC}"
        exit 1
    fi

    if [[ ! -x "$UGREEN_CLI" ]]; then
        echo -e "${RED}LED控制程序无执行权限: $UGREEN_CLI${NC}"
        echo "尝试修复权限..."
        chmod +x "$UGREEN_CLI" 2>/dev/null || {
            echo -e "${RED}权限修复失败${NC}"
            exit 1
        }
    fi

    ! lsmod | grep -q i2c_dev && modprobe i2c-dev 2>/dev/null
}

# 显示系统信息
show_system_info() {
    echo -e "${CYAN}================================${NC}"
    echo -e "${CYAN}$PROJECT_NAME v$VERSION${NC}"
    echo -e "${CYAN}================================${NC}"
    echo -e "更新时间: $LAST_UPDATE"
    echo -e "安装目录: $SCRIPT_DIR"
    echo -e "配置目录: $CONFIG_DIR"
    echo -e "日志目录: $LOG_DIR"
    echo
    echo -e "${BLUE}工作原理:${NC}"
    echo -e "  使用 smartctl 定期检测硬盘SMART健康状态"
    echo -e "  🟢 ${GREEN}绿色${NC} = 硬盘健康 (SMART PASSED)"
    echo -e "  🔴 ${RED}红色${NC} = 硬盘异常 (SMART FAILED / 检测失败)"
    echo

    if [[ -x "$UGREEN_CLI" ]]; then
        local led_status
        led_status=$("$UGREEN_CLI" all -status 2>/dev/null)
        if [[ -n "$led_status" ]]; then
            echo -e "${BLUE}当前LED状态:${NC}"
            echo "$led_status"
        else
            echo -e "${YELLOW}无法获取LED状态${NC}"
        fi
    fi
    echo

    # 显示硬盘健康摘要
    show_health_summary
}

# 显示硬盘健康摘要
show_health_summary() {
    echo -e "${BLUE}硬盘SMART健康摘要:${NC}"
    echo

    if [[ -f "$HCTL_CONFIG" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue

            if [[ "$line" =~ ^HCTL_MAPPING\[([^\]]+)\]=\"([^\"]+)\"$ ]]; then
                local disk_device="${BASH_REMATCH[1]}"
                local mapping_info="${BASH_REMATCH[2]}"
                IFS='|' read -r hctl led serial model size <<< "$mapping_info"

                if [[ -b "$disk_device" ]]; then
                    local smart_result
                    smart_result=$(timeout 10 smartctl -H "$disk_device" 2>/dev/null)
                    if echo "$smart_result" | grep -qiE "PASSED|SMART Health Status: OK"; then
                        echo -e "  $disk_device -> $led  ${GREEN}● 健康${NC}  ($model, $size)"
                    elif echo "$smart_result" | grep -qiE "FAIL"; then
                        echo -e "  $disk_device -> $led  ${RED}● 异常${NC}  ($model, $size)"
                    else
                        echo -e "  $disk_device -> $led  ${YELLOW}● 未知${NC}  ($model, $size)"
                    fi
                else
                    echo -e "  $disk_device -> $led  ${RED}● 设备不在线${NC}"
                fi
            fi
        done < "$HCTL_CONFIG"
    else
        echo -e "  ${YELLOW}HCTL映射配置不存在，请先启动后台服务${NC}"
    fi
    echo
}

# 显示硬盘映射
show_disk_mapping() {
    echo -e "${YELLOW}当前硬盘映射配置:${NC}"
    echo

    if [[ -f "$DISK_CONFIG" ]]; then
        echo -e "${BLUE}硬盘映射 ($DISK_CONFIG):${NC}"
        grep -E "^/dev/" "$DISK_CONFIG" 2>/dev/null || echo "  (无配置)"
        echo
    fi

    if [[ -f "$HCTL_CONFIG" ]]; then
        echo -e "${BLUE}HCTL映射 ($HCTL_CONFIG):${NC}"
        grep -E "^HCTL_MAPPING" "$HCTL_CONFIG" 2>/dev/null | while IFS= read -r line; do
            if [[ "$line" =~ ^HCTL_MAPPING\[([^\]]+)\]=\"?([^\"]+)\"?$ ]]; then
                local device="${BASH_REMATCH[1]}"
                local mapping="${BASH_REMATCH[2]}"
                IFS='|' read -r hctl led serial model size <<< "$mapping"
                echo "  $device -> $led (HCTL: $hctl)"
                echo "    型号: ${model:-Unknown} | 序列号: ${serial:-N/A} | 大小: ${size:-N/A}"
            fi
        done

        if ! grep -q "^HCTL_MAPPING" "$HCTL_CONFIG" 2>/dev/null; then
            echo "  (无HCTL映射配置)"
        fi
    else
        echo -e "${BLUE}HCTL映射: (配置文件不存在)${NC}"
    fi
}

# 开机自启管理
manage_autostart() {
    echo -e "${CYAN}开机自启设置${NC}"
    echo
    echo "1. 启用开机自启"
    echo "2. 禁用开机自启"
    echo "3. 查看自启状态"
    echo "4. 返回"
    echo
    read -p "请选择操作 (1-4): " choice

    case $choice in
        1)
            echo -e "${CYAN}启用开机自启...${NC}"
            if systemctl enable ugreen-led-monitor.service 2>/dev/null; then
                echo -e "${GREEN}✓ 开机自启已启用${NC}"
            else
                echo -e "${RED}✗ 启用开机自启失败${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}禁用开机自启...${NC}"
            if systemctl disable ugreen-led-monitor.service 2>/dev/null; then
                echo -e "${GREEN}✓ 开机自启已禁用${NC}"
            else
                echo -e "${RED}✗ 禁用开机自启失败${NC}"
            fi
            ;;
        3)
            echo -e "${CYAN}查看自启状态...${NC}"
            if systemctl is-enabled ugreen-led-monitor.service >/dev/null 2>&1; then
                echo -e "${GREEN}✓ 开机自启已启用${NC}"
            else
                echo -e "${YELLOW}⚠ 开机自启未启用${NC}"
            fi
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

# 后台服务管理
manage_service() {
    echo -e "${CYAN}后台服务管理${NC}"
    echo
    echo "1. 启动后台服务"
    echo "2. 停止后台服务"
    echo "3. 重启后台服务"
    echo "4. 查看服务状态"
    echo "5. 开机自启设置"
    echo "6. 查看服务日志"
    echo "7. 实时查看日志"
    echo "8. 返回主菜单"
    echo
    read -p "请选择操作 (1-8): " choice

    case $choice in
        1)
            echo -e "${CYAN}启动后台服务...${NC}"
            if systemctl start ugreen-led-monitor.service 2>/dev/null; then
                echo -e "${GREEN}✓ 服务启动成功${NC}"
            else
                echo -e "${RED}✗ 服务启动失败${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}停止后台服务...${NC}"
            if systemctl stop ugreen-led-monitor.service 2>/dev/null; then
                echo -e "${GREEN}✓ 服务停止成功${NC}"
            else
                echo -e "${RED}✗ 服务停止失败${NC}"
            fi
            ;;
        3)
            echo -e "${CYAN}重启后台服务...${NC}"
            if systemctl restart ugreen-led-monitor.service 2>/dev/null; then
                echo -e "${GREEN}✓ 服务重启成功${NC}"
            else
                echo -e "${RED}✗ 服务重启失败${NC}"
            fi
            ;;
        4)
            echo -e "${CYAN}查看服务状态...${NC}"
            echo
            echo -e "${BLUE}Systemd服务状态:${NC}"
            if systemctl status ugreen-led-monitor.service >/dev/null 2>&1; then
                systemctl status ugreen-led-monitor.service --no-pager -l
                echo
                echo -e "${BLUE}开机自启状态:${NC}"
                if systemctl is-enabled ugreen-led-monitor.service >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ 已启用开机自启${NC}"
                else
                    echo -e "${YELLOW}⚠ 未启用开机自启${NC}"
                fi
            else
                echo "Systemd服务未安装"
            fi
            ;;
        5)
            manage_autostart
            ;;
        6)
            echo -e "${CYAN}查看服务日志...${NC}"
            journalctl -u ugreen-led-monitor.service -n 50 --no-pager
            ;;
        7)
            echo -e "${CYAN}实时查看日志 (按Ctrl+C退出)...${NC}"
            journalctl -u ugreen-led-monitor.service -f
            ;;
        8)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac

    echo
    read -p "按回车键继续..."
}

# 主菜单
show_main_menu() {
    clear
    show_system_info

    echo -e "${YELLOW}主菜单:${NC}"
    echo
    echo "1. 后台服务管理"
    echo "2. 系统信息"
    echo "3. 显示硬盘映射"
    echo "4. 退出"
    echo
    read -p "请选择功能 (1-4): " choice

    case $choice in
        1)
            manage_service
            ;;
        2)
            show_system_info
            read -p "按回车键继续..."
            ;;
        3)
            show_disk_mapping
            read -p "按回车键继续..."
            ;;
        4)
            echo -e "${GREEN}感谢使用 $PROJECT_NAME${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重试${NC}"
            sleep 1
            ;;
    esac
}

# 主程序
main() {
    check_installation

    while true; do
        show_main_menu
    done
}

# 处理命令行参数
case "${1:-}" in
    "start")
        echo -e "${CYAN}启动LED监控服务...${NC}"
        systemctl start ugreen-led-monitor.service
        exit 0
        ;;
    "stop")
        echo -e "${CYAN}停止LED监控服务...${NC}"
        systemctl stop ugreen-led-monitor.service
        exit 0
        ;;
    "restart")
        echo -e "${CYAN}重启LED监控服务...${NC}"
        systemctl restart ugreen-led-monitor.service
        exit 0
        ;;
    "status")
        echo -e "${CYAN}LED监控服务状态:${NC}"
        systemctl status ugreen-led-monitor.service
        exit 0
        ;;
    "test")
        echo -e "${CYAN}运行LED测试...${NC}"
        if [[ -x "$SCRIPTS_DIR/led_test.sh" ]]; then
            "$SCRIPTS_DIR/led_test.sh"
        else
            echo -e "${RED}LED测试脚本不存在${NC}"
        fi
        exit 0
        ;;
    "info")
        show_system_info
        exit 0
        ;;
    "--help"|"-h")
        echo "$PROJECT_NAME v$VERSION"
        echo ""
        echo "用法: $0 [命令]"
        echo ""
        echo "命令:"
        echo "  start    - 启动LED监控服务"
        echo "  stop     - 停止LED监控服务"
        echo "  restart  - 重启LED监控服务"
        echo "  status   - 查看服务状态"
        echo "  test     - 运行LED测试"
        echo "  info     - 显示系统信息"
        echo ""
        echo "工作原理:"
        echo "  后台服务使用 smartctl 定期检测硬盘SMART健康状态"
        echo "  绿色LED = 硬盘健康, 红色LED = 硬盘异常"
        echo ""
        echo "不使用参数则进入交互模式"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "未知参数: $1"
        echo "使用 $0 --help 查看帮助"
        exit 1
        ;;
esac
