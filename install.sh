#!/usr/bin/env bash
#
# install.sh - Oracle Cloud 空闲实例防回收 一键部署脚本
#
# 用法：
#   bash <(curl -Ls https://raw.githubusercontent.com/closeblog/oci-cloud-anti-reclaim/refs/heads/main/install.sh) cron       # 方案一：cron 定时
#   bash <(curl -Ls https://raw.githubusercontent.com/closeblog/oci-cloud-anti-reclaim/refs/heads/main/install.sh) systemd    # 方案二：systemd service+timer（推荐）
#
# 两种方案效果一致，systemd 方案的优势是：重启错过的任务会自动补跑，
# 状态和日志更容易用 systemctl / journalctl 查看。

set -euo pipefail

MODE="${1:-}"
SCRIPT_PATH="/usr/local/bin/oci-anti-reclaim.sh"
LOG_FILE="/var/log/oci-anti-reclaim.log"
CRON_LINE="0 3 * * * ${SCRIPT_PATH} 2400 60 auto >> /var/log/oci-anti-reclaim-cron.log 2>&1"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行（例如：sudo bash <(curl -Ls https://raw.githubusercontent.com/closeblog/oci-cloud-anti-reclaim/refs/heads/main/install.sh systemd）" >&2
    exit 1
fi

if [[ "$MODE" != "cron" && "$MODE" != "systemd" ]]; then
    cat >&2 << USAGE
用法: bash <(curl -Ls https://raw.githubusercontent.com/closeblog/oci-cloud-anti-reclaim/refs/heads/main/install.sh) [cron|systemd]

  cron     使用 crontab 定时触发
  systemd  使用 systemd service+timer 定时触发（推荐）
USAGE
    exit 1
fi

echo ">>> [1/4] 写入压测脚本 ${SCRIPT_PATH} ..."
cat > "$SCRIPT_PATH" << 'SCRIPT_EOF'
#!/usr/bin/env bash
#
# oci-anti-reclaim.sh
# 用于避免 Oracle Cloud "Always Free" 空闲计算实例被自动回收
#
# 用法：
#   ./oci-anti-reclaim.sh [持续时间(秒)] [CPU负载百分比] [内存压力模式]
#
#   内存压力模式可选：
#     auto    （默认）根据架构自动判断，ARM 开启，x86 关闭
#     mem     强制开启内存压力
#     nomem   强制关闭内存压力

set -euo pipefail

LOG_FILE="/var/log/oci-anti-reclaim.log"
DURATION="${1:-1800}"
CPU_LOAD="${2:-50}"
MEM_MODE="${3:-auto}"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

if [[ $EUID -ne 0 ]]; then
    echo "请使用 sudo 或 root 权限运行本脚本" >&2
    exit 1
fi

detect_arm() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) return 0 ;;
        *) return 1 ;;
    esac
}

case "$MEM_MODE" in
    mem)
        USE_MEM=1
        log "内存压力模式：手动强制开启"
        ;;
    nomem)
        USE_MEM=0
        log "内存压力模式：手动强制关闭"
        ;;
    auto|*)
        if detect_arm; then
            USE_MEM=1
            log "检测到架构 $(uname -m)，判定为 ARM(A1) 机型，自动开启内存压力"
        else
            USE_MEM=0
            log "检测到架构 $(uname -m)，判定为 x86_64 机型，跳过内存压力"
        fi
        ;;
esac

if ! command -v stress-ng &>/dev/null; then
    log "未检测到 stress-ng，正在安装..."
    apt-get update -qq
    apt-get install -y stress-ng
fi

CPU_CORES=$(nproc)
STRESS_ARGS=(--cpu "${CPU_CORES}" --cpu-load "${CPU_LOAD}" --timeout "${DURATION}s" --metrics-brief)

if [[ "${USE_MEM}" -eq 1 ]]; then
    STRESS_ARGS+=(--vm "${CPU_CORES}" --vm-bytes 128M --vm-keep)
fi

log "开始压力测试：核心数=${CPU_CORES}，时长=${DURATION}s，CPU负载=${CPU_LOAD}%，内存压力=$([[ ${USE_MEM} -eq 1 ]] && echo 开启 || echo 关闭)"

stress-ng "${STRESS_ARGS[@]}" >> "$LOG_FILE" 2>&1

log "压力测试结束"
SCRIPT_EOF
chmod +x "$SCRIPT_PATH"

echo ">>> [2/4] 检查/安装依赖 stress-ng ..."
if ! command -v stress-ng &>/dev/null; then
    apt-get update -qq
    apt-get install -y stress-ng
fi

if [[ "$MODE" == "cron" ]]; then
    echo ">>> [3/4] 配置 crontab 定时任务 ..."
    # 先清掉旧的同类任务，避免重复执行本脚本时叠加多条
    ( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ; echo "$CRON_LINE" ) | crontab -

    echo ">>> [4/4] 完成，当前 crontab 内容："
    crontab -l
else
    echo ">>> [3/4] 写入 systemd unit 文件 ..."
    cat > /etc/systemd/system/oci-anti-reclaim.service << 'SERVICE_EOF'
[Unit]
Description=Oracle Cloud 空闲实例防回收任务 (CPU/内存压力测试，自动判断ARM架构)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-anti-reclaim.sh 2400 60 auto
Nice=10
CPUSchedulingPolicy=idle
SERVICE_EOF

    cat > /etc/systemd/system/oci-anti-reclaim.timer << 'TIMER_EOF'
[Unit]
Description=每天定时触发 oci-anti-reclaim 防回收任务

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

    systemctl daemon-reload
    systemctl enable --now oci-anti-reclaim.timer

    echo ">>> [4/4] 完成，当前 timer 状态："
    systemctl list-timers oci-anti-reclaim.timer --no-pager
fi

echo ""
echo "✅ 部署完成"
echo "   脚本位置：${SCRIPT_PATH}"
echo "   日志位置：${LOG_FILE}"
if [[ "$MODE" == "systemd" ]]; then
    echo "   手动测试：sudo systemctl start oci-anti-reclaim.service"
    echo "   查看日志：journalctl -u oci-anti-reclaim.service --since today"
else
    echo "   手动测试：sudo ${SCRIPT_PATH} 300 50 auto"
fi

