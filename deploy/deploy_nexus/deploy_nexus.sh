#!/bin/bash
# =============================================================================
# DevOpsAgent Sonatype Nexus3 部署脚本
# =============================================================================
# 替代 JFrog Artifactory OSS（官方 Docker 镜像已于 2024 年停止公开分发）
#
# 镜像源回退策略:
#   1. Docker Hub 官方: sonatype/nexus3:latest
#   2. 阿里云杭州:    registry.cn-hangzhou.aliyuncs.com/sonatype/nexus3:latest
#   3. 阿里云上海:    registry.cn-shanghai.aliyuncs.com/sonatype/nexus3:latest
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"

source "$LIB_DIR/common.sh"

NEXUS_PORT_WEB="${NEXUS_PORT_WEB:-8081}"
NEXUS_BIND="${NEXUS_BIND:-127.0.0.1}"
NEXUS_CONTAINER_NAME="${NEXUS_CONTAINER_NAME:-devopsagent-nexus}"
NEXUS_DATA_DIR="${NEXUS_DATA_DIR:-$PROJECT_DIR/data/nexus}"
NEXUS_USE_NAMED_VOLUMES="${NEXUS_USE_NAMED_VOLUMES:-true}"
NEXUS_VOLUME_DATA="${NEXUS_VOLUME_DATA:-nexus-data}"

deploy_nexus() {
    log_step "部署 Sonatype Nexus3 制品仓库"

    # 数据目录准备
    if [[ "$NEXUS_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储：$NEXUS_VOLUME_DATA"
    else
        if [[ ! -d "$NEXUS_DATA_DIR" ]]; then
            log_info "创建 Nexus 数据目录：$NEXUS_DATA_DIR"
            mkdir -p "$NEXUS_DATA_DIR"
        fi
        log_info "修改 Nexus 数据目录权限 (uid=200)..."
        chown -R 200:200 "$NEXUS_DATA_DIR" 2>/dev/null || true
    fi

    # 清理旧容器
    if docker ps -q --filter "name=$NEXUS_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "Nexus 容器已在运行，停止并删除..."
        docker stop "$NEXUS_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$NEXUS_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$NEXUS_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 Nexus 容器..."
        docker rm "$NEXUS_CONTAINER_NAME" 2>/dev/null || true
    fi

    # 镜像源列表（带回退）
    local images=(
        "sonatype/nexus3:latest"
        "registry.cn-hangzhou.aliyuncs.com/sonatype/nexus3:latest"
        "registry.cn-shanghai.aliyuncs.com/sonatype/nexus3:latest"
    )

    local pull_success=false
    local selected_image=""

    for img in "${images[@]}"; do
        log_info "尝试拉取镜像：$img"
        if timeout 300 docker pull "$img"; then
            log_info "✓ 镜像拉取成功：$img"
            selected_image="$img"
            pull_success=true
            break
        fi
        log_warn "镜像 $img 拉取失败，尝试下一个..."
        sleep 1
    done

    if [[ "$pull_success" == false ]]; then
        log_error "所有 Nexus3 镜像源均失败"
        log_error "============================================"
        log_error "请尝试以下解决方案："
        log_error "1. 检查网络连接和代理设置"
        log_error "2. 手动下载镜像后导入："
        log_error "   docker pull sonatype/nexus3:latest"
        log_error "3. 使用其他镜像加速器"
        log_error "============================================"
        return 1
    fi

    # 如果需要，tag 为标准名称
    if [[ "$selected_image" != "sonatype/nexus3:latest" ]]; then
        log_info "Tag 镜像为标准名称: sonatype/nexus3:latest"
        docker tag "$selected_image" "sonatype/nexus3:latest"
    fi

    log_info "创建 Nexus 容器..."
    local volume_mount=""
    local volume_display=""
    if [[ "$NEXUS_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_mount="-v $NEXUS_VOLUME_DATA:/nexus-data"
        volume_display="$NEXUS_VOLUME_DATA (命名卷)"
    else
        volume_mount="-v $NEXUS_DATA_DIR:/nexus-data"
        volume_display="$NEXUS_DATA_DIR (绑定挂载)"
    fi
    echo "  - 存储：$volume_display"

    docker run -d \
        --name "$NEXUS_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$NEXUS_BIND:$NEXUS_PORT_WEB:8081" \
        $volume_mount \
        -e INSTALL4J_ADD_VM_PARAMS="-Xms512m -Xmx2g -XX:MaxDirectMemorySize=1g" \
        "sonatype/nexus3:latest"

    log_info "等待 Nexus 启动 (首次启动约 2-3 分钟)..."
    local max_wait=300
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        if docker logs "$NEXUS_CONTAINER_NAME" 2>/dev/null | grep -q "Started Sonatype Nexus"; then
            log_info "✓ Nexus 启动完成"
            break
        fi
        sleep 5
        wait_count=$((wait_count + 5))
        if [[ $((wait_count % 30)) -eq 0 ]]; then
            log_info "等待中... ($wait_count/$max_wait 秒)"
        fi
    done

    if [[ $wait_count -ge $max_wait ]]; then
        log_warn "Nexus 启动超时，检查容器状态..."
        docker ps | grep "$NEXUS_CONTAINER_NAME" || true
        log_info "查看最近日志..."
        docker logs --tail=30 "$NEXUS_CONTAINER_NAME" 2>/dev/null || true
    fi

    # 获取初始 admin 密码
    log_info "获取 admin 初始密码..."
    sleep 5
    local admin_password=""
    if docker exec "$NEXUS_CONTAINER_NAME" cat /nexus-data/admin.password 2>/dev/null; then
        admin_password=$(docker exec "$NEXUS_CONTAINER_NAME" cat /nexus-data/admin.password 2>/dev/null)
        if [[ -n "$admin_password" ]]; then
            log_info "============================================"
            log_info "  Nexus 初始管理员密码: $admin_password"
            log_info "  ⚠ 请保存此密码，首次登录后需立即修改"
            log_info "============================================"
        fi
    else
        log_warn "admin.password 文件尚未生成，请稍后手动获取："
        log_warn "  docker exec $NEXUS_CONTAINER_NAME cat /nexus-data/admin.password"
    fi

    log_info "✓ Nexus3 部署完成"
    log_info "  默认用户名：admin"
    log_info "  访问地址：http://${NEXUS_BIND}:${NEXUS_PORT_WEB}"
    log_info ""
    log_info "【使用说明】"
    log_info "  1. 浏览器访问上述地址"
    log_info "  2. 使用 admin + 上述密码登录"
    log_info "  3. 按向导修改密码、配置匿名访问"
    log_info "  4. 仓库类型支持: Maven / npm / Docker / PyPI / Raw 等"
    log_info ""
    log_info "【从 Artifactory 迁移】"
    log_info "  如需迁移旧 Artifactory 数据，请参考："
    log_info "  https://help.sonatype.com/docs/nexus-repository"

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_nexus "$@"
fi
