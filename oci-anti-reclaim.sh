#!/usr/bin/env bash
#
# oci-anti-reclaim.sh
# 用于避免 Oracle Cloud "Always Free" 空闲计算实例被自动回收
#
# 原理：
#   Oracle 判断实例是否"空闲"，看的是过去 7 天内以下指标的第 95 百分位：
#     - CPU 利用率 < 20%
#     - 网络利用率 < 20%
#     - 内存利用率 < 20%（仅 A1/ARM 机型适用此项）
#   只要"任意一项"稳定超过 20%，实例就不会被判定为空闲。
#   利用第 95 百分位的统计特性：每天只需有约 5%~10% 的时间
#   （大约 1~2.5 小时）CPU 利用率超过 20%，就足以把 95 百分位顶起来。
#
#   本脚本会自动判断当前实例是否为 ARM (A1) 架构：
#     - 如果是 ARM，则同时施加内存压力（因为 A1 还多一条内存指标）
#     - 如果是 x86_64，则只做 CPU 压力（内存指标对该类机型不适用）
#
# 用法：
#   ./oci-anti-reclaim.sh [持续时间(秒)] [CPU负载百分比] [内存压力模式]
#
#   内存压力模式可选：
#     auto    （默认）根据架构自动判断，ARM 开启，x86 关闭
#     mem     强制开启内存压力
#     nomem   强制关闭内存压力
#
# 示例：
#   ./oci-anti-reclaim.sh                  # 全部使用默认值，自动判断架构
#   ./oci-anti-reclaim.sh 2400 60          # 40分钟，CPU负载60%，自动判断架构
#   ./oci-anti-reclaim.sh 1800 50 nomem    # 强制不加内存压力

set -euo pipefail

LOG_FILE="/var/log/oci-anti-reclaim.log"
DURATION="${1:-1800}"     # 持续时间，默认 1800 秒 = 30 分钟
CPU_LOAD="${2:-50}"       # 每个 CPU worker 的负载百分比，默认 50%
MEM_MODE="${3:-auto}"     # auto / mem / nomem

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

# 确保以 root 权限运行（安装依赖 & 写系统日志需要）
if [[ $EUID -ne 0 ]]; then
    echo "请使用 sudo 或 root 权限运行本脚本" >&2
    exit 1
fi

# ---- 判断是否为 ARM (A1) 实例 ----
detect_arm() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64)
            return 0  # 是 ARM
            ;;
        *)
            return 1  # 不是 ARM
            ;;
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

# 自动安装 stress-ng（仅首次运行时执行）
if ! command -v stress-ng &>/dev/null; then
    log "未检测到 stress-ng，正在安装..."
    apt-get update -qq
    apt-get install -y stress-ng
fi

CPU_CORES=$(nproc)

STRESS_ARGS=(--cpu "${CPU_CORES}" --cpu-load "${CPU_LOAD}" --timeout "${DURATION}s" --metrics-brief)

if [[ "${USE_MEM}" -eq 1 ]]; then
    # 每个核心配一个 vm worker，各占用约 128M，制造真实内存占用
    STRESS_ARGS+=(--vm "${CPU_CORES}" --vm-bytes 128M --vm-keep)
fi

log "开始压力测试：核心数=${CPU_CORES}，时长=${DURATION}s，CPU负载=${CPU_LOAD}%，内存压力=$([[ ${USE_MEM} -eq 1 ]] && echo 开启 || echo 关闭)"

stress-ng "${STRESS_ARGS[@]}" >> "$LOG_FILE" 2>&1

log "压力测试结束"
