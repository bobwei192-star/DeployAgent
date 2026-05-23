#!/bin/bash
# =============================================================================
# DevOpsAgent Langfuse 部署脚本
# =============================================================================
# 功能：
#   - 部署 Langfuse LLM 可观测性平台
#   - git clone langfuse/lanhfuse 仓库
#   - docker compose 方式拉起服务
#
# 使用方法：
#   - 独立运行: sudo ./deploy_langfuse/deploy_langfuse.sh
#   - 被主脚本调用: source deploy_langfuse/deploy_langfuse.sh
#
# 端口配置:
#   - Langfuse Web: 3000
#   - Nginx Langfuse: 18447
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
DOCKER_COMPOSE_CMD=""

source "$LIB_DIR/common.sh"

LANGFUSE_PORT_WEB="${LANGFUSE_PORT_WEB:-3000}"
LANGFUSE_BIND="${LANGFUSE_BIND:-127.0.0.1}"
LANGFUSE_REPO="${LANGFUSE_REPO:-https://github.com/langfuse/langfuse.git}"
LANGFUSE_REPO_DIR="${LANGFUSE_REPO_DIR:-$PROJECT_DIR/data/langfuse/repo}"
LANGFUSE_CONTAINER_PREFIX="${LANGFUSE_CONTAINER_PREFIX:-devopsagent-langfuse}"

LANGFUSE_USE_HTTPS_PROXY="${LANGFUSE_USE_HTTPS_PROXY:-false}"
LANGFUSE_NGINX_PORT="${LANGFUSE_NGINX_PORT:-18447}"
LANGFUSE_HOSTNAME="${LANGFUSE_HOSTNAME:-127.0.0.1}"

if [[ "$LANGFUSE_USE_HTTPS_PROXY" == "true" ]]; then
    LANGFUSE_EXTERNAL_URL="${LANGFUSE_EXTERNAL_URL:-https://$LANGFUSE_HOSTNAME:$LANGFUSE_NGINX_PORT}"
else
    LANGFUSE_EXTERNAL_URL="${LANGFUSE_EXTERNAL_URL:-http://$LANGFUSE_HOSTNAME:$LANGFUSE_PORT_WEB}"
fi

deploy_langfuse() {
    log_step "部署 Langfuse LLM 可观测性平台"

    mkdir -p "$(dirname "$LANGFUSE_REPO_DIR")"

    if [[ -d "$LANGFUSE_REPO_DIR/.git" ]]; then
        log_info "Langfuse 仓库已存在, 更新代码..."
        cd "$LANGFUSE_REPO_DIR"
        git pull --ff-only origin main 2>/dev/null || git pull --ff-only origin master 2>/dev/null || {
            log_warn "git pull 失败，使用现有代码"
        }
    else
        log_info "克隆 Langfuse 仓库..."
        rm -rf "$LANGFUSE_REPO_DIR"
        git clone --depth 1 "$LANGFUSE_REPO" "$LANGFUSE_REPO_DIR" || {
            log_error "git clone 失败: $LANGFUSE_REPO"
            return 1
        }
    fi

    cd "$LANGFUSE_REPO_DIR"

    if [[ ! -f "docker-compose.yml" ]] && [[ ! -f "docker-compose.yaml" ]]; then
        log_error "未找到 docker-compose.yml, 请检查仓库结构"
        ls -la "$LANGFUSE_REPO_DIR"/
        return 1
    fi

    log_info "配置 Langfuse 环境变量..."
    cat > .env << LANGFUSE_ENV_EOF
# DevOpsAgent 自动生成
NEXTAUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "langfuse-auto-$(date +%s)")
SALT=$(openssl rand -hex 16 2>/dev/null || echo "salt-auto-$(date +%s)")
ENCRYPTION_KEY=$(openssl rand -hex 32 2>/dev/null || echo "enc-auto-$(date +%s)")
NEXTAUTH_URL=$LANGFUSE_EXTERNAL_URL
HOSTNAME=$LANGFUSE_EXTERNAL_URL
NEXT_PUBLIC_SIGN_UP_DISABLED=false
TELEMETRY_ENABLED=false
LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES=true
LANGFUSE_SDK_CI_SYNC_PROCESSING_ENABLED=true
DATABASE_URL=postgresql://postgres:postgres@${LANGFUSE_CONTAINER_PREFIX}-postgres:5432/postgres
DIRECT_URL=postgresql://postgres:postgres@${LANGFUSE_CONTAINER_PREFIX}-postgres:5432/postgres
REDIS_HOST=${LANGFUSE_CONTAINER_PREFIX}-redis
REDIS_PORT=6379
CLICKHOUSE_URL=http://${LANGFUSE_CONTAINER_PREFIX}-clickhouse:8123
CLICKHOUSE_USER=clickhouse
CLICKHOUSE_PASSWORD=clickhouse
CLICKHOUSE_MIGRATION_URL=clickhouse://${LANGFUSE_CONTAINER_PREFIX}-clickhouse:9000
CLICKHOUSE_CLUSTER_ENABLED=false
LANGFUSE_USE_NAMED_VOLUMES=true
COMPOSE_PROJECT_NAME=${LANGFUSE_CONTAINER_PREFIX}
LANGFUSE_ENV_EOF
    log_info "  ✓ .env 已生成"

    log_info "停止旧服务..."
    docker compose down --remove-orphans 2>/dev/null || true

    log_info "拉取镜像并启动服务..."
    echo "  - Web 端口: $LANGFUSE_BIND:$LANGFUSE_PORT_WEB -> 3000"
    echo "  - 外部 URL: $LANGFUSE_EXTERNAL_URL"

    docker compose up -d --wait 2>&1 || {
        log_warn "docker compose --wait 失败, 尝试无 --wait 模式..."
        docker compose up -d 2>&1 || {
            log_error "docker compose up 失败"
            docker compose logs --tail=50 2>/dev/null || true
            return 1
        }
    }

    sleep 10

    local web_container="${LANGFUSE_CONTAINER_PREFIX}-server"
    if ! docker ps -q --filter "name=${LANGFUSE_CONTAINER_PREFIX}-web" 2>/dev/null | grep -q .; then
        if ! docker ps -q --filter "name=$web_container" 2>/dev/null | grep -q .; then
            log_warn "Langfuse Web 容器可能未启动, 检查 docker compose 状态..."
            docker compose ps 2>/dev/null || true
        fi
    fi

    log_info ""
    log_info "Langfuse 部署完成"
    log_info "===================="
    echo -e "  ${CYAN}访问地址:${NC}"
    echo -e "    - 直连: ${YELLOW}http://127.0.0.1:$LANGFUSE_PORT_WEB${NC}"
    echo -e "    - Nginx: ${YELLOW}https://127.0.0.1:$LANGFUSE_NGINX_PORT${NC}"
    echo
    echo -e "  ${CYAN}首次使用:${NC}"
    echo -e "    - 打开页面后注册管理员账号"
    echo -e "    - 设置: NEXT_PUBLIC_SIGN_UP_DISABLED=false 允许注册"
    echo

    return 0
}

deploy_langfuse_standalone() {
    log_banner
    log_step "Langfuse 一键部署/修复"
    deploy_langfuse
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --deploy)
            deploy_langfuse
            ;;
        --standalone)
            source "$PROJECT_DIR/lib/common.sh" 2>/dev/null || true
            deploy_langfuse_standalone
            ;;
        *)
            echo "用法: $0 [--deploy|--standalone]"
            echo "  --deploy      部署 Langfuse"
            echo "  --standalone  独立部署"
            exit 1
            ;;
    esac
fi
