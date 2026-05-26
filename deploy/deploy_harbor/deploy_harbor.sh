#!/bin/bash
# =============================================================================
# DevOpsAgent Harbor 部署脚本
# =============================================================================
# 功能：
#   - 部署 Harbor 容器镜像仓库
#   - 配置数据持久化
#   - 支持 HTTP 模式（简化部署）
#   - 支持 Nginx 反向代理
#
# 使用方法：
#   - 独立运行: sudo ./deploy_harbor/deploy_harbor.sh
#   - 被主脚本调用: source deploy_harbor/deploy_harbor.sh
#
# 端口配置:
#   - Harbor HTTP: 8082
#   - Harbor HTTPS: 8445
#   - Harbor Registry: 5002
#   - Nginx Harbor: 18446
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"

source "$LIB_DIR/common.sh"

HARBOR_PORT_HTTP="${HARBOR_PORT_HTTP:-8082}"
HARBOR_PORT_HTTPS="${HARBOR_PORT_HTTPS:-8445}"
HARBOR_PORT_REGISTRY="${HARBOR_PORT_REGISTRY:-5002}"
HARBOR_BIND="${HARBOR_BIND:-127.0.0.1}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
HARBOR_DATA_DIR="${HARBOR_DATA_DIR:-$PROJECT_DIR/data/harbor}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.10.0}"

deploy_harbor() {
    log_step "部署 Harbor 容器镜像仓库"

    if [[ ! -d "$HARBOR_DATA_DIR" ]]; then
        log_info "创建 Harbor 数据目录: $HARBOR_DATA_DIR"
        mkdir -p "$HARBOR_DATA_DIR"
    fi

    log_info "下载 Harbor 离线安装包..."
    local harbor_tar="harbor-offline-installer-${HARBOR_VERSION}.tgz"
    local harbor_url="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${harbor_tar}"
    
    if [[ ! -f "$HARBOR_DATA_DIR/$harbor_tar" ]]; then
        if ! curl -SL "$harbor_url" -o "$HARBOR_DATA_DIR/$harbor_tar" 2>/dev/null; then
            log_warn "从 GitHub 下载失败，尝试国内镜像..."
            curl -SL "https://mirror.ghproxy.com/${harbor_url}" -o "$HARBOR_DATA_DIR/$harbor_tar"
        fi
    fi

    if [[ ! -f "$HARBOR_DATA_DIR/$harbor_tar" ]]; then
        log_error "Harbor 安装包下载失败"
        return 1
    fi

    log_info "解压 Harbor 安装包..."
    tar -xzf "$HARBOR_DATA_DIR/$harbor_tar" -C "$HARBOR_DATA_DIR"

    local harbor_install_dir="$HARBOR_DATA_DIR/harbor"
    if [[ ! -d "$harbor_install_dir" ]]; then
        log_error "Harbor 解压失败"
        return 1
    fi

    log_info "生成 Harbor 配置文件..."
    cp "$harbor_install_dir/harbor.yml.tmpl" "$harbor_install_dir/harbor.yml"

    sed -i "s|^hostname: .*|hostname: localhost|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^http:|#http:|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^  port: 80|  #port: 80|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^https:|http:|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^  port: 443|  port: $HARBOR_PORT_HTTP|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^    certificate: .*|#    certificate:|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^    private_key: .*|#    private_key:|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^harbor_admin_password: .*|harbor_admin_password: $HARBOR_ADMIN_PASSWORD|" "$harbor_install_dir/harbor.yml"
    sed -i "s|^data_volume: .*|data_volume: $HARBOR_DATA_DIR/data|" "$harbor_install_dir/harbor.yml"

    log_info "停止并清理旧的 Harbor 容器..."
    if [[ -f "$harbor_install_dir/docker-compose.yml" ]]; then
        cd "$harbor_install_dir" && docker compose down -v 2>/dev/null || true
    fi

    log_info "运行 Harbor 安装脚本..."
    cd "$harbor_install_dir" && ./install.sh --with-trivy 2>&1 | tail -20

    log_info "等待 Harbor 启动..."
    local max_wait=180
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        if curl -s "http://$HARBOR_BIND:$HARBOR_PORT_HTTP/api/v2.0/ping" | grep -q "pong"; then
            log_info "✓ Harbor 启动完成"
            break
        fi
        sleep 5
        wait_count=$((wait_count + 5))
        if [[ $((wait_count % 30)) -eq 0 ]]; then
            log_info "等待中... ($wait_count/$max_wait 秒)"
        fi
    done

    if [[ $wait_count -ge $max_wait ]]; then
        log_warn "Harbor 启动超时，检查容器状态..."
        cd "$harbor_install_dir" && docker compose ps
    fi

    log_info "✓ Harbor 部署完成"
    log_info "  默认用户名: admin"
    log_info "  默认密码: $HARBOR_ADMIN_PASSWORD"
    log_info "  访问地址: http://${HARBOR_BIND}:${HARBOR_PORT_HTTP}"

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_harbor "$@"
fi