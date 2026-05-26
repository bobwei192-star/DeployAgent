#!/bin/bash
# =============================================================================
# DevOpsAgent JFrog Artifactory 部署脚本
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"

source "$LIB_DIR/common.sh"

ARTIFACTORY_PORT_WEB="${ARTIFACTORY_PORT_WEB:-8081}"
ARTIFACTORY_BIND="${ARTIFACTORY_BIND:-127.0.0.1}"
ARTIFACTORY_CONTAINER_NAME="${ARTIFACTORY_CONTAINER_NAME:-devopsagent-artifactory}"
ARTIFACTORY_DATA_DIR="${ARTIFACTORY_DATA_DIR:-$PROJECT_DIR/data/artifactory}"
ARTIFACTORY_USE_NAMED_VOLUMES="${ARTIFACTORY_USE_NAMED_VOLUMES:-true}"
ARTIFACTORY_VOLUME_HOME="${ARTIFACTORY_VOLUME_HOME:-artifactory-home}"

deploy_artifactory() {
    log_step "部署 JFrog Artifactory 服务"

    if [[ "$ARTIFACTORY_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储：$ARTIFACTORY_VOLUME_HOME"
    else
        if [[ ! -d "$ARTIFACTORY_DATA_DIR" ]]; then
            log_info "创建 Artifactory 数据目录：$ARTIFACTORY_DATA_DIR"
            mkdir -p "$ARTIFACTORY_DATA_DIR"
        fi
        log_info "修改 Artifactory 数据目录权限..."
        chown -R 1030:1030 "$ARTIFACTORY_DATA_DIR" 2>/dev/null || true
    fi

    if docker ps -q --filter "name=$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "Artifactory 容器已在运行，停止并删除..."
        docker stop "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 Artifactory 容器..."
        docker rm "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null || true
    fi

    log_info "清理旧的镜像缓存..."
    docker rmi "jfrog/artifactory-oss" 2>/dev/null || true

    local images=(
        "registry.cn-hangzhou.aliyuncs.com/jfrog/artifactory-oss:7.67.3"
        "registry.cn-shanghai.aliyuncs.com/jfrog/artifactory-oss:7.67.3"
        "hub-mirror.c.163.com/jfrog/artifactory-oss:7.67.3"
        "mirror.ccs.tencentyun.com/jfrog/artifactory-oss:7.67.3"
        "jfrog/artifactory-oss:7.67.3"
        "docker.jfrog.io/jfrog/artifactory-oss:7.67.3"
        "releases-docker.jfrog.io/jfrog/artifactory-oss:7.67.3"
        "jfrog/artifactory-oss:latest"
        "registry.cn-hangzhou.aliyuncs.com/jfrog/artifactory-oss:latest"
        "hub-mirror.c.163.com/jfrog/artifactory-oss:latest"
    )

    local pull_success=false
    local selected_image=""

    for img in "${images[@]}"; do
        log_info "尝试拉取镜像：$img"
        if timeout 60 docker pull "$img"; then
            log_info "✓ 镜像拉取成功：$img"
            selected_image="$img"
            pull_success=true
            break
        fi
        log_warn "镜像 $img 拉取失败，尝试下一个..."
        sleep 1
    done

    if [[ "$pull_success" == false ]]; then
        log_error "所有 Artifactory 镜像源均失败"
        log_error "============================================"
        log_error "网络环境无法访问外部镜像源"
        log_error "请尝试以下解决方案："
        log_error "1. 检查网络连接和代理设置"
        log_error "2. 配置 Docker 镜像加速器"
        log_error "3. 手动下载镜像后导入："
        log_error "   docker pull jfrog/artifactory-oss:7.67.3"
        log_error "4. 跳过 Artifactory 部署，选择其他服务"
        log_error "============================================"
        return 1
    fi

    log_info "创建 Artifactory 容器..."
    local volume_mount=""
    local volume_display=""
    if [[ "$ARTIFACTORY_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_mount="-v $ARTIFACTORY_VOLUME_HOME:/var/opt/jfrog/artifactory"
        volume_display="$ARTIFACTORY_VOLUME_HOME (命名卷)"
    else
        volume_mount="-v $ARTIFACTORY_DATA_DIR:/var/opt/jfrog/artifactory"
        volume_display="$ARTIFACTORY_DATA_DIR (绑定挂载)"
    fi
    echo "  - 存储：$volume_display"

    docker run -d \
        --name "$ARTIFACTORY_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8081" \
        $volume_mount \
        -e EXTRA_JAVA_OPTIONS="-Xms512m -Xmx2g" \
        "$selected_image"

    log_info "等待 Artifactory 启动..."
    local max_wait=120
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        if docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null | grep -q "Server startup complete"; then
            log_info "✓ Artifactory 启动完成"
            break
        fi
        if docker logs "$ARTIFACTORY_CONTAINER_NAME" 2>/dev/null | grep -q "ERROR"; then
            log_error "Artifactory 启动失败"
            docker logs "$ARTIFACTORY_CONTAINER_NAME"
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
    fi

    log_info "✓ Artifactory 部署完成"
    log_info "  默认用户名：admin"
    log_info "  默认密码：password"
    log_info "  访问地址：http://${ARTIFACTORY_BIND}:${ARTIFACTORY_PORT_WEB}"

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_artifactory "$@"
fi
