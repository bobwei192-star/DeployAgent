#!/bin/bash
# =============================================================================
# DevOpsAgent JFrog Artifactory 部署脚本
# =============================================================================
# 注意: Artifactory 7.x 已移除对 Derby 嵌入式数据库的支持，强制要求 PostgreSQL
# 本脚本自动检测主机上已安装的 PostgreSQL，配置数据库并部署 Artifactory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"

source "$LIB_DIR/common.sh"

ARTIFACTORY_PORT_WEB="${ARTIFACTORY_PORT_WEB:-8084}"
ARTIFACTORY_BIND="${ARTIFACTORY_BIND:-0.0.0.0}"
ARTIFACTORY_CONTAINER_NAME="${ARTIFACTORY_CONTAINER_NAME:-devopsagent-artifactory}"
ARTIFACTORY_DATA_DIR="${ARTIFACTORY_DATA_DIR:-$PROJECT_DIR/data/artifactory}"
ARTIFACTORY_USE_NAMED_VOLUMES="${ARTIFACTORY_USE_NAMED_VOLUMES:-true}"
ARTIFACTORY_VOLUME_HOME="${ARTIFACTORY_VOLUME_HOME:-artifactory-home}"

# PostgreSQL 配置
ARTIFACTORY_DB_NAME="${ARTIFACTORY_DB_NAME:-artifactory}"
ARTIFACTORY_DB_USER="${ARTIFACTORY_DB_USER:-artifactory}"
ARTIFACTORY_DB_PASSWORD="${ARTIFACTORY_DB_PASSWORD:-artifactory_secret}"

# 配置目录
ARTIFACTORY_CONFIG_DIR="${PROJECT_DIR}/config/artifactory"

# =============================================================================
# PostgreSQL 自动配置函数
# =============================================================================

configure_postgresql() {
    log_step "配置 PostgreSQL 数据库 (Artifactory 专用)"

    # 自动检测 PostgreSQL 版本和端口
    if ! command -v pg_lsclusters &>/dev/null; then
        log_error "pg_lsclusters 命令不存在，请安装 postgresql-client"
        return 1
    fi

    local pg_info
    pg_info=$(pg_lsclusters | grep online | head -1)
    if [[ -z "$pg_info" ]]; then
        log_error "未找到运行中的 PostgreSQL 集群"
        return 1
    fi

    PG_VERSION=$(echo "$pg_info" | awk '{print $1}')
    PG_CLUSTER=$(echo "$pg_info" | awk '{print $2}')
    PG_PORT=$(echo "$pg_info" | awk '{print $3}')
    PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
    PG_HBA_CONF="${PG_CONF_DIR}/pg_hba.conf"
    PG_CONF="${PG_CONF_DIR}/postgresql.conf"

    log_info "检测到 PostgreSQL: 版本=$PG_VERSION, 集群=$PG_CLUSTER, 端口=$PG_PORT"

    # 获取 Docker 网络网关
    DOCKER_GATEWAY=$(docker network inspect devopsagent-network -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.18.0.1")
    DOCKER_SUBNET=$(docker network inspect devopsagent-network -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.18.0.0/16")
    log_info "Docker 网关: $DOCKER_GATEWAY, 子网: $DOCKER_SUBNET"

    # 创建数据库和用户（如不存在）
    if sudo -u postgres psql -p "$PG_PORT" -lqt 2>/dev/null | cut -d\| -f1 | grep -qw "$ARTIFACTORY_DB_NAME"; then
        log_info "✓ 数据库 '$ARTIFACTORY_DB_NAME' 已存在，跳过创建"
    else
        log_info "创建数据库 '$ARTIFACTORY_DB_NAME'..."
        sudo -u postgres psql -p "$PG_PORT" -c "CREATE USER $ARTIFACTORY_DB_USER WITH PASSWORD '$ARTIFACTORY_DB_PASSWORD';" 2>/dev/null || true
        sudo -u postgres psql -p "$PG_PORT" -c "CREATE DATABASE $ARTIFACTORY_DB_NAME OWNER $ARTIFACTORY_DB_USER;" 2>/dev/null || true
        log_info "✓ 数据库和用户创建完成"
    fi

    # 配置 listen_addresses = '*'
    local current_listen
    current_listen=$(grep "^listen_addresses" "$PG_CONF" 2>/dev/null | awk '{print $3}' | tr -d "'")
    if [[ "$current_listen" != "*" ]]; then
        log_info "配置 listen_addresses = '*' ..."
        sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
        log_info "✓ listen_addresses 已更新"
    else
        log_info "✓ listen_addresses = '*' 已配置"
    fi

    # 配置 pg_hba.conf 允许 Docker 容器连接
    local subnet_prefix
    subnet_prefix=$(echo "$DOCKER_SUBNET" | cut -d. -f1-2)
    if grep -q "${subnet_prefix}" "$PG_HBA_CONF" 2>/dev/null; then
        log_info "✓ pg_hba.conf 已包含 Docker 网络条目"
    else
        log_info "配置 pg_hba.conf 允许 Docker 容器连接..."
        echo "" >> "$PG_HBA_CONF"
        echo "# Allow Docker containers (devopsagent-network) to connect" >> "$PG_HBA_CONF"
        echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    ${DOCKER_SUBNET}    md5" >> "$PG_HBA_CONF"
        log_info "✓ pg_hba.conf 已添加 Docker 网络条目"
    fi

    # ─── WSL2 网络适配: 自动检测 WSL2 特殊网关 IP ───
    # WSL2 环境下, Docker 容器的连接源 IP 不经过 Docker 桥接,
    # 而是走 WSL2 虚拟交换机 (Hyper-V), PostgreSQL 看到的来源 IP 可能是:
    #   10.255.255.254  (WSL2 本地回环特殊地址)
    #   172.21.x.x      (WSL2 eth0 子网)
    log_info "检测 WSL/Docker 实际源地址..."

    # 检测 WSL2 特殊回环 IP
    if ip -4 addr show lo 2>/dev/null | grep -q "10.255.255.254"; then
        if ! grep -q "10.255.255.254" "$PG_HBA_CONF" 2>/dev/null; then
            echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    10.255.255.254/32    md5" >> "$PG_HBA_CONF"
            log_info "  ✓ 已添加 WSL2 特殊 IP: 10.255.255.254/32"
        else
            log_info "  ✓ WSL2 特殊 IP 已存在"
        fi
    fi

    # 检测 WSL2 eth0 子网 (VM 主网络接口)
    local eth0_cidr
    eth0_cidr=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+/\d+')
    if [[ -n "$eth0_cidr" ]]; then
        eth0_ip=$(echo "$eth0_cidr" | cut -d/ -f1)
        eth0_net=$(echo "$eth0_ip" | cut -d. -f1-3)
        eth0_entry="${eth0_net}.0/24"
        if ! grep -q "${eth0_net}" "$PG_HBA_CONF" 2>/dev/null; then
            echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    ${eth0_entry}    md5" >> "$PG_HBA_CONF"
            log_info "  ✓ 已添加 WSL2 eth0 子网: ${eth0_entry}"
        else
            log_info "  ✓ WSL2 eth0 子网已存在"
        fi

        # 同时添加默认网关 (Windows 宿主机 IP)
        default_gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [[ -n "$default_gw" ]] && ! grep -q "${default_gw}" "$PG_HBA_CONF" 2>/dev/null; then
            echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    ${default_gw}/32    md5" >> "$PG_HBA_CONF"
            log_info "  ✓ 已添加默认网关: ${default_gw}/32"
        fi
    fi

    # 重启 PostgreSQL 使配置生效
    log_info "重启 PostgreSQL 使配置生效..."
    sudo systemctl restart postgresql
    sleep 2

    # 验证监听状态
    if ss -tlnp | grep -q ":${PG_PORT}"; then
        local listen_addr
        listen_addr=$(ss -tlnp | grep ":${PG_PORT}" | head -1 | awk '{print $4}')
        log_info "✓ PostgreSQL 正在监听: $listen_addr"
    else
        log_error "PostgreSQL 未在端口 $PG_PORT 上监听!"
        return 1
    fi

    # 验证 Docker 网关连接
    if PGPASSWORD="$ARTIFACTORY_DB_PASSWORD" psql -h "$DOCKER_GATEWAY" -p "$PG_PORT" -U "$ARTIFACTORY_DB_USER" -d "$ARTIFACTORY_DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
        log_info "✓ Docker 网关连接验证成功 ($DOCKER_GATEWAY:$PG_PORT)"
    else
        # WSL2 下 psql -h $DOCKER_GATEWAY 的连接源可能不是 Docker 子网 IP,
        # 尝试重载配置后以 WSL2 实际 IP 重新验证
        log_warn "Docker 网关连接失败，尝试重载 pg_hba.conf..."
        sudo -u postgres psql -p "$PG_PORT" -c "SELECT pg_reload_conf();" 2>/dev/null || true
        sleep 2
        if PGPASSWORD="$ARTIFACTORY_DB_PASSWORD" psql -h "$DOCKER_GATEWAY" -p "$PG_PORT" -U "$ARTIFACTORY_DB_USER" -d "$ARTIFACTORY_DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
            log_info "✓ 重载后连接验证成功"
        else
            log_error "Docker 网关连接仍然失败!"
            log_error "  预期来源 IP: 10.255.255.254 (WSL2) 或 ${DOCKER_GATEWAY} (Docker)"
            log_error "  请手动执行以下命令排查:"
            log_error "    sudo -u postgres psql -p $PG_PORT -c \"SELECT * FROM pg_hba_file_rules WHERE database='${ARTIFACTORY_DB_NAME}';\""
            log_error "    tail -20 /var/log/postgresql/postgresql-${PG_VERSION}-main.log  | grep 'no pg_hba'"
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# 生成 system.yaml
# =============================================================================

generate_system_yaml() {
    mkdir -p "$ARTIFACTORY_CONFIG_DIR"
    cat > "$ARTIFACTORY_CONFIG_DIR/system.yaml" << EOF
## Artifactory system.yaml - Auto-generated by DevOpsAgent
## Artifactory 7.x 强制要求 PostgreSQL, 不再支持 Derby
## PostgreSQL ${PG_VERSION} cluster on port ${PG_PORT}

shared:
  database:
    type: postgresql
    driver: org.postgresql.Driver
    url: jdbc:postgresql://${DOCKER_GATEWAY}:${PG_PORT}/${ARTIFACTORY_DB_NAME}
    username: ${ARTIFACTORY_DB_USER}
    password: ${ARTIFACTORY_DB_PASSWORD}

jfconnect:
  enabled: false
EOF
    chmod 600 "$ARTIFACTORY_CONFIG_DIR/system.yaml"
    log_info "✓ system.yaml 已生成 (PostgreSQL 端口: $PG_PORT)"
}

# =============================================================================
# 主部署函数
# =============================================================================

deploy_artifactory() {
    log_step "部署 JFrog Artifactory 服务 (PostgreSQL 裸机模式)"

    # ─── 步骤 1: 检查/安装 PostgreSQL ───
    log_step "检查/安装 PostgreSQL (裸机模式)"
    if command -v psql &>/dev/null; then
        local pg_ver
        pg_ver=$(psql --version | head -1 | awk '{print $3}')
        log_info "✓ PostgreSQL 已安装 (版本: $pg_ver)"
    else
        log_info "安装 PostgreSQL..."
        sudo apt-get update -qq && sudo apt-get install -y -qq postgresql postgresql-client >/dev/null
        log_info "✓ PostgreSQL 安装完成"
    fi

    # 检查 PostgreSQL 服务状态
    if ! sudo systemctl is-active --quiet postgresql; then
        log_info "启动 PostgreSQL 服务..."
        sudo systemctl start postgresql
    fi
    log_info "✓ PostgreSQL 服务正在运行"

    # ─── 步骤 2: 配置 PostgreSQL ───
    if ! configure_postgresql; then
        log_error "PostgreSQL 配置失败，Artifactory 无法启动"
        return 1
    fi

    # ─── 步骤 3: 生成 system.yaml ───
    generate_system_yaml
    log_info "配置目录: $ARTIFACTORY_CONFIG_DIR"

    # ─── 步骤 4: 清理旧容器 ───
    if docker ps -q --filter "name=$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "Artifactory 容器已在运行，停止并删除..."
        docker stop "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 Artifactory 容器..."
        docker rm "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null || true
    fi

    # ─── 步骤 5: 拉取 Artifactory 镜像 ───
    log_step "拉取 Artifactory 镜像"
    local IMAGE_NAME="releases-docker.jfrog.io/jfrog/artifactory-oss"
    local TAG="latest"
    local FULL_IMAGE="${IMAGE_NAME}:${TAG}"

    # 检查本地是否已有镜像
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${FULL_IMAGE}$"; then
        log_info "✓ 本地已存在镜像: ${FULL_IMAGE}"
        selected_image="$FULL_IMAGE"
    else
        log_info "清理旧的镜像缓存..."
        docker rmi "jfrog/artifactory-oss" 2>/dev/null || true

        # JFrog 官方镜像源（优先使用）
        local official_images=(
            "releases-docker.jfrog.io/jfrog/artifactory-oss:latest"
            "docker.jfrog.io/jfrog/artifactory-oss:latest"
            "jfrog/artifactory-oss:latest"
        )

        # 第三方搬运镜像（按可信度排序）- 备用方案
        local third_party_images=(
            "jijidom/artifactory-oss:latest"      # 标注来源 releases-docker.jfrog.io
            "jaysong/artifactory-oss:latest"      # 社区维护
            "goodrainapps/artifactory-oss:latest" # 企业应用商店
            "yunlzheng/artifactory-oss:latest"   # Rancher catalog
        )

        local pull_success=false
        local step=1
        local total_steps=$(( ${#official_images[@]} + ${#third_party_images[@]} ))

        # 第1步: 尝试官方镜像源
        log_info "============================================"
        log_info "第1步: 尝试 JFrog 官方镜像源"
        log_info "============================================"

        for img in "${official_images[@]}"; do
            log_info "[${step}/${total_steps}] 尝试: ${img}"
            if timeout 120 docker pull "$img"; then
                log_info "✓ 镜像拉取成功：$img"
                selected_image="$img"
                pull_success=true
                break
            fi
            log_warn "镜像 $img 拉取失败，尝试下一个..."
            ((step++))
            sleep 1
        done

        # 第2步: 尝试第三方搬运镜像
        if [[ "$pull_success" == false ]]; then
            log_info "============================================"
            log_info "第2步: 尝试第三方搬运镜像"
            log_info "============================================"

            for img in "${third_party_images[@]}"; do
                log_info "[${step}/${total_steps}] 尝试: ${img}"
                if timeout 60 docker pull "$img"; then
                    log_info "✓ 拉取成功: ${img}"
                    log_info "重命名: ${img} -> ${FULL_IMAGE}"
                    docker tag "$img" "$FULL_IMAGE"
                    selected_image="$FULL_IMAGE"
                    pull_success=true
                    break
                fi
                log_warn "拉取失败，尝试下一个..."
                ((step++))
            done
        fi

        if [[ "$pull_success" == false ]]; then
            log_error "所有 Artifactory 镜像源均失败"
            log_error "============================================"
            log_error "【问题总结】"
            log_error "1. JFrog 官方已从 Docker Hub 移除 artifactory-oss 镜像"
            log_error "2. 原官方仓库返回: pull access denied"
            log_error "3. 第三方搬运镜像可能也已失效"
            log_error ""
            log_error "【建议方案】"
            log_error "1. 检查网络连接和代理设置"
            log_error "2. 配置 Docker 镜像加速器"
            log_error "3. 手动下载镜像后导入"
            log_error "4. 迁移到 Nexus3: docker pull sonatype/nexus3:latest"
            log_error "5. 使用 JFrog 官方安装包（非 Docker）"
            log_error "   参考: https://jfrog.com/help/r/jfrog-installation-setup-documentation"
            log_error "============================================"
            return 1
        fi
    fi

    # ─── 步骤 6: 创建 Artifactory 容器 ───
    log_step "创建 Artifactory 容器"
    local volume_mount=""
    local volume_display=""
    if [[ "$ARTIFACTORY_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_mount="-v $ARTIFACTORY_VOLUME_HOME:/var/opt/jfrog/artifactory"
        volume_display="$ARTIFACTORY_VOLUME_HOME (命名卷)"
    else
        volume_mount="-v $ARTIFACTORY_DATA_DIR:/var/opt/jfrog/artifactory"
        volume_display="$ARTIFACTORY_DATA_DIR (绑定挂载)"
    fi
    log_info "  - 存储：$volume_display"
    log_info "  - system.yaml: $ARTIFACTORY_CONFIG_DIR/system.yaml → /opt/jfrog/artifactory/var/etc/system.yaml"
    log_info "  - 数据库: PostgreSQL $PG_VERSION @ $DOCKER_GATEWAY:$PG_PORT"

    docker run -d \
        --name "$ARTIFACTORY_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        --ulimit nofile=65535:65535 \
        --ulimit nproc=4096:4096 \
        -p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8082" \
        $volume_mount \
        -v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml" \
        -e EXTRA_JAVA_OPTIONS="-Xms512m -Xmx2g" \
        -e JF_JFCONNECT_ENABLED=false \
        --user root \
        "$selected_image"

    # ─── 步骤 7: 等待 Artifactory 启动 ───
    log_step "等待 Artifactory 启动"
    local max_wait=180
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        if docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>&1 | grep -q "Server startup complete"; then
            log_info "✓ Artifactory 启动完成"
            break
        fi
        # 检测数据库连接失败
        if docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>&1 | tail -20 | grep -q "DbTypeNotAllowedException"; then
            log_error "Artifactory 数据库类型不允许 (Derby), 请检查 system.yaml 是否正确挂载"
            docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>&1 | tail -30
            return 1
        fi
        if docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>&1 | tail -20 | grep -q "Connection refused.*5432\|Connection refused.*5433\|Connection refused.*5434"; then
            log_error "Artifactory 无法连接 PostgreSQL，请检查:"
            log_error "  1. PostgreSQL 是否正在运行 (systemctl status postgresql)"
            log_error "  2. PostgreSQL 监听地址 (ss -tlnp | grep postgres)"
            log_error "  3. pg_hba.conf 是否允许 Docker 网络连接"
            log_error "  4. system.yaml 中的端口号是否正确"
            docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>&1 | tail -30
            return 1
        fi
        sleep 5
        wait_count=$((wait_count + 5))
        if [[ $((wait_count % 30)) -eq 0 ]]; then
            log_info "等待中... ($wait_count/$max_wait 秒)"
        fi
    done

    if [[ $wait_count -ge $max_wait ]]; then
        log_warn "Artifactory 启动超时，检查容器状态..."
        docker ps | grep "$ARTIFACTORY_CONTAINER_NAME"
        log_info "最后 30 行日志:"
        docker logs --tail 30 "$ARTIFACTORY_CONTAINER_NAME" 2>&1
        return 1
    fi

    log_info "✓ Artifactory 部署完成"
    log_info "  默认用户名：admin"
    log_info "  默认密码：password"
    log_info "  访问地址：http://${ARTIFACTORY_BIND}:${ARTIFACTORY_PORT_WEB}"
    log_info "  数据库：PostgreSQL $PG_VERSION @ $DOCKER_GATEWAY:$PG_PORT"

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_artifactory "$@"
fi