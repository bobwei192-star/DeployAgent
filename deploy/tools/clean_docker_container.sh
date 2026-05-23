#!/bin/bash
# =============================================================================
# DevOpsAgent Docker 容器清理工具
# sudo ./tools/clean_docker_container.sh --all --volumes
# =============================================================================
# 功能：
#   - 列出所有 devopsagent-* 容器
#   - 交互式选择停止/删除容器
#   - 一键停止/删除所有 devopsagent-* 容器
#   - 可选清理命名卷
#
# 使用方法:
#   sudo ./tools/clean_docker_container.sh          # 交互式菜单
#   sudo ./tools/clean_docker_container.sh --list    # 仅列出容器
#   sudo ./tools/clean_docker_container.sh --stop    # 停止所有 devopsagent-* 容器
#   sudo ./tools/clean_docker_container.sh --rm      # 删除所有 devopsagent-* 容器
#   sudo ./tools/clean_docker_container.sh --all     # 停止并删除所有 devopsagent-* 容器
#   sudo ./tools/clean_docker_container.sh --all --volumes  # 停止+删除容器+清理卷
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PREFIX="devopsagent"

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') - $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1"; }
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }

list_containers() {
    local status="${1:-all}"

    if [[ "$status" == "running" ]]; then
        docker ps --filter "name=$PREFIX" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    elif [[ "$status" == "all" ]]; then
        docker ps -a --filter "name=$PREFIX" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi
}

get_containers() {
    local status="${1:-all}"
    if [[ "$status" == "running" ]]; then
        docker ps --filter "name=$PREFIX" --format "{{.Names}}" 2>/dev/null || true
    else
        docker ps -a --filter "name=$PREFIX" --format "{{.Names}}" 2>/dev/null || true
    fi
}

stop_all() {
    log_step "停止所有 ${PREFIX}-* 容器"
    local containers=$(get_containers "running")
    if [[ -z "$containers" ]]; then
        log_info "没有运行中的 ${PREFIX}-* 容器"
        return 0
    fi
    echo "$containers" | while read -r name; do
        [[ -z "$name" ]] && continue
        log_info "停止: $name"
        docker stop "$name" 2>/dev/null && log_info "  ✓ 已停止" || log_warn "  ✗ 停止失败"
    done
}

remove_all() {
    log_step "删除所有 ${PREFIX}-* 容器"
    local containers=$(get_containers "all")
    if [[ -z "$containers" ]]; then
        log_info "没有 ${PREFIX}-* 容器"
        return 0
    fi
    echo "$containers" | while read -r name; do
        [[ -z "$name" ]] && continue
        log_info "删除: $name"
        docker rm -f "$name" 2>/dev/null && log_info "  ✓ 已删除" || log_warn "  ✗ 删除失败"
    done
}

cleanup_volumes() {
    log_step "清理 ${PREFIX}-* 命名卷"
    local volumes=$(docker volume ls --filter "name=$PREFIX" --format "{{.Name}}" 2>/dev/null || true)
    if [[ -z "$volumes" ]]; then
        log_info "没有 ${PREFIX}-* 命名卷"
        return 0
    fi
    echo "$volumes" | while read -r name; do
        [[ -z "$name" ]] && continue
        log_info "删除卷: $name"
        docker volume rm "$name" 2>/dev/null && log_info "  ✓ 已删除" || log_warn "  ✗ 删除失败"
    done
}

interactive_menu() {
    echo
    echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│        DevOpsAgent 容器清理工具              │${NC}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────┘${NC}"
    echo

    log_step "当前 ${PREFIX}-* 容器状态"
    local all=$(get_containers "all" | wc -l)
    local run_count=$(get_containers "running" | wc -l)
    echo
    echo -e "  运行中: ${BOLD}$run_count${NC} 个"
    echo -e "  总共:   ${BOLD}$all${NC} 个"
    echo
    if [[ $all -gt 0 ]]; then
        list_containers "all"
        echo
    fi

    echo -e "${BOLD}请选择操作:${NC}"
    echo
    echo -e "  ${CYAN}[1]${NC} 停止所有 ${PREFIX}-* 容器"
    echo -e "  ${CYAN}[2]${NC} 删除所有 ${PREFIX}-* 容器 (先停止)"
    echo -e "  ${CYAN}[3]${NC} 停止+删除+清理命名卷"
    echo -e "  ${CYAN}[4]${NC} 仅列出容器"
    echo -e "  ${CYAN}[0]${NC} 退出"
    echo

    read -p "请输入选项 (0-4): " choice
    echo

    case "$choice" in
        1)
            echo -e "${YELLOW}⚠ 将停止所有 ${PREFIX}-* 容器${NC}"
            read -p "确认? (y/N): " confirm
            if [[ "$confirm" =~ ^[yY] ]]; then
                stop_all
                log_info "操作完成"
            else
                log_info "已取消"
            fi
            ;;
        2)
            echo -e "${RED}⚠ 将删除所有 ${PREFIX}-* 容器及数据${NC}"
            read -p "确认? (y/N): " confirm
            if [[ "$confirm" =~ ^[yY] ]]; then
                stop_all
                remove_all
                log_info "操作完成"
            else
                log_info "已取消"
            fi
            ;;
        3)
            echo -e "${RED}⚠ 将删除所有 ${PREFIX}-* 容器 + 命名卷 (数据不可恢复!)${NC}"
            read -p "确认? (y/N): " confirm
            if [[ "$confirm" =~ ^[yY] ]]; then
                stop_all
                remove_all
                cleanup_volumes
                log_info "操作完成"
            else
                log_info "已取消"
            fi
            ;;
        4)
            list_containers "all"
            ;;
        0)
            log_info "退出"
            exit 0
            ;;
        *)
            log_error "无效选项"
            exit 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════

if [[ $EUID -ne 0 ]]; then
    log_warn "推荐使用 sudo 运行以确保有 Docker 操作权限"
    echo
fi

case "${1:-}" in
    --list|-l)
        log_step "${PREFIX}-* 容器列表"
        list_containers "all"
        ;;
    --stop|-s)
        stop_all
        ;;
    --rm|-r)
        echo -e "${RED}⚠ 将删除所有 ${PREFIX}-* 容器${NC}"
        read -p "确认? (y/N): " confirm
        if [[ "$confirm" =~ ^[yY] ]]; then
            stop_all
            remove_all
            log_info "操作完成"
        else
            log_info "已取消"
        fi
        ;;
    --all|-a)
        echo -e "${RED}⚠ 将删除所有 ${PREFIX}-* 容器${NC}"
        if [[ "${2:-}" == "--volumes" || "${2:-}" == "-v" ]]; then
            echo -e "${RED}⚠ 同时清理命名卷 (数据不可恢复!)${NC}"
        fi
        read -p "确认? (y/N): " confirm
        if [[ "$confirm" =~ ^[yY] ]]; then
            stop_all
            remove_all
            if [[ "${2:-}" == "--volumes" || "${2:-}" == "-v" ]]; then
                cleanup_volumes
            fi
            log_info "操作完成"
        else
            log_info "已取消"
        fi
        ;;
    --volumes|-v)
        cleanup_volumes
        ;;
    --help|-h|*)
        echo
        echo -e "${BOLD}DevOpsAgent Docker 容器清理工具${NC}"
        echo
        echo -e "用法: $0 [选项]"
        echo
        echo -e "选项:"
        echo -e "  ${CYAN}(无参数)${NC}      交互式菜单"
        echo -e "  ${CYAN}--list${NC}        仅列出所有 ${PREFIX}-* 容器"
        echo -e "  ${CYAN}--stop${NC}        停止所有 ${PREFIX}-* 容器"
        echo -e "  ${CYAN}--rm${NC}          删除所有 ${PREFIX}-* 容器"
        echo -e "  ${CYAN}--all${NC}         停止并删除所有 ${PREFIX}-* 容器"
        echo -e "  ${CYAN}--all --volumes${NC} 停止+删除+清理命名卷"
        echo -e "  ${CYAN}--volumes${NC}     仅清理 ${PREFIX}-* 命名卷"
        echo -e "  ${CYAN}--help${NC}        显示此帮助"
        echo
        ;;
esac
