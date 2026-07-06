# LLLED - LED 硬盘健康监控系统

> 绿联 NAS LED 硬盘健康监控  
> 使用 smartctl 检测硬盘 SMART 状态，绿色 = 健康，红色 = 异常

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-4.0.0-blue.svg)](https://github.com/BearHero520/LLLED)
[![Shell Script](https://img.shields.io/badge/language-Shell-green.svg)](https://github.com/BearHero520/LLLED)

## 工作原理

后台服务每 30 秒使用 `smartctl -H` 检测每个硬盘的 SMART 健康状态：

- 🟢 **绿色 LED** = 硬盘健康 (SMART PASSED)
- 🔴 **红色 LED** = 硬盘异常 (SMART FAILED / 检测失败)

## 支持设备

| 设备型号 | 支持状态 |
|----------|----------|
| UGREEN DX4600 Pro | ✅ |
| UGREEN DX4700+ | ✅ |
| UGREEN DXP2800 | ✅ |
| UGREEN DXP4800 | ✅ |
| UGREEN DXP4800 Plus | ✅ |
| UGREEN DXP6800 Pro | ✅ |
| UGREEN DXP8800 Plus | ✅ |

## 系统要求

- Linux (Debian/Ubuntu/TrueNAS/Proxmox 等)
- `i2c-dev` 内核模块
- `smartmontools` (smartctl)
- Root 权限

## 快速开始

### 本地安装

```bash
# 在项目目录中运行
sudo bash quick_install.sh
```

### 使用

```bash
sudo LLLED              # 交互式控制面板
sudo LLLED start        # 启动后台服务
sudo LLLED stop         # 停止后台服务
sudo LLLED restart      # 重启后台服务
sudo LLLED status       # 查看服务状态
sudo LLLED info         # 显示系统信息和硬盘健康摘要
```

## 项目结构

```
LLLED/
├── ugreen_led_controller.sh          # 主控制脚本
├── quick_install.sh                  # 本地安装脚本
├── uninstall.sh                      # 卸载脚本
├── verify_detection.sh               # 硬件检测验证
├── ugreen_leds_cli                   # LED控制核心程序 (二进制)
├── config/
│   ├── global_config.conf            # 全局配置
│   ├── led_mapping.conf              # LED映射配置
│   ├── disk_mapping.conf             # 硬盘映射配置
│   └── hctl_mapping.conf             # HCTL映射配置 (自动生成)
├── scripts/
│   ├── led_daemon.sh                 # LED守护进程 (smartctl健康检测)
│   ├── smart_disk_activity_hctl.sh   # HCTL硬盘映射检测
│   ├── turn_off_all_leds.sh          # 关闭所有LED
│   ├── configure_mapping_optimized.sh # 硬盘映射配置工具
│   └── led_mapping_test.sh           # LED映射测试
└── systemd/
    └── ugreen-led-monitor.service    # 系统服务文件
```

## 配置文件

### LED映射配置 (`config/led_mapping.conf`)

```bash
I2C_BUS=1
I2C_DEVICE_ADDR=0x3a

# 颜色配置
DISK_COLOR_HEALTHY="0 255 0"       # 绿色 - SMART健康
DISK_COLOR_UNHEALTHY="255 0 0"     # 红色 - SMART异常
DEFAULT_BRIGHTNESS=64
```

### 全局配置 (`config/global_config.conf`)

```bash
LLLED_VERSION="4.0.0"
CHECK_INTERVAL=30                   # 检测间隔(秒)
SMART_CHECK_ENABLED=true
```

## 系统服务

```bash
# 启动服务
sudo systemctl start ugreen-led-monitor.service

# 开机自启
sudo systemctl enable ugreen-led-monitor.service

# 查看状态
sudo systemctl status ugreen-led-monitor.service

# 查看日志
sudo journalctl -u ugreen-led-monitor.service -f
```

## 卸载

```bash
sudo /opt/ugreen-led-controller/uninstall.sh
```

## 故障排除

**LED 不亮**
```bash
sudo modprobe i2c-dev
sudo LLLED info
```

**硬盘检测失败**
```bash
lsblk -S -o NAME,HCTL
sudo smartctl -H /dev/sda
```

**查看运行日志**
```bash
sudo journalctl -u ugreen-led-monitor.service -n 50
```

## 参考资料

- [绿联 DX4600 Pro LED 控制模块分析](https://blog.miskcoo.com/2024/05/ugreen-dx4600-pro-led-controller)
- [miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller)

## 许可证

MIT
