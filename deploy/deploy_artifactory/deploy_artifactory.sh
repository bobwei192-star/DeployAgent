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

    IMAGE_NAME="jfrog/artifactory-oss"
    TAG="7.67.3"
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"

    # 检查本地是否已有镜像
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${FULL_IMAGE}$"; then
        log_info "✓ 本地已存在镜像: ${FULL_IMAGE}"
        selected_image="$FULL_IMAGE"
    else
        log_info "清理旧的镜像缓存..."
        docker rmi "jfrog/artifactory-oss" 2>/dev/null || true

        # 第三方搬运镜像（按可信度排序）- JFrog 官方已从 Docker Hub 移除 artifactory-oss
        local third_party_images=(
            "jijidom/artifactory-oss:latest"      # 标注来源 releases-docker.jfrog.io
            "jaysong/artifactory-oss:latest"      # 社区维护
            "goodrainapps/artifactory-oss:latest" # 企业应用商店
            "yunlzheng/artifactory-oss:latest"   # Rancher catalog
        )

        # 官方镜像源（已失效，仅作记录）
        local official_images=(
            "registry.cn-hangzhou.aliyuncs.com/jfrog/artifactory-oss:7.67.3"
            "registry.cn-shanghai.aliyuncs.com/jfrog/artifactory-oss:7.67.3"
            "hub-mirror.c.163.com/jfrog/artifactory-oss:7.67.3"
            "mirror.ccs.tencentyun.com/jfrog/artifactory-oss:7.67.3"
            "jfrog/artifactory-oss:7.67.3"
            "docker.jfrog.io/jfrog/artifactory-oss:7.67.3"
            "releases-docker.jfrog.io/jfrog/artifactory-oss:7.67.3"
            "jfrog/artifactory-oss:latest"
        )

        local pull_success=false
        local step=1
        local total_steps=$(( ${#third_party_images[@]} + ${#official_images[@]} ))

        # 第1步: 尝试第三方搬运镜像
        log_info "============================================"
        log_info "第1步: 尝试第三方搬运镜像"
        log_info "============================================"
        log_info "原因: JFrog 官方已从 Docker Hub 移除 artifactory-oss 镜像"

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

        # 第2步: 尝试官方镜像源
        if [[ "$pull_success" == false ]]; then
            log_info "============================================"
            log_info "第2步: 尝试官方镜像源"
            log_info "============================================"

            for img in "${official_images[@]}"; do
                log_info "[${step}/${total_steps}] 尝试: ${img}"
                if timeout 60 docker pull "$img"; then
                    log_info "✓ 镜像拉取成功：$img"
                    selected_image="$img"
                    pull_success=true
                    break
                fi
                log_warn "镜像 $img 拉取失败，尝试下一个..."
                ((step++))
                sleep 1
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
