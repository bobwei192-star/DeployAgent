#!/bin/bash
# ============================================================
# Artifactory 镜像阶梯式自动下载脚本 - 修复版
# 重点：正确尝试 Docker Hub 外网源，带重试和调试
# ============================================================

set -e

# ---------- 配置区 ----------
IMAGE_NAME="jfrog/artifactory-oss"
TAG="7.67.3"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

# 关键：Docker Hub 直接地址（能访问外网就用这个）
DOCKER_HUB="docker.io"
# 国内镜像源（备用）
declare -a MIRRORS=(
    "registry.cn-hangzhou.aliyuncs.com"
    "mirror.ccs.tencentyun.com"
    "docker.mirrors.sjtug.sjtu.edu.cn"
    "docker.m.daocloud.io"
)

# 备选版本（如果 7.67.3 确实有问题）
ALTERNATIVE_TAGS=("7.68.14" "7.63.5" "7.77.3" "latest")

# 重试次数
MAX_RETRY=3

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%F %T') $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%F %T') $1"; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%F %T') $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $(date '+%F %T') $1"; }

# ---------- 功能函数 ----------

# 带重试的拉取，并显示详细错误
pull_with_retry() {
    local image="$1"
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRY ]]; do
        info "尝试拉取: ${image} (第 ${attempt}/${MAX_RETRY} 次)"
        
        # 使用 --platform 指定 amd64，避免 manifest 问题
        # 使用 2>&1 捕获完整错误输出
        if docker pull --platform linux/amd64 "$image" 2>&1; then
            info "✓ 拉取成功: ${image}"
            return 0
        fi
        
        warn "第 ${attempt} 次失败，等待 3 秒后重试..."
        sleep 3
        ((attempt++))
    done
    
    return 1
}

# 尝试 Docker Hub 直接拉取（外网源）
try_docker_hub() {
    info "========================================"
    info "第1步: Docker Hub 直接拉取 (外网源)"
    info "========================================"
    
    # 直接拉取，不通过任何镜像代理
    if pull_with_retry "${FULL_IMAGE}"; then
        return 0
    fi
    
    # 如果失败，尝试用 docker.io 前缀
    warn "直接拉取失败，尝试显式指定 docker.io 前缀..."
    if pull_with_retry "docker.io/${FULL_IMAGE}"; then
        docker tag "docker.io/${FULL_IMAGE}" "${FULL_IMAGE}" 2>/dev/null || true
        return 0
    fi
    
    return 1
}

# 尝试国内镜像源
try_mirrors() {
    info "========================================"
    info "第2步: 国内镜像源"
    info "========================================"
    
    local step=1
    for mirror in "${MIRRORS[@]}"; do
        local mirror_image="${mirror}/${IMAGE_NAME}:${TAG}"
        info "[${step}/${#MIRRORS[@]}] 尝试: ${mirror_image}"
        
        if pull_with_retry "$mirror_image"; then
            info "✓ 从 ${mirror} 拉取成功，重命名中..."
            docker tag "$mirror_image" "${FULL_IMAGE}"
            docker rmi "$mirror_image" 2>/dev/null || true
            return 0
        fi
        
        ((step++))
    done
    
    return 1
}

# 尝试备选版本
try_alternative_tags() {
    info "========================================"
    info "第3步: 备选版本标签"
    info "========================================"
    
    for alt_tag in "${ALTERNATIVE_TAGS[@]}"; do
        local alt_image="${IMAGE_NAME}:${alt_tag}"
        info "尝试版本: ${alt_image}"
        
        if pull_with_retry "$alt_image"; then
            warn "⚠ 未找到 ${TAG}，但成功拉取 ${alt_tag}"
            info "创建标签映射: ${alt_image} -> ${FULL_IMAGE}"
            docker tag "$alt_image" "$FULL_IMAGE"
            return 0
        fi
    done
    
    return 1
}

# 手动下载 layer 并导入（终极方案）
manual_download_and_import() {
    info "========================================"
    info "第4步: 手动下载 layer 并组装"
    info "========================================"
    
    warn "此步骤需要 curl 和 jq，尝试获取 manifest 手动下载..."
    
    local token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMAGE_NAME}:pull"
    local registry_url="https://registry-1.docker.io/v2/${IMAGE_NAME}/manifests/${TAG}"
    
    info "获取认证 token..."
    local token=$(curl -fsSL "$token_url" 2>/dev/null | jq -r '.token' 2>/dev/null)
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        error "无法获取 Docker Hub 认证 token"
        return 1
    fi
    
    info "获取 manifest..."
    local manifest=$(curl -fsSL -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "$registry_url" 2>/dev/null)
    
    if [[ -z "$manifest" ]]; then
        error "无法获取 manifest"
        return 1
    fi
    
    info "manifest 获取成功，layer 数量: $(echo "$manifest" | jq '.layers | length')"
    warn "手动下载 layer 比较复杂，建议使用以下替代方案："
    echo ""
    echo "  方案A: 使用 skopeo 复制镜像"
    echo "    sudo apt install skopeo  # 或 yum install skopeo"
    echo "    skopeo copy docker://${FULL_IMAGE} docker-daemon:${FULL_IMAGE}"
    echo ""
    echo "  方案B: 使用 podman（兼容性更好）"
    echo "    sudo apt install podman"
    echo "    podman pull ${FULL_IMAGE}"
    echo "    podman save -o artifactory.tar ${FULL_IMAGE}"
    echo "    docker load -i artifactory.tar"
    echo ""
    
    return 1
}

# 诊断网络问题
diagnose_network() {
    info "========================================"
    info "网络诊断"
    info "========================================"
    
    debug "检查 DNS 解析..."
    nslookup registry-1.docker.io >/dev/null 2>&1 && info "DNS 正常" || warn "DNS 可能有问题"
    
    debug "检查 Docker Hub 连通性..."
    curl -sI https://registry-1.docker.io/v2/ >/dev/null 2>&1 && info "Docker Hub 可访问" || warn "Docker Hub 无法访问"
    
    debug "检查当前 Docker 镜像加速器配置..."
    if [[ -f /etc/docker/daemon.json ]]; then
        info "daemon.json 内容:"
        cat /etc/docker/daemon.json | grep -E "registry-mirrors|insecure-registries" || info "  (无镜像加速配置)"
    else
        info "无 daemon.json 配置"
    fi
    
    debug "Docker 版本信息:"
    docker version --format 'Server: {{.Server.Version}}' 2>/dev/null || docker version 2>/dev/null | head -5
}

# ---------- 主流程 ----------
main() {
    echo "============================================================"
    echo "  Artifactory 镜像阶梯下载工具 - 修复版"
    echo "  目标镜像: ${FULL_IMAGE}"
    echo "============================================================"
    
    # 检查Docker
    if ! sudo docker info >/dev/null 2>&1; then
        error "Docker 未运行或无权限，尝试 sudo..."
        if ! sudo docker info >/dev/null 2>&1; then
            error "Docker 确实无法访问"
            exit 1
        fi
    fi
    
    # 诊断网络
    diagnose_network
    
    # 1. Docker Hub 直接拉取（外网源）
    if try_docker_hub; then
        success_exit
    fi
    
    # 2. 国内镜像源
    if try_mirrors; then
        success_exit
    fi
    
    # 3. 备选版本
    if try_alternative_tags; then
        success_exit
    fi
    
    # 4. 手动方案
    manual_download_and_import
    
    # 全部失败
    error "所有方案均失败"
    echo ""
    echo "【可能原因】"
    echo "1. Docker Hub 的 manifest v2 校验问题（常见于旧版 Docker）"
    echo "2. 网络不稳定导致 layer 下载不完整"
    echo "3. 该镜像版本在 Docker Hub 上已被移除或标记为私有"
    echo ""
    echo "【建议】"
    echo "1. 升级 Docker: sudo apt update && sudo apt install docker-ce"
    echo "2. 清理缓存重试: sudo docker system prune -a"
    echo "3. 使用 skopeo: skopeo copy docker://${FULL_IMAGE} docker-daemon:${FULL_IMAGE}"
    echo "4. 在另一台机器下载后导入"
    echo ""
    
    exit 1
}

success_exit() {
    info "🎉 镜像获取成功: ${FULL_IMAGE}"
    info "镜像信息:"
    sudo docker images "${IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
    exit 0
}

# ---------- 命令行参数 ----------
case "${1:-}" in
    --diagnose|-d)
        diagnose_network
        ;;
    --help|-h)
        echo "用法: sudo bash $0 [选项]"
        echo "  无参数      执行完整阶梯下载流程"
        echo "  --diagnose  仅诊断网络问题"
        echo "  --help      显示帮助"
        ;;
    *)
        main
        ;;
esac
