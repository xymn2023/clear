#!/bin/bash
# server-cleanup.sh - 服务器磁盘空间清理维护脚本
# 完整版本 v2.1 - 包含交互菜单、自动模式、日志记录和完整清屏功能

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # 无色

# 配置区域（根据实际情况修改）
WP_PATH="/home/web/html/your-website/wordpress"
LOG_FILE="/var/log/server-cleanup.log"
MAX_LOG_SIZE=100      # systemd日志大小限制(MB)
LOG_TRUNCATE_SIZE=50  # 要截断的日志文件大小(MB)
TMP_FILE_AGE=3        # 临时文件过期天数(天)
DOCKER_LOG_DIR="/var/lib/docker/containers"

# 初始化日志系统
function init_log() {
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo -e "${RED}无法创建日志文件 $LOG_FILE${NC}"
        echo -e "${YELLOW}尝试使用备用位置...${NC}"
        LOG_FILE="$HOME/server-cleanup.log"
        touch "$LOG_FILE" || {
            echo -e "${RED}无法创建日志文件，将输出到控制台${NC}"
            LOG_FILE="/dev/null"
        }
    fi
    echo "=== 清理脚本开始运行 $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
}

# 日志记录函数
function log() {
    local log_msg="$(date '+%Y-%m-%d %H:%M:%S') - $*"
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo -e "$log_msg" >> "$LOG_FILE"
    fi
    # 同时显示在控制台（除非是自动模式）
    [ "$1" != "--auto" ] && echo -e "$log_msg"
}

# 显示函数
function pause() {
    [ "$1" != "--auto" ] && read -rp "按回车键继续..."
}

function info() {
    echo -e "${CYAN}[INFO] $*${NC}"
    log "[INFO] $*"
}

function success() {
    echo -e "${GREEN}[SUCCESS] $*${NC}"
    log "[SUCCESS] $*"
}

function warning() {
    echo -e "${YELLOW}[WARNING] $*${NC}"
    log "[WARNING] $*"
}

function error() {
    echo -e "${RED}[ERROR] $*${NC}"
    log "[ERROR] $*"
}

# 清理功能函数
function apt_cleanup() {
    info "开始清理APT缓存和孤包..."
    if apt-get clean && apt-get autoclean -y && apt-get autoremove --purge -y; then
        success "APT清理完成"
        return 0
    else
        error "APT清理失败"
        return 1
    fi
}

function systemd_log_cleanup() {
    info "限制systemd日志大小为${MAX_LOG_SIZE}MB..."
    if journalctl --vacuum-size=${MAX_LOG_SIZE}M; then
        success "systemd日志清理完成"
        return 0
    else
        error "systemd日志清理失败"
        return 1
    fi
}

function big_log_truncate() {
    info "截断大于${LOG_TRUNCATE_SIZE}MB的日志文件..."
    local truncated_files=0
    while IFS= read -r -d $'\0' file; do
        truncate -s 0 "$file"
        info "已截断: $file"
        ((truncated_files++))
    done < <(find /var/log -type f \( -name "*.log" -o -name "*.gz" \) -size +${LOG_TRUNCATE_SIZE}M -print0)

    if [ $truncated_files -gt 0 ]; then
        success "已截断 $truncated_files 个日志文件"
        return 0
    else
        warning "未找到需要截断的大日志文件"
        return 1
    fi
}

function tmp_cleanup() {
    info "清理${TMP_FILE_AGE}天未访问的临时文件..."
    local deleted_files=0
    
    # 清理/tmp
    info "清理/tmp目录..."
    while IFS= read -r -d $'\0' file; do
        rm -f "$file"
        ((deleted_files++))
    done < <(find /tmp -xdev -type f -atime +${TMP_FILE_AGE} -print0)

    # 清理/var/tmp
    info "清理/var/tmp目录..."
    while IFS= read -r -d $'\0' file; do
        rm -f "$file"
        ((deleted_files++))
    done < <(find /var/tmp -xdev -type f -atime +${TMP_FILE_AGE} -print0)

    if [ $deleted_files -gt 0 ]; then
        success "已删除 $deleted_files 个临时文件"
        return 0
    else
        warning "未找到需要清理的临时文件"
        return 1
    fi
}

function wp_cache_cleanup() {
    info "开始清理WordPress缓存和升级残留..."
    if [ ! -d "$WP_PATH" ]; then
        warning "WordPress路径不存在: $WP_PATH"
        return 1
    fi

    declare -a wp_dirs=(
        "$WP_PATH/wp-content/cache"
        "$WP_PATH/wp-content/boost-cache"
        "$WP_PATH/wp-content/autoptimize"
        "$WP_PATH/wp-content/w3tc"
        "$WP_PATH/wp-content/upgrade"
        "$WP_PATH/wp-content/backups"
        "$WP_PATH/wp-content/backup-db"
    )

    local cleaned_dirs=0
    for dir in "${wp_dirs[@]}"; do
        if [ -d "$dir" ]; then
            if [ "$(ls -A "$dir")" ]; then
                rm -rf "$dir"/*
                info "已清理: $dir"
                ((cleaned_dirs++))
            fi
        fi
    done

    if [ $cleaned_dirs -gt 0 ]; then
        success "已清理 $cleaned_dirs 个WordPress缓存目录"
        return 0
    else
        warning "未找到需要清理的WordPress缓存"
        return 1
    fi
}

function docker_cleanup() {
    if ! command -v docker >/dev/null 2>&1; then
        warning "未检测到Docker，跳过Docker清理"
        return 1
    fi

    info "Docker磁盘占用信息："
    docker system df

    info "清理停止的容器..."
    docker container prune -f

    info "清理未使用的镜像..."
    docker image prune -af

    info "清理构建缓存..."
    docker builder prune -af

    info "清理未使用的网络..."
    docker network prune -f

    info "截断Docker容器日志文件..."
    local truncated_logs=0
    if [ -d "$DOCKER_LOG_DIR" ]; then
        while IFS= read -r -d $'\0' logfile; do
            : > "$logfile"
            ((truncated_logs++))
        done < <(find "$DOCKER_LOG_DIR" -name "*-json.log" -type f -size +1M -print0)
    fi

    if [ $truncated_logs -gt 0 ]; then
        success "已截断 $truncated_logs 个Docker日志文件"
    else
        info "未找到需要截断的大Docker日志"
    fi

    success "Docker清理完成"
    return 0
}

function show_disk_usage() {
    info "当前磁盘使用情况："
    df -hT
    echo
    info "根目录下各目录大小排名："
    du -xhd1 / 2>/dev/null | sort -hr | head -n 15
    echo
    info "/var目录大小排名："
    du -xhd1 /var 2>/dev/null | sort -hr | head -n 10
}

function show_log() {
    clear
    echo -e "${BLUE}===== 最近清理日志 (最后20行) =====${NC}"
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 "$LOG_FILE"
    else
        warning "日志文件不存在: $LOG_FILE"
    fi
    echo
    echo -e "${YELLOW}完整日志请查看: $LOG_FILE${NC}"
    pause
}

function auto_cleanup() {
    local mode="$1"
    [ "$mode" == "--auto" ] && info "自动模式运行中..."
    
    info "开始执行所有清理任务..."
    apt_cleanup
    systemd_log_cleanup
    big_log_truncate
    tmp_cleanup
    wp_cache_cleanup
    docker_cleanup
    
    info "清理完成后的磁盘使用情况："
    show_disk_usage
    
    success "所有清理任务已完成"
    log "=== 清理脚本运行结束 ==="
}

function print_header() {
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${CYAN}      服务器磁盘空间清理维护脚本 v2.1       ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}最后运行时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo
}

function main_menu() {
    print_header
    echo "请选择执行操作："
    echo -e " 1) ${GREEN}清理APT缓存和孤包${NC}"
    echo -e " 2) ${GREEN}限制systemd日志大小${NC}"
    echo -e " 3) ${GREEN}截断大日志文件${NC}"
    echo -e " 4) ${GREEN}清理临时目录文件${NC}"
    echo -e " 5) ${GREEN}清理WordPress缓存${NC}"
    echo -e " 6) ${GREEN}清理Docker相关占用${NC}"
    echo -e " 7) ${CYAN}查看磁盘使用信息${NC}"
    echo -e " 8) ${BLUE}自动执行所有清理${NC}"
    echo -e " 9) ${YELLOW}查看清理日志${NC}"
    echo -e " 0) ${RED}退出脚本${NC}"
    echo
    read -rp "输入选项数字: " choice

    case $choice in
        1) apt_cleanup; pause; main_menu ;;
        2) systemd_log_cleanup; pause; main_menu ;;
        3) big_log_truncate; pause; main_menu ;;
        4) tmp_cleanup; pause; main_menu ;;
        5) wp_cache_cleanup; pause; main_menu ;;
        6) docker_cleanup; pause; main_menu ;;
        7) show_disk_usage; pause; main_menu ;;
        8) auto_cleanup; pause; main_menu ;;
        9) show_log; main_menu ;;
        0) clear; echo -e "${BLUE}感谢使用，再见！${NC}"; exit 0 ;;
        *) error "无效选项，请输入0-9之间的数字"; pause; main_menu ;;
    esac
}

# 主程序入口
init_log
if [ "$1" = "--auto" ]; then
    auto_cleanup "--auto"
else
    while true; do
        main_menu
    done
fi