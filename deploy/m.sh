#!/bin/bash
# ============================================================
# Artifactory 镜像阶梯式自动下载脚本 - 最终版
# 整合问题：官方仓库移除、加速器缓存损坏、第三方镜像 fallback
# 适用：Docker Hub 官方镜像失效后的替代方案
# ============================================================

set -e

# ---------- 配置区 ----------
IMAGE_NAME="jfrog/artifactory-oss"
TAG="7.67.3"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

# 官方源（已失效，仅作记录）
# OFFICIAL="docker.io/jfrog/artifactory-oss:${TAG}"

# 第三方搬运镜像（按可信度排序）
declare -a THIRD_PARTY_IMAGES=(
    "jijidom/artifactory-oss:latest"      # 标注来源 releases-docker.jfrog.io
    "jaysong/artifactory-oss:latest"      # 社区维护
    "goodrainapps/artifactory-oss:latest" # 企业应用商店
    "yunlzheng/artifactory-oss:latest"   # Rancher catalog
)

# 替代方案：Nexus3（Artifactory 的完全替代品）
NEXUS_IMAGE="sonatype/nexus3:latest"

# 日志颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%F %T') $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%F %T') $1"; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%F %T') $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $(date '+%F %T') $1"; }

# ---------- 核心函数 ----------

# 检查本地是否已有镜像
check_local() {
    if sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${FULL_IMAGE}$"; then
        info "✓ 本地已存在镜像: ${FULL_IMAGE}"
        return 0
    fi
    return 1
}

# 尝试第三方搬运镜像
try_third_party() {
    info "========================================"
    info "第1步: 尝试第三方搬运镜像"
    info "========================================"
    info "原因: JFrog 官方已从 Docker Hub 移除 artifactory-oss 镜像"
    info "      原官方仓库返回: pull access denied"
    
    local step=1
    for img in "${THIRD_PARTY_IMAGES[@]}"; do
        info "[${step}/${#THIRD_PARTY_IMAGES[@]}] 尝试: ${img}"
        
        # 先检查该镜像是否存在
        if sudo docker pull "$img" 2>&1; then
            info "✓ 拉取成功: ${img}"
            info "  来源说明: $(sudo docker inspect "$img" --format '{{.Comment}}' 2>/dev/null || echo '无')"
            
            # 重命名为脚本期望的官方名称
            info "重命名: ${img} -> ${FULL_IMAGE}"
            sudo docker tag "$img" "$FULL_IMAGE"
            
            # 可选：保留或删除原始标签
            # sudo docker rmi "$img" 2>/dev/null || true
            
            info "✓ 完成！脚本可继续使用 ${FULL_IMAGE}"
            return 0
        fi
        
        warn "拉取失败，尝试下一个..."
        ((step++))
    done
    
    return 1
}

# 尝试 Nexus3 替代方案
try_nexus_alternative() {
    info "========================================"
    info "第2步: Nexus3 替代方案"
    info "========================================"
    info "Artifactory OSS Docker 生态已死，建议迁移到 Nexus3"
    
    read -p "是否部署 Nexus3 作为替代? [y/N]: " ans
    if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
        return 1
    fi
    
    info "拉取 Nexus3 官方镜像..."
    if sudo docker pull "$NEXUS_IMAGE"; then
        info "✓ Nexus3 拉取成功"
        info "  运行命令: sudo docker run -d -p 8081:8081 --name nexus ${NEXUS_IMAGE}"
        info "  默认密码: 进入容器后 cat /nexus-data/admin.password"
        
        # 如果需要，可以自动运行
        read -p "是否立即启动 Nexus3 容器? [y/N]: " run
        if [[ "$run" == "y" || "$run" == "Y" ]]; then
            sudo docker run -d -p 8081:8081 --name nexus -v nexus-data:/nexus-data "$NEXUS_IMAGE"
            info "✓ Nexus3 已启动，访问: http://localhost:8081"
        fi
        
        return 0
    fi
    
    return 1
}

# 网络诊断（排查加速器问题）
diagnose() {
    info "========================================"
    info "网络与 Docker 诊断"
    info "========================================"
    
    # Docker 版本
    debug "Docker 版本:"
    sudo docker version --format 'Server: {{.Server.Version}}' 2>/dev/null || true
    
    # 加速器配置
    debug "当前加速器配置:"
    if [[ -f /etc/docker/daemon.json ]]; then
        grep "registry-mirrors" -A 20 /etc/docker/daemon.json || info "无配置"
    else
        info "无 daemon.json"
    fi
    
    # 连通性测试
    debug "Docker Hub 连通性:"
    curl -sI https://registry-1.docker.io/v2/ >/dev/null 2>&1 && info "可达" || warn "不可达"
    
    # 官方仓库状态
    debug "官方仓库状态 (jfrog/artifactory-oss):"
    local status=$(curl -s -o /dev/null -w "%{http_code}" \
        https://hub.docker.com/v2/repositories/jfrog/artifactory-oss/tags/7.67.3 2>/dev/null || echo "000")
    info "HTTP 状态: ${status} (404=不存在/私有, 200=公开)"
}

# 清理损坏的加速器缓存
clean_cache() {
    warn "清理 Docker 缓存..."
    sudo docker system prune -a -f
    info "缓存已清理"
}

# ---------- 主流程 ----------
main() {
    echo "============================================================"
    echo "  Artifactory 镜像下载脚本 - 最终版"
    echo "  目标: ${FULL_IMAGE}"
    echo "  状态: 官方仓库已移除，使用第三方搬运镜像"
    echo "============================================================"
    
    # 检查 Docker
    if ! sudo docker info >/dev/null 2>&1; then
        error "Docker 无法访问"
        exit 1
    fi
    
    # 检查本地
    if check_local; then
        info "无需下载"
        exit 0
    fi
    
    # 诊断
    diagnose
    
    # 1. 尝试第三方镜像
    if try_third_party; then
        info "🎉 Artifactory 镜像准备完成"
        info "镜像信息:"
        sudo docker images "$IMAGE_NAME" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.ID}}"
        exit 0
    fi
    
    # 2. Nexus3 替代
    if try_nexus_alternative; then
        info "🎉 Nexus3 部署完成，可作为 Artifactory 替代品"
        exit 0
    fi
    
    # 全部失败
    error "所有方案均失败"
    echo ""
    echo "【问题总结】"
    echo "1. JFrog 官方已从 Docker Hub 移除 artifactory-oss 镜像"
    echo "2. 原官方仓库 (docker.io/jfrog/artifactory-oss) 返回 403/404"
    echo "3. 国内加速器缓存了损坏的 manifest，导致 size validation 错误"
    echo "4. 第三方搬运镜像可能也已失效"
    echo ""
    echo "【最终建议】"
    echo "• 迁移到 Nexus3: sudo docker pull sonatype/nexus3:latest"
    echo "• 或使用 JFrog 官方安装包（非 Docker）"
    echo "• 检查: https://jfrog.com/help/r/jfrog-installation-setup-documentation"
    echo ""
    
    exit 1
}

# ---------- 命令行 ----------
case "${1:-}" in
    --diagnose|-d) diagnose ;;
    --clean|-c)    clean_cache ;;
    --nexus)       try_nexus_alternative ;;
    --help|-h)
        echo "用法: sudo bash $0 [选项]"
        echo "  无参数      执行完整下载流程"
        echo "  --diagnose  诊断网络和 Docker 配置"
        echo "  --clean     清理 Docker 缓存"
        echo "  --nexus     直接部署 Nexus3 替代"
        echo "  --help      显示帮助"
        ;;
    *) main ;;
esac
