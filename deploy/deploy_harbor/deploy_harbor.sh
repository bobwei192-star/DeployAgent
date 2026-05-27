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
set -o pipefail

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

check_harbor_conflicts() {
    if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:1514|0\.0\.0\.0:1514|188\.188\.88\.4:1514'; then
        log_error "Harbor 日志端口 1514 已被占用，harbor-log 无法启动"
        log_info "占用情况:"
        ss -tlnp 2>/dev/null | grep ':1514' || true
        return 1
    fi
}

patch_harbor_compose() {
    local harbor_install_dir="$1"
    local compose_file="$harbor_install_dir/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        log_error "Harbor docker-compose.yml 不存在: $compose_file"
        return 1
    fi

    # Harbor 官方 compose 使用 redis/nginx/registry 等全局 container_name,
    # 在共享 Docker 主机上容易与其他服务冲突；删除后由 compose 项目前缀隔离。
    sed -i '/^[[:space:]]*container_name:/d' "$compose_file"
}

deploy_harbor() {
    log_step "部署 Harbor 容器镜像仓库"

    check_harbor_conflicts

    if [[ ! -d "$HARBOR_DATA_DIR" ]]; then
        log_info "创建 Harbor 数据目录: $HARBOR_DATA_DIR"
        mkdir -p "$HARBOR_DATA_DIR"
    fi

    log_info "下载 Harbor 离线安装包..."
    local harbor_tar="harbor-offline-installer-${HARBOR_VERSION}.tgz"
    local harbor_url="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${harbor_tar}"
    local tarball="$HARBOR_DATA_DIR/$harbor_tar"

    # 下载（如果文件已存在先做完整性校验，损坏则重新下载）
    local need_download=true
    if [[ -f "$tarball" ]]; then
        if gzip -t "$tarball" 2>/dev/null; then
            local fsize; fsize=$(stat -c%s "$tarball" 2>/dev/null || stat -f%z "$tarball" 2>/dev/null)
            # Harbor v2.10 离线包约 550MB+，小于 100MB 视为损坏
            if [[ "$fsize" -gt 104857600 ]]; then
                log_info "安装包已存在且校验通过 (${fsize} bytes)，跳过下载"
                need_download=false
            else
                log_warn "安装包文件过小 (${fsize} bytes)，可能下载中断，重新下载..."
                rm -f "$tarball"
            fi
        else
            log_warn "安装包 gzip 校验失败，文件损坏，重新下载..."
            rm -f "$tarball"
        fi
    fi

    if $need_download; then
        if ! curl -fSL --connect-timeout 20 --max-time 1200 -o "$tarball" "$harbor_url"; then
            log_warn "从 GitHub 下载失败，尝试国内镜像..."
            rm -f "$tarball"
            if ! curl -fSL --connect-timeout 20 --max-time 1200 -o "$tarball" "https://mirror.ghproxy.com/${harbor_url}"; then
                log_error "Harbor 安装包下载失败（GitHub 和镜像均失败）"
                rm -f "$tarball"
                return 1
            fi
        fi
    fi

    if [[ ! -f "$tarball" ]]; then
        log_error "Harbor 安装包下载失败"
        return 1
    fi

    log_info "解压 Harbor 安装包..."
    if ! tar -xzf "$tarball" -C "$HARBOR_DATA_DIR"; then
        log_error "Harbor 安装包解压失败，文件已损坏，自动清理后请重新部署"
        rm -f "$tarball"
        return 1
    fi

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

    log_info "加载 Harbor 镜像并生成配置..."
    cd "$harbor_install_dir"
    if [[ -f harbor*.tar.gz ]]; then
        docker load -i ./harbor*.tar.gz
    fi
    ./prepare --with-trivy
    patch_harbor_compose "$harbor_install_dir"

    log_info "启动 Harbor compose 服务..."
    docker compose -p devopsagent-harbor up -d

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
        cd "$harbor_install_dir" && docker compose -p devopsagent-harbor ps
        return 1
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