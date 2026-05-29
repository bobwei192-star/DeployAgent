#!/bin/bash
# =============================================================================
# DevOpsAgent MantisBT 部署脚本
# =============================================================================
# 功能：
#   - 部署 MantisBT Bug 追踪系统 + MariaDB 数据库
#   - 自动初始化数据库
#   - 获取初始管理员密码
#
# 使用方法：
#   - 独立运行: sudo ./deploy_MantisBT/deploy_mantisbt.sh
#   - 被主脚本调用: source deploy_MantisBT/deploy_mantisbt.sh
#
# 端口配置:
#   - MantisBT Web: 19093
#   - MariaDB: 3307
#   - Nginx MantisBT: 18443
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
DOCKER_COMPOSE_CMD=""

source "$LIB_DIR/common.sh"

MANTISBT_PORT_WEB="${MANTISBT_PORT_WEB:-19093}"
MANTISBT_BIND="${MANTISBT_BIND:-127.0.0.1}"
MANTISBT_IMAGE="${MANTISBT_IMAGE:-rainflood/mantisbt:latest}"
MANTISBT_CONTAINER_NAME="${MANTISBT_CONTAINER_NAME:-devopsagent-mantisbt}"
MANTISBT_DATA_DIR="${MANTISBT_DATA_DIR:-$PROJECT_DIR/data/mantisbt}"

MARIADB_PORT="${MARIADB_PORT:-3307}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:10.11}"
MARIADB_CONTAINER_NAME="${MARIADB_CONTAINER_NAME:-devopsagent-mantisbt-db}"
MARIADB_DATA_DIR="${MARIADB_DATA_DIR:-$PROJECT_DIR/data/mantisbt-db}"

MANTISBT_DB_NAME="${MANTISBT_DB_NAME:-mantisbt}"
MANTISBT_DB_USER="${MANTISBT_DB_USER:-mantisbt}"

# 自动生成强随机密码（可通过环境变量覆盖）
_AUTO_DB_PASS=$(openssl rand -hex 16 2>/dev/null || echo "$(date +%s)$RANDOM$(hostname)")
MANTISBT_DB_PASSWORD="${MANTISBT_DB_PASSWORD:-$_AUTO_DB_PASS}"
_AUTO_ADMIN_PASS=$(openssl rand -hex 12 2>/dev/null || echo "$(date +%s)$RANDOM")
MANTISBT_ADMIN_USER="${MANTISBT_ADMIN_USER:-administrator}"
MANTISBT_ADMIN_PASSWORD="${MANTISBT_ADMIN_PASSWORD:-$_AUTO_ADMIN_PASS}"
MANTISBT_USE_NAMED_VOLUMES="${MANTISBT_USE_NAMED_VOLUMES:-true}"

MANTISBT_USE_HTTPS_PROXY="${MANTISBT_USE_HTTPS_PROXY:-false}"
MANTISBT_NGINX_PORT="${MANTISBT_NGINX_PORT:-18443}"
MANTISBT_HOSTNAME="${MANTISBT_HOSTNAME:-127.0.0.1}"

if [[ "$MANTISBT_USE_HTTPS_PROXY" == "true" ]]; then
    MANTISBT_EXTERNAL_URL="${MANTISBT_EXTERNAL_URL:-https://$MANTISBT_HOSTNAME:$MANTISBT_NGINX_PORT}"
else
    MANTISBT_EXTERNAL_URL="${MANTISBT_EXTERNAL_URL:-http://$MANTISBT_HOSTNAME:$MANTISBT_PORT_WEB}"
fi

MANTISBT_VOLUME_WEB="${MANTISBT_VOLUME_WEB:-mantisbt-web}"
MARIADB_VOLUME_DATA="${MARIADB_VOLUME_DATA:-mantisbt-db-data}"

deploy_mantisbt_db() {
    log_step "部署 MantisBT MariaDB 数据库"

    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储 (推荐用于 WSL/Windows)"
    else
        if [[ ! -d "$MARIADB_DATA_DIR" ]]; then
            log_info "创建 MariaDB 数据目录: $MARIADB_DATA_DIR"
            mkdir -p "$MARIADB_DATA_DIR"
        fi
    fi

    if docker ps -q --filter "name=$MARIADB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "MantisBT DB 容器已在运行，停止并删除..."
        docker stop "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$MARIADB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 MantisBT DB 容器..."
        docker rm "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
    fi

    log_info "创建 MariaDB 容器..."
    echo "  - 端口: $MANTISBT_BIND:$MARIADB_PORT -> 3306"
    echo "  - 数据库: $MANTISBT_DB_NAME"
    echo "  - 用户: $MANTISBT_DB_USER"

    local volume_args=""
    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_args="-v $MARIADB_VOLUME_DATA:/var/lib/mysql"
    else
        volume_args="-v $MARIADB_DATA_DIR:/var/lib/mysql"
    fi

    docker run -d \
        --name "$MARIADB_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$MANTISBT_BIND:$MARIADB_PORT:3306" \
        $volume_args \
        -e MYSQL_ROOT_PASSWORD="$MANTISBT_DB_PASSWORD" \
        -e MYSQL_DATABASE="$MANTISBT_DB_NAME" \
        -e MYSQL_USER="$MANTISBT_DB_USER" \
        -e MYSQL_PASSWORD="$MANTISBT_DB_PASSWORD" \
        -e TZ=Asia/Shanghai \
        "$MARIADB_IMAGE" 2>&1 || {
        log_error "MariaDB 容器创建失败"
        log_error "请检查: 端口 $MARIADB_PORT 是否可用, 镜像 $MARIADB_IMAGE 是否可拉取"
        docker logs "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
        return 1
    }

    sleep 5

    if docker ps -q --filter "name=$MARIADB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ MariaDB 容器已启动"

        log_info "等待 MariaDB 就绪..."
        local max_attempts=30
        local attempt=0
        while [[ $attempt -lt $max_attempts ]]; do
            if docker exec "$MARIADB_CONTAINER_NAME" mysqladmin ping -h localhost -u root -p"$MANTISBT_DB_PASSWORD" --silent 2>/dev/null; then
                log_info "✓ MariaDB 已就绪"
                return 0
            fi
            attempt=$((attempt + 1))
            sleep 2
        done
        log_warn "MariaDB 可能未完全就绪，继续部署..."
        return 0
    else
        log_error "MariaDB 容器启动失败"
        return 1
    fi
}

deploy_mantisbt() {
    log_step "部署 MantisBT Bug 追踪系统"

    deploy_mantisbt_db

    if [[ -z "$MANTISBT_DB_PASSWORD" ]]; then
        log_warn "MANTISBT_DB_PASSWORD 未设置，使用默认密码: mantisbt_secret"
    fi

    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储"
    else
        if [[ ! -d "$MANTISBT_DATA_DIR" ]]; then
            log_info "创建 MantisBT 数据目录: $MANTISBT_DATA_DIR"
            mkdir -p "$MANTISBT_DATA_DIR"
        fi
    fi

    if docker ps -q --filter "name=$MANTISBT_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "MantisBT 容器已在运行，停止并删除..."
        docker stop "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$MANTISBT_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 MantisBT 容器..."
        docker rm "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
    fi

    log_info "创建 MantisBT 容器..."
    echo "  - 端口: $MANTISBT_BIND:$MANTISBT_PORT_WEB -> 80"
    echo "  - 数据库主机: $MARIADB_CONTAINER_NAME"
    echo "  - 数据库端口: 3306"
    echo "  - 数据库名: $MANTISBT_DB_NAME"

    local volume_args=""
    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_args="-v $MANTISBT_VOLUME_WEB:/var/www/html"
    else
        volume_args="-v $MANTISBT_DATA_DIR:/var/www/html"
    fi

    docker run -d \
        --name "$MANTISBT_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$MANTISBT_BIND:$MANTISBT_PORT_WEB:80" \
        $volume_args \
        -e MANTISBT_DB_HOST="$MARIADB_CONTAINER_NAME" \
        -e MANTISBT_DB_PORT=3306 \
        -e MANTISBT_DB_NAME="$MANTISBT_DB_NAME" \
        -e MANTISBT_DB_USER="$MANTISBT_DB_USER" \
        -e MANTISBT_DB_PASSWORD="$MANTISBT_DB_PASSWORD" \
        -e MANTISBT_ADMIN_USER="$MANTISBT_ADMIN_USER" \
        -e MANTISBT_ADMIN_PASSWORD="$MANTISBT_ADMIN_PASSWORD" \
        -e TZ=Asia/Shanghai \
        "$MANTISBT_IMAGE" 2>&1 || {
        log_error "MantisBT 容器创建失败"
        log_error "请检查: 端口 $MANTISBT_PORT_WEB 是否可用, 镜像 $MANTISBT_IMAGE 是否可拉取"
        docker logs "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
        return 1
    }

    sleep 10

    if docker ps -q --filter "name=$MANTISBT_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ MantisBT 容器已启动"
    else
        log_error "MantisBT 容器启动失败"
        log_warn "检查日志: docker logs $MANTISBT_CONTAINER_NAME"
        return 1
    fi

    log_info "创建 config_inc.php（自动配置数据库连接）..."
    local crypto_salt=$(openssl rand -hex 32 2>/dev/null || echo "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2")
    docker exec "$MANTISBT_CONTAINER_NAME" bash -c "cat > /var/www/html/config/config_inc.php << 'CONFIGEOF'
<?php
\$g_hostname      = '$MARIADB_CONTAINER_NAME';
\$g_db_username   = '$MANTISBT_DB_USER';
\$g_db_password   = '$MANTISBT_DB_PASSWORD';
\$g_database_name = '$MANTISBT_DB_NAME';
\$g_db_type       = 'mysqli';
\$g_db_table_prefix = 'mantis';
\$g_db_table_suffix = '';
\$g_db_table_plugin_prefix = 'plugin';
\$g_crypto_master_salt = '$crypto_salt';
\$g_default_timezone = 'Asia/Shanghai';
\$g_allow_signup = ON;
\$g_webmaster_email = 'admin@devopsagent.local';
\$g_from_email = 'noreply@devopsagent.local';
\$g_return_path_email = 'admin@devopsagent.local';
CONFIGEOF
chown www-data:www-data /var/www/html/config/config_inc.php
chmod 644 /var/www/html/config/config_inc.php"

    log_info "安装 MantisBT 数据库表..."
    local schema_paths=(
        "/var/www/html/admin/sql/mantisbt.mysqli.sql"
        "/var/www/html/admin/sql/mantisbt.mysql.sql"
        "/var/www/html/admin/sql/mantisbt.mssql.sql"
        "/var/www/html/sql/mantisbt.sql"
        "/var/www/html/sql/mantis.sql"
    )
    local schema_file=""
    for sp in "${schema_paths[@]}"; do
        if docker exec "$MANTISBT_CONTAINER_NAME" test -f "$sp" 2>/dev/null; then
            schema_file="$sp"
            break
        fi
    done

    local has_schema_php=false
    if docker exec "$MANTISBT_CONTAINER_NAME" test -f "/var/www/html/admin/schema.php" 2>/dev/null; then
        has_schema_php=true
    fi

    for sp in "${schema_paths[@]}"; do
        log_info "    SQL检查: $sp → $(docker exec "$MANTISBT_CONTAINER_NAME" test -f "$sp" 2>/dev/null && echo '存在' || echo '不存在')"
    done
    log_info "    PHP检查: /var/www/html/admin/schema.php → $($has_schema_php && echo '存在' || echo '不存在')"

    local installed=false

    if [[ -n "$schema_file" ]]; then
        log_info "  发现 SQL schema 文件: $schema_file"
        local import_output
        if import_output=$(docker exec "$MANTISBT_CONTAINER_NAME" cat "$schema_file" | docker exec -i "$MARIADB_CONTAINER_NAME" mysql -u "$MANTISBT_DB_USER" -p"$MANTISBT_DB_PASSWORD" "$MANTISBT_DB_NAME" 2>&1); then
            log_info "  ✓ SQL schema 已导入"
            installed=true
        else
            log_error "  SQL schema 导入失败"
            log_error "  $import_output"
        fi
    fi

    if [[ "$installed" != "true" ]] && [[ "$has_schema_php" == "true" ]]; then
        log_info "  尝试 PHP CLI 方式安装数据库表..."
        local php_result
        php_result=$(docker exec "$MANTISBT_CONTAINER_NAME" php -r "
            \$_SERVER['SCRIPT_NAME'] = '/admin/schema.php';
            \$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
            define('PLUGINS_DISABLED', true);

            \$g_hostname      = '$MARIADB_CONTAINER_NAME';
            \$g_db_username   = '$MANTISBT_DB_USER';
            \$g_db_password   = '$MANTISBT_DB_PASSWORD';
            \$g_database_name = '$MANTISBT_DB_NAME';
            \$g_db_type       = 'mysqli';

            ob_start();
            try {
                include '/var/www/html/admin/schema.php';
            } catch (Throwable \$e) {
                echo 'PHP_EXCEPTION: ' . \$e->getMessage();
            }
            \$output = ob_get_clean();
            echo \$output;
        " 2>&1) || true
        log_info "  PHP schema 输出: ${php_result:0:600}"
    fi

    sleep 3

    local table_count=$(docker exec "$MARIADB_CONTAINER_NAME" mysql -u "$MANTISBT_DB_USER" -p"$MANTISBT_DB_PASSWORD" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MANTISBT_DB_NAME'" 2>/dev/null | tail -1)
    if [[ "$table_count" -gt 0 ]] 2>/dev/null; then
        log_info "✓ 数据库表安装完成 ($table_count 张表)"
    else
        log_warn "  数据库表未安装，尝试 Web 安装器..."
        local web_ready=0
        for i in $(seq 1 15); do
            if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$MANTISBT_PORT_WEB/admin/install.php" 2>/dev/null | grep -q "200"; then
                web_ready=1
                break
            fi
            sleep 2
        done

        if [[ "$web_ready" -eq 1 ]]; then
            log_info "  执行 Web 安装器..."
            local resp_file=$(mktemp)
            curl -s -o "$resp_file" -w "\n%{http_code}" -X POST \
                -d "install=2" \
                -d "hostname=$MARIADB_CONTAINER_NAME" \
                -d "db_username=$MANTISBT_DB_USER" \
                -d "db_password=$MANTISBT_DB_PASSWORD" \
                -d "database_name=$MANTISBT_DB_NAME" \
                -d "db_type=mysqli" \
                -d "db_table_prefix=mantis" \
                -d "db_table_suffix=" \
                -d "db_table_plugin_prefix=plugin" \
                -d "admin_username=$MANTISBT_ADMIN_USER" \
                -d "admin_password=$MANTISBT_ADMIN_PASSWORD" \
                -d "timezone=Asia/Shanghai" \
                -d "go=Install/Upgrade+Database" \
                "http://127.0.0.1:$MANTISBT_PORT_WEB/admin/install.php" 2>&1 || echo "curl_failed"
            local fail_count=$(grep -cE 'BAD|fail|error|Error' "$resp_file" 2>/dev/null || echo 0)
            local good_count=$(grep -cE 'GOOD|Success|success' "$resp_file" 2>/dev/null || echo 0)
            log_info "  Web 安装结果: GOOD=$good_count, BAD/FAIL=$fail_count"
            if [[ "$fail_count" -gt "$good_count" ]]; then
                local debug_file="/tmp/mantisbt_install_$(date +%Y%m%d_%H%M%S).html"
                cp "$resp_file" "$debug_file" 2>/dev/null || true
                log_info "  安装响应已保存: $debug_file"
            fi
            rm -f "$resp_file"
        else
            log_error "  MantisBT Web 服务未就绪，无法执行安装"
        fi

        sleep 2
        table_count=$(docker exec "$MARIADB_CONTAINER_NAME" mysql -u "$MANTISBT_DB_USER" -p"$MANTISBT_DB_PASSWORD" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MANTISBT_DB_NAME'" 2>/dev/null | tail -1)
        if [[ "$table_count" -gt 0 ]] 2>/dev/null; then
            log_info "✓ 数据库表安装完成 ($table_count 张表)"
        else
            log_warn "数据库表可能未完全安装，请访问 Web 界面手动完成"
            log_info "  手动安装地址: http://127.0.0.1:$MANTISBT_PORT_WEB/admin/install.php"
        fi
    fi

    local user_table
    user_table=$(docker exec "$MARIADB_CONTAINER_NAME" mysql -N -s -u root -p"$MANTISBT_DB_PASSWORD" -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$MANTISBT_DB_NAME' AND table_name IN ('mantis_user_table', 'mantis_user') ORDER BY FIELD(table_name, 'mantis_user_table', 'mantis_user') LIMIT 1;" 2>/dev/null || true)
    if [[ -z "$user_table" ]]; then
        log_error "数据库初始化不完整: 缺少 MantisBT 用户表 (mantis_user_table 或 mantis_user)"
        log_error "请检查 MantisBT schema 导入或 Web 安装器输出"
        return 1
    fi
    log_info "  MantisBT 用户表: $user_table"

    log_info "配置管理员账号..."
    local admin_sql
    admin_sql=$(cat <<EOSQL
DELETE FROM $user_table WHERE username = '$MANTISBT_ADMIN_USER';
UPDATE $user_table
SET username = '$MANTISBT_ADMIN_USER',
    realname = '$MANTISBT_ADMIN_USER',
    email = 'admin@devopsagent.local',
    password = MD5('$MANTISBT_ADMIN_PASSWORD'),
    enabled = 1,
    protected = 0,
    access_level = 90
WHERE username = 'administrator' OR id = 1;
INSERT INTO $user_table
    (username, realname, email, password, enabled, protected, access_level, login_count, lost_password_request_count, failed_login_count, cookie_string, last_visit, date_created)
SELECT '$MANTISBT_ADMIN_USER',
       '$MANTISBT_ADMIN_USER',
       'admin@devopsagent.local',
       MD5('$MANTISBT_ADMIN_PASSWORD'),
       1,
       0,
       90,
       0,
       0,
       0,
       MD5(CONCAT('$MANTISBT_ADMIN_USER', UNIX_TIMESTAMP())),
       UNIX_TIMESTAMP(),
       UNIX_TIMESTAMP()
WHERE NOT EXISTS (
    SELECT 1 FROM $user_table WHERE username = '$MANTISBT_ADMIN_USER'
);
EOSQL
)
    docker exec -i "$MARIADB_CONTAINER_NAME" mysql -u "$MANTISBT_DB_USER" -p"$MANTISBT_DB_PASSWORD" "$MANTISBT_DB_NAME" <<< "$admin_sql"
    log_info "  ✓ 管理员账号已配置: $MANTISBT_ADMIN_USER / $MANTISBT_ADMIN_PASSWORD"

    log_info "验证数据库连接..."
    local php_test=$(docker exec "$MANTISBT_CONTAINER_NAME" php -r "
        \$config = include '/var/www/html/config/config_inc.php';
        try {
            \$mysqli = new mysqli('$MARIADB_CONTAINER_NAME', '$MANTISBT_DB_USER', '$MANTISBT_DB_PASSWORD', '$MANTISBT_DB_NAME', 3306);
            if (\$mysqli->connect_error) {
                echo 'DB_CONNECT_FAIL: ' . \$mysqli->connect_error;
            } else {
                \$r = \$mysqli->query('SELECT COUNT(*) as cnt FROM information_schema.tables WHERE table_schema=\'$MANTISBT_DB_NAME\'');
                \$row = \$r->fetch_assoc();
                echo 'DB_OK tables=' . \$row['cnt'];
                \$mysqli->close();
            }
        } catch (Exception \$e) {
            echo 'PHP_ERR: ' . \$e->getMessage();
        }
    " 2>&1 || echo "PHP_CHECK_FAILED")
    log_info "  $php_test"

    log_info ""
    log_info "MantisBT 部署完成"
    log_info "===================="
    echo -e "  ${CYAN}访问地址:${NC}"
    echo -e "    - 直连: ${YELLOW}http://127.0.0.1:$MANTISBT_PORT_WEB${NC}"
    echo -e "    - Nginx: ${YELLOW}https://127.0.0.1:$MANTISBT_NGINX_PORT${NC}"
    echo
    echo -e "  ${CYAN}管理员登录:${NC}"
    echo -e "    - 用户名: ${YELLOW}$MANTISBT_ADMIN_USER${NC}"
    echo -e "    - 密码:   ${YELLOW}$MANTISBT_ADMIN_PASSWORD${NC}"
    echo
    echo -e "  ${CYAN}数据库信息:${NC}"
    echo -e "    - 主机: ${YELLOW}$MARIADB_CONTAINER_NAME:3306${NC}"
    echo -e "    - 数据库: ${YELLOW}$MANTISBT_DB_NAME${NC}"

    return 0
}

deploy_mantisbt_standalone() {
    log_banner
    log_step "MantisBT 一键部署/修复"
    deploy_mantisbt
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --deploy)
            deploy_mantisbt
            ;;
        --standalone)
            source "$PROJECT_DIR/lib/common.sh" 2>/dev/null || true
            deploy_mantisbt_standalone
            ;;
        *)
            echo "用法: $0 [--deploy|--standalone]"
            echo "  --deploy      部署 MantisBT"
            echo "  --standalone  独立部署（含 Nginx 集成检测）"
            exit 1
            ;;
    esac
fi
