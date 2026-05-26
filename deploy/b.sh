#!/bin/bash
# ============================================================
# Artifactory 镜像阶梯式自动下载脚本
# 支持：docker pull / 镜像导出导入 / 离线tar包
# ============================================================

set -e

# ---------- 配置区 ----------
IMAGE_NAME="jfrog/artifactory-oss"
TAG="7.67.3"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"
LOCAL_TAR="/opt/artifactory-oss-${TAG}.tar"  # 离线包路径（如有）
ALTERNATIVE_TAGS=("latest" "7.68.14" "7.63.5")  # 备选版本

# 镜像源优先级（从快到慢/从私有到公共）
declare -a REGISTRIES=(
    "docker.io"                          # Docker Hub 官方
    "registry.cn-hangzhou.aliyuncs.com"  # 阿里云（需存在）
    "mirror.ccs.tencentyun.com"          # 腾讯云
    "hub-mirror.c.163.com"               # 网易（已停用，备用）
    "docker.mirrors.sjtug.sjtu.edu.cn"   # 上海交大
    "docker.m.daocloud.io"               # DaoCloud
)

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%F %T') $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%F %T') $1"; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%F %T') $1"; }

# ---------- 功能函数 ----------

# 检查本地是否已有镜像
check_local() {
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${FULL_IMAGE}$"; then
        info "✓ 本地已存在镜像: ${FULL_IMAGE}"
        return 0
    fi
    return 1
}

# 尝试从本地tar包导入
try_import_tar() {
    if [[ -f "$LOCAL_TAR" ]]; then
        info "发现本地离线包: ${LOCAL_TAR}"
        if docker load -i "$LOCAL_TAR"; then
            info "✓ 离线包导入成功"
            return 0
        else
            warn "离线包导入失败"
        fi
    fi
    return 1
}

# 阶梯式拉取：逐个源尝试
try_pull_stepped() {
    local target="$1"
    info "开始阶梯式拉取: ${target}"
    
    # 1. 先尝试直接拉取（使用系统配置的镜像加速）
    info "第1步: 直接拉取 ${target} ..."
    if docker pull "$target" 2>/dev/null; then
        info "✓ 直接拉取成功"
        return 0
    fi
    warn "直接拉取失败"
    
    # 2. 逐个镜像源尝试
    local step=2
    for registry in "${REGISTRIES[@]}"; do
        # 跳过docker.io（已经试过了）
        [[ "$registry" == "docker.io" ]] && continue
        
        local mirror_image="${registry}/${IMAGE_NAME}:${TAG}"
        info "第${step}步: 尝试镜像源 ${mirror_image} ..."
        
        if docker pull "$mirror_image" 2>/dev/null; then
            info "✓ 从 ${registry} 拉取成功，正在重命名..."
            docker tag "$mirror_image" "$target"
            docker rmi "$mirror_image" 2>/dev/null || true
            info "✓ 镜像已重命名为 ${target}"
            return 0
        fi
        
        warn "${registry} 失败"
        ((step++))
    done
    
    return 1
}

# 尝试备选版本标签
try_alternative_tags() {
    info "尝试备选版本标签..."
    for alt_tag in "${ALTERNATIVE_TAGS[@]}"; do
        local alt_image="${IMAGE_NAME}:${alt_tag}"
        info "尝试版本: ${alt_image}"
        
        if docker pull "$alt_image" 2>/dev/null; then
            warn "⚠ 未找到 ${TAG}，但成功拉取 ${alt_tag}"
            warn "  建议: docker tag ${alt_image} ${FULL_IMAGE}"
            docker tag "$alt_image" "$FULL_IMAGE"
            info "已自动创建标签: ${FULL_IMAGE}"
            return 0
        fi
    done
    return 1
}

# 导出镜像（用于传输到离线环境）
export_image() {
    local output_path="${1:-/tmp/artifactory-oss-${TAG}-export.tar}"
    info "导出镜像到: ${output_path}"
    docker save -o "$output_path" "$FULL_IMAGE"
    info "✓ 导出完成，大小: $(du -h "$output_path" | cut -f1)"
    info "  传输到目标机后执行: docker load -i ${output_path}"
}

# ---------- 主流程 ----------
main() {
    echo "============================================================"
    echo "  Artifactory 镜像阶梯下载工具"
    echo "  目标镜像: ${FULL_IMAGE}"
    echo "============================================================"
    
    # 0. 检查Docker
    if ! docker info >/dev/null 2>&1; then
        error "Docker 未运行或无权限"
        exit 1
    fi
    
    # 1. 检查本地是否已有
    if check_local; then
        read -p "是否导出镜像到tar包? [y/N]: " ans
        [[ "$ans" == "y" || "$ans" == "Y" ]] && export_image
        exit 0
    fi
    
    # 2. 尝试本地tar导入
    if try_import_tar; then
        exit 0
    fi
    
    # 3. 阶梯式拉取主版本
    if try_pull_stepped "$FULL_IMAGE"; then
        info "🎉 镜像获取成功: ${FULL_IMAGE}"
        read -p "是否导出镜像备份? [y/N]: " ans
        [[ "$ans" == "y" || "$ans" == "Y" ]] && export_image
        exit 0
    fi
    
    # 4. 尝试备选版本
    if try_alternative_tags; then
        info "🎉 通过备选版本获取成功"
        exit 0
    fi
    
    # 5. 全部失败，给出离线方案
    error "所有在线源均失败，网络环境受限"
    echo ""
    echo "【离线解决方案】"
    echo "1. 在能访问外网的机器上执行："
    echo "   docker pull ${FULL_IMAGE}"
    echo "   docker save -o artifactory-oss-${TAG}.tar ${FULL_IMAGE}"
    echo ""
    echo "2. 将 tar 包传输到本机 (${LOCAL_TAR})，然后："
    echo "   docker load -i artifactory-oss-${TAG}.tar"
    echo ""
    echo "3. 或者使用本脚本的导出模式（在有网络的机器上）："
    echo "   $0 --export-only"
    echo ""
    
    exit 1
}

# ---------- 命令行参数 ----------
case "${1:-}" in
    --export-only)
        check_local || { error "本地没有 ${FULL_IMAGE}"; exit 1; }
        export_image "${2:-/tmp/artifactory-oss-${TAG}-export.tar}"
        ;;
    --import)
        LOCAL_TAR="${2:-$LOCAL_TAR}"
        try_import_tar || { error "导入失败"; exit 1; }
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo "  无参数      执行完整阶梯下载流程"
        echo "  --export-only [路径]  导出本地镜像为tar包"
        echo "  --import <tar路径>    从tar包导入镜像"
        echo "  --help                显示帮助"
        ;;
    *)
        main
        ;;
esac
