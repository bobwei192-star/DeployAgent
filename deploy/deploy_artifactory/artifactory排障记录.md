# Artifactory 部署排障记录

## 背景

在 `DeployAgent/deploy` 中选择 `8` 部署 JFrog Artifactory + Nginx HTTPS 时，部署过程多次出现“脚本显示完成，但页面打不开”或部署中断。

目标部署形态：

- Artifactory 容器：`devopsagent-artifactory`
- Artifactory 直接端口：`8084` 或自动分配端口
- Nginx HTTPS 反向代理端口：`18448` / `18450`
- PostgreSQL：宿主机裸机 PostgreSQL 16，端口 `5433`
- Artifactory 数据库：`artifactory`
- Artifactory 数据库用户：`artifactory`

## 涉及代码文件清单

本次排障和修复主要涉及以下文件。

已修改的代码文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
/home/zx/CICD/DeployAgent/deploy/deploy_all.py
```

新增/完善的排障文档：

```text
/home/zx/CICD/DeployAgent/deploy/artifactory_troubleshooting.md
```

部署过程中会生成或更新的配置文件：

```text
/home/zx/CICD/DeployAgent/deploy/config/artifactory/system.yaml
/home/zx/CICD/DeployAgent/deploy/deploy_nginx/nginx/conf.d/artifactory.conf
/home/zx/CICD/DeployAgent/deploy/.env
/home/zx/CICD/DeployAgent/deploy/.env.auto
```

排障时检查过的相关配置文件：

```text
/etc/postgresql/16/main/pg_hba.conf
/etc/postgresql/16/main/postgresql.conf
/home/zx/CICD/DeployAgent/deploy/deploy_nginx/nginx/nginx.conf
```

相关运行日志位置：

```text
/home/zx/CICD/DeployAgent/deploy/deploy.log
/opt/jfrog/artifactory/var/log/router-service.log
/opt/jfrog/artifactory/var/log/router-request.log
/opt/jfrog/artifactory/var/log/frontend-service.log
/opt/jfrog/artifactory/var/log/frontend-request.log
```

## 问题 1：PostgreSQL 网关连接失败

### 问题现象

部署 Artifactory 时失败：

```text
Docker 网关连接失败，尝试重载 pg_hba.conf...
Docker 网关连接仍然失败! 请手动检查 pg_hba.conf
PostgreSQL 配置失败，Artifactory 无法启动
```

手动验证时，本地连接成功，但通过 Docker 网关连接失败：

```text
127.0.0.1:5433 连接成功
172.31.1.1:5433 连接失败:
FATAL: no pg_hba.conf entry for host "10.255.255.254"
```

### 问题原因

部署脚本根据 Docker 网络子网写入 `pg_hba.conf`，例如：

```text
host    artifactory    artifactory    172.31.1.0/24    md5
```

但在 WSL/Docker 网络环境下，PostgreSQL 实际看到的连接来源可能是：

```text
10.255.255.254
```

因此 PostgreSQL 拒绝连接。

### 解决方式

在 `/etc/postgresql/16/main/pg_hba.conf` 追加允许规则：

```bash
sudo tee -a /etc/postgresql/16/main/pg_hba.conf >/dev/null <<'EOF'

# Allow Artifactory container / WSL Docker gateway checks
host    artifactory    artifactory    172.31.1.0/24       md5
host    artifactory    artifactory    10.255.255.254/32   md5
EOF

sudo -u postgres psql -p 5433 -c "SELECT pg_reload_conf();"
```

验证：

```bash
PGPASSWORD=artifactory_secret \
psql -h 172.31.1.1 -p 5433 -U artifactory -d artifactory -c "select 1;"
```

> **注意**：以上为一次性手动修复。脚本已增加 WSL2 自动检测逻辑，详见 [问题 5](#问题-5wsl2-网段变化导致-pg_hbaconf-白名单再次失效)。

## 问题 2：页面 500，Artifactory 内部 router/access 起不来

### 问题现象

脚本最后打印：

```text
✓ artifactory 部署完成
部署流程完成
```

但页面打不开，容器日志持续出现：

```text
Registration with router on URL http://localhost:8046 failed
Connection refused
Artifactory context could not be initialized
```

更早的关键错误是：

```text
Could not save system configuration file
failed renaming file ... to /opt/jfrog/artifactory/var/etc/system.yaml
error: open /opt/jfrog/artifactory/var/etc/system.yaml: read-only file system
```

### 问题原因

部署脚本把 `system.yaml` 以只读方式挂载到容器：

```bash
-v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml:ro"
```

JFrog 启动时会对 `system.yaml` 中的敏感字段进行加密并回写文件。只读挂载导致配置无法回写，进而导致 router/access 初始化失败。

### 代码修复

文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

变更 1：去掉 `:ro`，允许 JFrog 回写 `system.yaml`。

```diff
-        -v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml:ro" \
+        -v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml" \
```

变更 2：启动超时后返回失败，避免误报“部署完成”。

```diff
     if [[ $wait_count -ge $max_wait ]]; then
         log_warn "Artifactory 启动超时，检查容器状态..."
         docker ps | grep "$ARTIFACTORY_CONTAINER_NAME"
         log_info "最后 30 行日志:"
         docker logs --tail 30 "$ARTIFACTORY_CONTAINER_NAME" 2>&1
+        return 1
     fi
```

语法检查：

```bash
bash -n deploy_artifactory/deploy_artifactory.sh
```

## 重新部署清理步骤

如果需要重新走完整 Artifactory 部署流程：

```bash
cd /home/zx/CICD/DeployAgent/deploy

sudo docker rm -f devopsagent-artifactory
sudo docker volume rm artifactory-home

sudo -u postgres psql -p 5433 -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='artifactory';"
sudo -u postgres psql -p 5433 -c "DROP DATABASE IF EXISTS artifactory;"
sudo -u postgres psql -p 5433 -c "DROP ROLE IF EXISTS artifactory;"

sudo rm -rf config/artifactory data/artifactory
sudo python3 deploy_all.py
```

## 成功标志

容器日志中出现：

```text
All services started successfully
```

并且各服务健康：

```text
jfac HEALTHY
jfcfg HEALTHY
jfevt HEALTHY
jffe HEALTHY
jfmd HEALTHY
jfob HEALTHY
jfrt HEALTHY
jftpl HEALTHY
```

HTTP 验证：

```bash
curl -I http://127.0.0.1:8084/
curl -I http://127.0.0.1:8084/artifactory/webapp/
curl -k -I https://188.188.88.4:18450/artifactory/webapp/
```

其中 `302` 是正常登录跳转，不是错误。

## 问题 3：服务启动成功，但浏览器访问 `/artifactory/webapp/` 后 404

### 问题现象

Artifactory 日志已经出现：

```text
All services started successfully
```

但浏览器访问：

```text
http://188.188.88.4:8084/artifactory/webapp/
http://localhost:8084/artifactory/webapp/
```

会跳转到：

```text
/ui/
```

然后显示：

```text
HTTP Status 404 – Not Found
```

### 问题原因

JFrog Artifactory 7 的 UI 应该通过 Router 外部入口 `8082` 访问。

当前脚本错误地把宿主端口映射到容器 `8081`：

```bash
-p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8081"
```

并且 Nginx 也错误代理到容器 `8081`：

```nginx
proxy_pass http://devopsagent-artifactory:8081;
```

验证结果：

```text
http://localhost:8081/ui/  => 404
http://localhost:8082/ui/  => 200
```

因此 `8084` 实际连到了 Artifactory 后端服务，不是 JFrog Router/UI 入口。

### 代码修复

文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

变更：

```diff
-        -p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8081" \
+        -p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8082" \
```

文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_all.py
```

变更：

```diff
-        "artifactory": ("devopsagent-artifactory", "8081", 8448, "/"),
+        "artifactory": ("devopsagent-artifactory", "8082", 8448, "/"),
```

修改后需要重新创建 Artifactory 和 Nginx 容器，让端口映射和反向代理配置生效。

## 问题 4：`/ui/` 返回 200，但页面一直停在 JFrog 加载动画

### 问题现象

后端 API 正常：

```text
/artifactory/api/system/ping  => 200 OK
/access/api/v1/system/ping    => 200 OK
/router/api/v1/system/health  => 200 OK
```

但浏览器页面一直停留在 JFrog loading 动画。

浏览器控制台出现大量 MFE manifest 错误：

```text
Refused to execute script ... manifest.umd.js because its MIME type ('text/plain') is not executable
single-spa minified message
```

### 问题原因

较新的 Artifactory OSS 镜像中，JFConnect/部分前端 MFE 会请求 OSS 版本中不存在的组件或 entitlement 能力，导致前端加载流程卡住。

### 代码修复

在生成的 `system.yaml` 中显式禁用 JFConnect：

```yaml
jfconnect:
  enabled: false
```

同时容器启动时增加环境变量：

```bash
-e JF_JFCONNECT_ENABLED=false
```

修改位置：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

## 问题 5：WSL2 网段变化导致 pg_hba.conf 白名单再次失效

### 问题现象

宿主机网段从 `188.188.88.x` 切换到其他网段后，重新执行 `deploy_all.py` 部署 Artifactory 仍然失败：

```text
Docker 网关连接仍然失败! 请手动检查 pg_hba.conf
PostgreSQL 配置失败，Artifactory 无法启动
```

手动验证：

```bash
PGPASSWORD=artifactory_secret psql -h 127.0.0.1 -p 5433 -U artifactory -d artifactory -c "SELECT 1;"
# → 成功

PGPASSWORD=artifactory_secret psql -h 172.18.0.1 -p 5433 -U artifactory -d artifactory -c "SELECT 1;"
# → FATAL: no pg_hba.conf entry for host "10.255.255.254"
```

### 问题原因

问题 1 的静态修复（手动追加 `10.255.255.254/32`）只是一次性操作。当以下情况发生时，pg_hba.conf 白名单再次不匹配：

1. **WSL2 重启后 eth0 IP 变化**：WSL2 的 eth0 地址由 Windows Hyper-V 虚拟交换机动态分配，每次重启可能不同
2. **宿主机网段切换**：Windows 宿主机从 `188.188.88.x` 切到其他网段后，WSL2 内部路由也随之变化
3. **PostgreSQL 看到的来源 IP 实际是**：
   - `10.255.255.254` — WSL2 本地回环特殊地址（通过 `lo` 接口可见）
   - WSL2 eth0 子网内的地址
   - Windows 宿主机（默认网关）的地址

而不仅仅是 Docker 网络网关 `172.18.0.1` 所属的子网。

### 代码修复

在 `deploy_artifactory.sh` 的 `configure_postgresql()` 函数中，**自动检测 WSL2 环境并动态追加 pg_hba.conf 白名单**，不再依赖手动操作。

文件：

```text
/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

新增逻辑（在已有的 Docker 子网规则之后，PostgreSQL 重启之前）：

```bash
# ─── WSL2 网络适配: 自动检测 WSL2 特殊网关 IP ───
# WSL2 环境下, Docker 容器的连接源 IP 不经过 Docker 桥接,
# 而是走 WSL2 虚拟交换机 (Hyper-V), PostgreSQL 看到的来源 IP 可能是:
#   10.255.255.254  (WSL2 本地回环特殊地址)
#   172.21.x.x      (WSL2 eth0 子网)
log_info "检测 WSL/Docker 实际源地址..."

# 1) 检测 WSL2 特殊回环 IP
if ip -4 addr show lo 2>/dev/null | grep -q "10.255.255.254"; then
    if ! grep -q "10.255.255.254" "$PG_HBA_CONF" 2>/dev/null; then
        echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    10.255.255.254/32    md5" >> "$PG_HBA_CONF"
        log_info "  ✓ 已添加 WSL2 特殊 IP: 10.255.255.254/32"
    fi
fi

# 2) 检测 WSL2 eth0 子网 (VM 主网络接口)
local eth0_cidr
eth0_cidr=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+/\d+')
if [[ -n "$eth0_cidr" ]]; then
    eth0_ip=$(echo "$eth0_cidr" | cut -d/ -f1)
    eth0_net=$(echo "$eth0_ip" | cut -d. -f1-3)
    eth0_entry="${eth0_net}.0/24"
    if ! grep -q "${eth0_net}" "$PG_HBA_CONF" 2>/dev/null; then
        echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    ${eth0_entry}    md5" >> "$PG_HBA_CONF"
        log_info "  ✓ 已添加 WSL2 eth0 子网: ${eth0_entry}"
    fi

    # 3) 同时添加默认网关 (Windows 宿主机 IP)
    default_gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [[ -n "$default_gw" ]] && ! grep -q "${default_gw}" "$PG_HBA_CONF" 2>/dev/null; then
        echo "host    ${ARTIFACTORY_DB_NAME}    ${ARTIFACTORY_DB_USER}    ${default_gw}/32    md5" >> "$PG_HBA_CONF"
        log_info "  ✓ 已添加默认网关: ${default_gw}/32"
    fi
fi
```

同时增强连接验证失败时的错误提示，方便快速定位：

```bash
log_error "Docker 网关连接仍然失败!"
log_error "  预期来源 IP: 10.255.255.254 (WSL2) 或 ${DOCKER_GATEWAY} (Docker)"
log_error "  请手动执行以下命令排查:"
log_error "    sudo -u postgres psql -p $PG_PORT -c \"SELECT * FROM pg_hba_file_rules WHERE database='${ARTIFACTORY_DB_NAME}';\""
log_error "    tail -20 /var/log/postgresql/postgresql-${PG_VERSION}-main.log  | grep 'no pg_hba'"
```

### 检测维度说明

| 检测项 | 检测来源 | 典型值 | 对应场景 |
|--------|----------|--------|----------|
| WSL2 特殊回环 IP | `ip addr show lo` | `10.255.255.254/32` | psql 通过 Docker 网关连接时的实际来源 |
| eth0 子网 | `ip addr show eth0` | `172.21.201.0/24` | 容器通过 WSL2 内部网络访问宿主机服务 |
| 默认网关 | `ip route show default` | `172.21.192.1/32` | Windows 宿主机 IP（Hyper-V 交换机网关） |

### 修改原因

原脚本只为 Docker 网络子网添加了白名单，WSL2 环境中容器流量不经过 Docker 桥接。每次 WSL2 重启或宿主机换网段时，eth0 IP 可能变化，静态白名单方案无法应对。

改为动态检测后，无论网段如何变化，脚本自动覆盖所有可能来源，无需手动干预。

### 影响

- 修复 WSL2 环境下的 pg_hba.conf 白名单自动化适配。
- 宿主机网段切换后无需手动修改配置文件。
- 连接失败时错误信息更具体，排查更快。

## 详细代码变更清单

本节记录本次实际修改过的部署代码，以及当前运行环境中为了立即验证而执行过的临时修复命令。

### 变更 1：`system.yaml` 允许 JFrog 回写

修改文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

修改位置：

```text
docker run -d ... 创建 devopsagent-artifactory 容器时的 volume 挂载参数
```

修改前：

```bash
-v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml:ro" \
```

修改后：

```bash
-v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml" \
```

修改原因：

JFrog 启动时会读取 `system.yaml`，并把数据库密码等敏感字段加密后写回同一个文件。例如明文密码会被改写为类似：

```text
7283ce.aesgcm256....
```

如果使用 `:ro` 只读挂载，容器内部无法重命名和覆盖 `/opt/jfrog/artifactory/var/etc/system.yaml`，会导致以下错误：

```text
Could not save system configuration file
open /opt/jfrog/artifactory/var/etc/system.yaml: read-only file system
```

影响：

- 修复 Artifactory 初始化阶段写配置失败。
- 修复 router/access/jffe 等内部服务注册失败。
- 避免部署脚本显示完成但实际页面 500。

### 变更 2：Artifactory 外部访问端口改为 Router 入口 `8082`

修改文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

修改位置：

```text
docker run -d ... 创建 devopsagent-artifactory 容器时的 -p 参数
```

修改前：

```bash
-p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8081" \
```

修改后：

```bash
-p "$ARTIFACTORY_BIND:$ARTIFACTORY_PORT_WEB:8082" \
```

完整修改后片段：

```bash
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
```

修改原因：

Artifactory 7 容器里常见端口含义如下：

```text
8081: Artifactory 后端服务
8082: JFrog Router 外部入口，负责 /ui/、/artifactory/、/access/ 等统一路由
```

原来把宿主机 `8084` 映射到容器 `8081`，所以浏览器访问：

```text
http://localhost:8084/artifactory/webapp/
```

会先跳转到：

```text
http://localhost:8084/ui/
```

但 `/ui/` 在容器 `8081` 上不存在，因此返回：

```text
HTTP Status 404 – Not Found
```

验证对比：

```text
容器内 http://localhost:8081/ui/ => 404
容器内 http://localhost:8082/ui/ => 200
```

影响：

- `http://localhost:8084/artifactory/webapp/` 可以正确跳转到 `/ui/`。
- `http://localhost:8084/ui/` 可以正确打开 JFrog 登录页。
- 当前容器实际端口映射已经重建为：

```text
0.0.0.0:8084 -> container:8082
```

### 变更 3：Nginx 反向代理后端改为 `8082`

修改文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_all.py
```

修改位置：

```python
nginx_confs = {
    ...
}
```

修改前：

```python
"artifactory": ("devopsagent-artifactory", "8081", 8448, "/"),
```

修改后：

```python
"artifactory": ("devopsagent-artifactory", "8082", 8448, "/"),
```

完整上下文：

```python
nginx_confs = {
    "jenkins": ("devopsagent-jenkins", "8080", 8440, "/jenkins/"),
    "gitlab": ("devopsagent-gitlab", "80", 8441, "/"),
    "nexus": ("devopsagent-nexus", "8081", 8442, "/"),
    "mantisbt": ("devopsagent-mantisbt", "80", 8443, "/"),
    "harbor": ("harbor-portal", "8082", 8446, "/"),
    "langfuse": ("langfuse-langfuse-web-1", "3000", 8447, "/"),
    "artifactory": ("devopsagent-artifactory", "8082", 8448, "/"),
}
```

修改原因：

`deploy_all.py` 会生成 Nginx 的 `artifactory.conf`。如果这里仍然写 `8081`，HTTPS 入口会继续代理到错误的 Artifactory 后端端口。

期望生成的 Nginx 配置应为：

```nginx
location / {
    proxy_pass http://devopsagent-artifactory:8082;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Ssl on;
    proxy_set_header X-Forwarded-Port $server_port;
}
```

影响：

- 修复 `https://188.188.88.4:18450/artifactory/webapp/` 经过 Nginx 后仍然访问错误后端的问题。
- 注意：当前运行中的 Nginx 容器挂载了只读配置目录，不能在容器内直接 `sed -i` 修改。需要重建 Nginx 容器或重新执行 `sudo python3 deploy_all.py` 让新配置生效。

### 变更 4：生成 `system.yaml` 时禁用 JFConnect

修改文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

修改函数：

```bash
generate_system_yaml()
```

修改后完整片段：

```bash
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
```

修改原因：

较新的 `releases-docker.jfrog.io/jfrog/artifactory-oss:latest` 中，前端服务会访问 JFConnect/entitlement 能力。OSS 镜像中这些能力不完整时，会出现：

```text
First-time entitlement fetch failed: 12 UNIMPLEMENTED: Received HTTP status code 404
count fetch entitlements: 12 UNIMPLEMENTED: Received HTTP status code 404
```

浏览器表现为：

```text
/ui/ 返回 200，但页面一直停在 JFrog loading 动画
```

显式禁用 `jfconnect` 后，页面可以进入登录页。

影响：

- 修复 JFrog UI 一直加载、不出现登录框的问题。
- 不影响 Artifactory OSS 的基础制品仓库能力。

### 变更 5：容器启动参数增加 `JF_JFCONNECT_ENABLED=false`

修改文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

修改位置：

```text
docker run -d ... 环境变量参数
```

新增参数：

```bash
-e JF_JFCONNECT_ENABLED=false \
```

完整上下文：

```bash
-v "$ARTIFACTORY_CONFIG_DIR/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml" \
-e EXTRA_JAVA_OPTIONS="-Xms512m -Xmx2g" \
-e JF_JFCONNECT_ENABLED=false \
--user root \
"$selected_image"
```

修改原因：

`system.yaml` 是配置层面的禁用；环境变量是运行时兜底禁用。二者同时设置，可以避免镜像内部默认值覆盖配置文件导致 JFConnect 仍然启动。

### 变更 6：启动超时必须返回失败

修改文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh
```

修改位置：

```text
等待 Artifactory 启动的 while 循环之后
```

修改前：

```bash
if [[ $wait_count -ge $max_wait ]]; then
    log_warn "Artifactory 启动超时，检查容器状态..."
    docker ps | grep "$ARTIFACTORY_CONTAINER_NAME"
    log_info "最后 30 行日志:"
    docker logs --tail 30 "$ARTIFACTORY_CONTAINER_NAME" 2>&1
fi
```

修改后：

```bash
if [[ $wait_count -ge $max_wait ]]; then
    log_warn "Artifactory 启动超时，检查容器状态..."
    docker ps | grep "$ARTIFACTORY_CONTAINER_NAME"
    log_info "最后 30 行日志:"
    docker logs --tail 30 "$ARTIFACTORY_CONTAINER_NAME" 2>&1
    return 1
fi
```

修改原因：

原逻辑只打印超时日志，但没有返回失败，后续部署流程仍可能打印：

```text
✓ artifactory 部署完成
部署流程完成
```

这会造成误判：脚本显示成功，但服务实际不可用。

影响：

- 部署失败时脚本会正确退出失败。
- 上层 `deploy_all.py` 可以感知 Artifactory 部署失败。

### 当前运行环境的临时修复命令

除了修改源码，为了让当前已经运行的环境立即恢复访问，执行过一次容器重建。该操作没有删除数据库，也没有删除 `artifactory-home` 数据卷。

重建 Artifactory 容器，把宿主机 `8084` 改为映射容器 `8082`：

```bash
docker rm -f devopsagent-artifactory

docker run -d \
  --name devopsagent-artifactory \
  --network devopsagent-network \
  --restart unless-stopped \
  --ulimit nofile=65535:65535 \
  --ulimit nproc=4096:4096 \
  -p 0.0.0.0:8084:8082 \
  -v artifactory-home:/var/opt/jfrog/artifactory \
  -v /home/zx/CICD/DeployAgent/deploy/config/artifactory/system.yaml:/opt/jfrog/artifactory/var/etc/system.yaml \
  -e EXTRA_JAVA_OPTIONS='-Xms512m -Xmx2g' \
  --user root \
  releases-docker.jfrog.io/jfrog/artifactory-oss:latest
```

给当前容器内的 `system.yaml` 追加 JFConnect 禁用配置并重启：

```bash
docker exec devopsagent-artifactory sh -lc \
  "if ! grep -q '^jfconnect:' /opt/jfrog/artifactory/var/etc/system.yaml; then
     printf '\njfconnect:\n  enabled: false\n' >> /opt/jfrog/artifactory/var/etc/system.yaml;
   fi"

docker restart devopsagent-artifactory
```

当前验证结果：

```text
http://localhost:8084/artifactory/webapp/  => 302 到 /ui/
http://localhost:8084/ui/                  => Login - JFrog
```

### 需要注意的未立即生效项

当前运行中的 Nginx 容器挂载配置目录为只读：

```text
/etc/nginx/conf.d: read-only
```

因此不能在容器内直接修改：

```bash
sed -i 's/devopsagent-artifactory:8081/devopsagent-artifactory:8082/g' /etc/nginx/conf.d/artifactory.conf
```

会报错：

```text
sed: can't create temp file '/etc/nginx/conf.d/artifactory.confXXXXXX': Read-only file system
```

要让 HTTPS 入口 `https://188.188.88.4:18450/...` 生效，需要重建 Nginx 容器或重新执行：

```bash
cd /home/zx/CICD/DeployAgent/deploy
sudo python3 deploy_all.py
```

重新生成后的 `artifactory.conf` 必须包含：

```nginx
proxy_pass http://devopsagent-artifactory:8082;
```

### 修改后的验证命令

脚本语法验证：

```bash
cd /home/zx/CICD/DeployAgent/deploy
bash -n deploy_artifactory/deploy_artifactory.sh
python3 -m py_compile deploy_all.py
```

服务健康验证：

```bash
curl -I http://127.0.0.1:8084/ui/
curl -I http://127.0.0.1:8084/artifactory/webapp/
curl http://127.0.0.1:8084/artifactory/api/system/ping
curl http://127.0.0.1:8084/access/api/v1/system/ping
curl http://127.0.0.1:8084/router/api/v1/system/health
```

预期结果：

```text
/ui/                              => 200
/artifactory/webapp/              => 302 到 /ui/
/artifactory/api/system/ping      => OK
/access/api/v1/system/ping        => OK
/router/api/v1/system/health      => router/services HEALTHY
```