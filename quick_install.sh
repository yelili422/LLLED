#!/bin/bash

# LLLED 本地安装脚本 v4.0.0
# 从当前目录安装LLLED到系统
# 使用smartctl检测硬盘健康状态，绿色=健康，红色=异常

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

LLLED_VERSION="4.0.0"
INSTALL_DIR="/opt/ugreen-led-controller"
LOG_DIR="/var/log/llled"
SERVICE_NAME="ugreen-led-monitor"

# 检查root权限
[[ $EUID -ne 0 ]] && { echo -e "${RED}需要root权限: sudo bash $0${NC}"; exit 1; }

echo -e "${CYAN}================================${NC}"
echo -e "${CYAN}LLLED 本地安装工具 v${LLLED_VERSION}${NC}"
echo -e "${CYAN}================================${NC}"
echo
echo -e "${BLUE}工作原理:${NC}"
echo -e "  使用 smartctl 定期检测硬盘SMART健康状态"
echo -e "  ${GREEN}绿色LED${NC} = 硬盘健康"
echo -e "  ${RED}红色LED${NC} = 硬盘异常"
echo

# 获取脚本所在目录（项目根目录）
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

log_install() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INSTALL] $1" | tee -a "$LOG_DIR/install.log"
}

# 停止旧服务
log_install "停止旧服务..."
systemctl stop "$SERVICE_NAME.service" 2>/dev/null || true
systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# 删除旧命令链接
rm -f /usr/local/bin/LLLED 2>/dev/null || true
rm -f /usr/bin/LLLED 2>/dev/null || true
rm -f /bin/LLLED 2>/dev/null || true

# 备份旧配置
if [[ -d "$INSTALL_DIR" ]]; then
    backup_dir="/tmp/llled-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    if [[ -d "$INSTALL_DIR/config" ]]; then
        cp -r "$INSTALL_DIR/config" "$backup_dir/" 2>/dev/null || true
        echo "旧配置已备份到: $backup_dir"
    fi
    rm -rf "$INSTALL_DIR"
fi

# 安装依赖
log_install "安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || true
    apt-get install -y i2c-tools smartmontools util-linux -qq 2>/dev/null || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y i2c-tools smartmontools util-linux -q 2>/dev/null || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y i2c-tools smartmontools util-linux -q 2>/dev/null || true
fi

# 加载i2c模块
modprobe i2c-dev 2>/dev/null || true

# 创建目录结构
log_install "创建目录结构..."
mkdir -p "$INSTALL_DIR"/{scripts,config,systemd}
mkdir -p "$LOG_DIR"

# 从本地复制文件
log_install "从本地复制文件..."

copy_file() {
    local src="$SOURCE_DIR/$1"
    local dst="$INSTALL_DIR/$1"
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo "  ✓ $1"
    else
        echo "  ${RED}✗${NC} $1 (源文件不存在)"
    fi
}

files=(
    "ugreen_led_controller.sh"
    "uninstall.sh"
    "verify_detection.sh"
    "ugreen_leds_cli"
    "scripts/turn_off_all_leds.sh"
    "scripts/smart_disk_activity_hctl.sh"
    "scripts/led_mapping_test.sh"
    "scripts/configure_mapping_optimized.sh"
    "scripts/led_daemon.sh"
    "config/global_config.conf"
    "config/led_mapping.conf"
    "config/disk_mapping.conf"
    "config/hctl_mapping.conf"
    "systemd/ugreen-led-monitor.service"
)

for file in "${files[@]}"; do
    copy_file "$file"
done

# 设置权限
log_install "设置权限..."
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR"/ugreen_leds_cli 2>/dev/null || true

# 验证关键文件
log_install "验证核心文件..."
core_files=("ugreen_leds_cli" "scripts/led_daemon.sh" "scripts/smart_disk_activity_hctl.sh" "config/global_config.conf")
missing_files=()

for file in "${core_files[@]}"; do
    if [[ ! -f "$INSTALL_DIR/$file" || ! -s "$INSTALL_DIR/$file" ]]; then
        missing_files+=("$file")
    fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo -e "${RED}安装失败：关键文件缺失:${NC}"
    for file in "${missing_files[@]}"; do
        echo "  - $file"
    done
    exit 1
fi

# 创建命令链接
log_install "创建LLLED命令..."
ln -sf "$INSTALL_DIR/ugreen_led_controller.sh" /usr/local/bin/LLLED
chmod +x "$INSTALL_DIR/ugreen_led_controller.sh"

# 安装systemd服务
log_install "安装systemd服务..."
if [[ -f "$INSTALL_DIR/systemd/ugreen-led-monitor.service" ]]; then
    cp "$INSTALL_DIR/systemd/ugreen-led-monitor.service" /etc/systemd/system/
    systemctl daemon-reload
fi

# 启用并启动服务
log_install "启用并启动服务..."
systemctl enable "$SERVICE_NAME.service" 2>/dev/null || true
systemctl start "$SERVICE_NAME.service" 2>/dev/null || true

# 完成
echo
echo -e "${CYAN}================================${NC}"
echo -e "${CYAN}LLLED v${LLLED_VERSION} 安装完成${NC}"
echo -e "${CYAN}================================${NC}"
echo
echo -e "${GREEN}使用命令: sudo LLLED${NC}"
echo
echo -e "  绿色LED = 硬盘SMART健康"
echo -e "  红色LED = 硬盘SMART异常/检测失败"
echo
echo -e "安装目录: $INSTALL_DIR"
echo -e "日志目录: $LOG_DIR"
echo -e "服务状态: $(systemctl is-active "$SERVICE_NAME.service" 2>/dev/null || echo '未运行')"
echo
