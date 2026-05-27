# Harbor 安装问题排障记录

## 背景

在 `DeployAgent/deploy` 中选择 Harbor 单服务部署模式时，目标形态为：

```text
Harbor 直连 HTTP:  http://127.0.0.1:8083/
Harbor Nginx HTTPS: https://188.188.88.4:18446/
Harbor API 健康检查: /api/v2.0/ping
```

本次排障涉及的主要代码文件：

```text
/home/zx/CICD/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh
/home/zx/CICD/DeployAgent/deploy/deploy_all.py
```

部署过程中涉及的生成文件和运行配置：

```text
/home/zx/CICD/DeployAgent/deploy/data/harbor/harbor/harbor.yml
/home/zx/CICD/DeployAgent/deploy/data/harbor/harbor/docker-compose.yml
/home/zx/CICD/DeployAgent/deploy/deploy_nginx/nginx/conf.d/harbor.conf
/home/zx/CICD/DeployAgent/deploy/.env.auto
```

## 问题 1：Harbor 部署命令 600 秒超时

### 现象

主部署脚本调用 Harbor 子脚本后超时：

```text
[ERROR] 命令超时 (600s): /home/zx/CICD/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh --deploy
subprocess.TimeoutExpired: Command ... timed out after 600 seconds
```

检查容器发现 Harbor 相关容器只创建但没有正常启动：

```text
harbor-portal   Created
registry        Created
harbor-db       Created
registryctl     Created
harbor-log      Created
```

### 原因

旧 Harbor 残留容器占用了 Harbor 日志端口：

```text
installer-log-1 -> 127.0.0.1:1514
harbor-log      -> 127.0.0.1:1514
```

手动启动 `harbor-log` 时报错：

```text
Bind for 127.0.0.1:1514 failed: port is already allocated
```

同时，生成的 Harbor 配置目录部分文件为 `root:root` 且权限较严：

```text
common/config/registryctl/env -> root root -rw-r-----
docker compose config -> permission denied
```

### 解决方式

清理旧 Harbor 残留容器并修复目录权限：

```bash
docker rm -f harbor-log registry registryctl harbor-db harbor-core harbor-portal harbor-jobservice nginx trivy-adapter
docker rm -f installer-log-1 installer-jobservice-1 installer-proxy-1 installer-core-1 installer-trivy-adapter-1 installer-postgresql-1 installer-redis-1 installer-registry-1 installer-portal-1 installer-registryctl-1
sudo chown -R zx:zx /home/zx/CICD/DeployAgent/deploy/data/harbor
```

如果输出 `No such container`，说明对应容器本来就不存在，可以忽略。

## 问题 2：`8082` 显示成 Harbor，但实际不是 Harbor

### 现象

部署摘要打印：

```text
harbor/http: http://188.188.88.4:8082
harbor/https: http://188.188.88.4:8445
harbor/registry: http://188.188.88.4:5002
```

但访问 `8082` 返回的不是 Harbor 页面。实际 Harbor 服务没有监听 `8445`、`5002`，Nginx `18446` 也没有正常起来。

### 原因

`deploy_all.py` 的端口扫描有两个问题：

1. `scan_ports(selected_services)` 虽然收到了 `['harbor', 'nginx']`，但旧逻辑仍遍历整个 `PORT_REGISTRY`，导致非本次部署服务的端口也参与分配。
2. 端口占用检测只依赖 `ss` 和 `docker ps`，在 WSL/Docker 转发场景下，某些端口无法从这两处可靠发现，但实际 `bind()` 会失败。

验证 `8082` 实际已不可绑定：

```text
0.0.0.0:8082 bind_failed [Errno 98] Address already in use
127.0.0.1:8082 bind_failed [Errno 98] Address already in use
188.188.88.4:8082 bind_failed [Errno 98] Address already in use
```

### 代码修复

在 `deploy_all.py` 中新增 `socket` 导入，并用实际 `bind()` 作为端口可用性判断：

```python
import socket
```

```python
def find_available_port(default_port, occupied, max_offset=50):
    """从默认端口开始, 找第一个可用端口"""
    for offset in range(max_offset):
        candidate = default_port + offset
        if candidate not in occupied and _is_port_bindable(candidate):
            return candidate
    return default_port

def _is_port_bindable(port, host="0.0.0.0"):
    """实际尝试 bind, 捕获 ss/docker ps 无法发现的 Windows/WSL 转发占用。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
            return True
        except OSError:
            return False
```

同时只扫描本次要部署的服务：

```python
services_to_scan = selected_services or list(PORT_REGISTRY.keys())
services_to_scan = [svc for svc in services_to_scan if svc in PORT_REGISTRY]

for service in services_to_scan:
    ports = PORT_REGISTRY[service]
```

修复后 Harbor HTTP 端口会避开 `8082`：

```text
[harbor/http] 8082 已被占用 -> 自动分配 8083
```

## 问题 3：Harbor 与已有 `redis` 容器名冲突

### 现象

重新部署 Harbor 后立即失败：

```text
[ERROR] 发现 Harbor 容器名冲突: redis
```

检查现有 `redis` 容器发现它不是 Harbor 残留：

```text
name=/redis
image=redis:7-alpine
project=/home/zx/CICD/部署/services/redis
```

### 原因

Harbor 官方离线安装包生成的 `docker-compose.yml` 使用全局固定容器名：

```yaml
container_name: redis
container_name: nginx
container_name: registry
container_name: harbor-portal
```

在同一台 Docker 主机上部署多个服务时，这些固定名称容易和已有服务冲突。不能为了部署 Harbor 删除非 Harbor 的 `redis`。

### 代码修复

在 `deploy_harbor.sh` 中新增 `patch_harbor_compose()`，删除 Harbor 生成的固定 `container_name`：

```bash
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
```

同时不再直接调用 `./install.sh --with-trivy`，改成显式执行：

```bash
docker load -i ./harbor*.tar.gz
./prepare --with-trivy
patch_harbor_compose "$harbor_install_dir"
docker compose -p devopsagent-harbor up -d
```

修复后 Harbor 容器使用 compose 项目前缀隔离：

```text
devopsagent-harbor-proxy-1
devopsagent-harbor-redis-1
devopsagent-harbor-registry-1
devopsagent-harbor-portal-1
```

不会再和已有 `redis`、`nginx`、`registry` 等容器名冲突。

## 问题 4：Nginx 代理到错误的 Harbor 后端

### 现象

Harbor 本身已经运行并健康：

```text
devopsagent-harbor-proxy-1 Up healthy 0.0.0.0:8083->8080/tcp
http://127.0.0.1:8083/api/v2.0/ping -> Pong
```

但 `devopsagent-nginx` 反复重启，日志显示：

```text
host not found in upstream "harbor-portal" in /etc/nginx/conf.d/harbor.conf:19
```

当时生成的 `harbor.conf` 是：

```nginx
proxy_pass http://harbor-portal:8082;
```

### 原因

去掉 `container_name` 后，Harbor 入口不再是 `harbor-portal`。真正应该被 Nginx 代理的是 Harbor 自带的 `proxy` 容器：

```text
devopsagent-harbor-proxy-1:8080
```

`harbor-portal` 只是 Harbor 前端组件，不是完整 Harbor 对外入口。

### 代码修复

在 `deploy_all.py` 的 `SERVICE_CONFIG` 中修改 Harbor 后端：

```python
"harbor": {
    "deploy_script": PROJECT_ROOT / "deploy_harbor" / "deploy_harbor.sh",
    "container": "devopsagent-harbor-proxy-1",
    "nginx_port_key": ("nginx", "harbor"),
    "nginx_container_port": 8446,
    "backend_host": "devopsagent-harbor-proxy-1",
    "backend_port": 8080,
    "nginx_location": "/",
},
```

在 `ensure_nginx_proxy()` 的内置 Nginx 配置映射中同步修改：

```python
nginx_confs = {
    "jenkins": ("devopsagent-jenkins", "8080", 8440, "/jenkins/"),
    "gitlab": ("devopsagent-gitlab", "80", 8441, "/"),
    "nexus": ("devopsagent-nexus", "8081", 8442, "/"),
    "mantisbt": ("devopsagent-mantisbt", "80", 8443, "/"),
    "harbor": ("devopsagent-harbor-proxy-1", "8080", 8446, "/"),
    "langfuse": ("langfuse-langfuse-web-1", "3000", 8447, "/"),
    "artifactory": ("devopsagent-artifactory", "8082", 8448, "/"),
}
```

修复后的 `harbor.conf` 应包含：

```nginx
proxy_pass http://devopsagent-harbor-proxy-1:8080;
```

当前运行环境如果已有旧配置，需要手工应用一次：

```bash
cd /home/zx/CICD/DeployAgent/deploy

docker network connect devopsagent-network devopsagent-harbor-proxy-1 2>/dev/null || true

sudo sed -i 's|proxy_pass http://harbor-portal:8082;|proxy_pass http://devopsagent-harbor-proxy-1:8080;|' \
  deploy_nginx/nginx/conf.d/harbor.conf

docker restart devopsagent-nginx
```

## 问题 5：WSL 内部 HTTPS 正常，Windows 浏览器访问 `188.188.88.4:18446` 超时

### 现象

WSL 内部访问正常：

```text
https://188.188.88.4:18446/              -> 200 Harbor HTML
https://188.188.88.4:18446/api/v2.0/ping -> 200 Pong
```

Windows 侧访问同一地址超时，但直连本机端口可以访问 Harbor：

```text
http://127.0.0.1:8083/account/sign-in?redirect_url=%2Fharbor%2Fprojects -> 正常
```

### 原因

前面只给 Artifactory 放通过端口：

```text
18448, 8085
```

Harbor 使用的新端口是：

```text
18446  # Nginx HTTPS
8083   # Harbor 直连
```

因此 Windows/Hyper-V 防火墙还需要放通 Harbor 端口。

### 解决方式

管理员 PowerShell 中执行：

```powershell
New-NetFirewallRule -DisplayName "DevOpsAgent Harbor" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18446,8083

New-NetFirewallHyperVRule -Name "DevOpsAgent-Harbor" -DisplayName "DevOpsAgent Harbor WSL" -Direction Inbound -VMCreatorId "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}" -Protocol TCP -LocalPorts 18446,8083 -Action Allow
```

本机浏览器可用直连地址：

```text
http://127.0.0.1:8083/account/sign-in?redirect_url=%2Fharbor%2Fprojects
```

外部或 WSL 内部 HTTPS 入口：

```text
https://188.188.88.4:18446/
```

## 最终验证

Harbor 直连验证：

```bash
curl http://127.0.0.1:8083/api/v2.0/ping
```

预期：

```text
Pong
```

Nginx HTTPS 验证：

```bash
curl -k -I https://188.188.88.4:18446/
```

预期：

```text
HTTP/1.1 200 OK
Server: nginx
```

容器状态：

```text
devopsagent-harbor-proxy-1           Up healthy  0.0.0.0:8083->8080/tcp
devopsagent-harbor-core-1            Up healthy
devopsagent-harbor-jobservice-1      Up healthy
devopsagent-harbor-registry-1        Up healthy
devopsagent-harbor-registryctl-1     Up healthy
devopsagent-harbor-portal-1          Up healthy
devopsagent-harbor-postgresql-1      Up healthy
devopsagent-harbor-redis-1           Up healthy
devopsagent-harbor-trivy-adapter-1   Up healthy
devopsagent-harbor-log-1             Up healthy
```

## 代码变动表

| 文件 | 变动点 | 原因 | 影响 |
|---|---|---|---|
| `deploy_harbor/deploy_harbor.sh` | 增加 `set -o pipefail` | 避免管道中前置命令失败被 `tail` 吞掉 | Harbor 安装失败能正确返回失败 |
| `deploy_harbor/deploy_harbor.sh` | 新增 `check_harbor_conflicts()` 检查 `1514` 端口 | `harbor-log` 固定使用 `127.0.0.1:1514`，旧残留会导致启动失败 | 提前报错，避免卡到主脚本 600 秒超时 |
| `deploy_harbor/deploy_harbor.sh` | 新增 `patch_harbor_compose()` 删除 `container_name` | 官方 compose 使用 `redis/nginx/registry` 等全局容器名，容易冲突 | Harbor 容器改为 `devopsagent-harbor-*` 前缀，能与现有服务共存 |
| `deploy_harbor/deploy_harbor.sh` | 下载命令增加 `--connect-timeout 20 --max-time 600` | 避免网络异常时 curl 长时间挂住 | 下载失败更快暴露 |
| `deploy_harbor/deploy_harbor.sh` | 不再直接执行 `./install.sh --with-trivy`，改为 `docker load` + `./prepare` + patch compose + `docker compose -p devopsagent-harbor up -d` | 需要在启动前修改 Harbor 生成的 compose | 可控地修复容器名冲突并启动 Harbor |
| `deploy_harbor/deploy_harbor.sh` | 启动超时后 `return 1` | 原逻辑可能超时后仍打印部署完成 | 避免误报成功 |
| `deploy_all.py` | 新增 `import socket` 和 `_is_port_bindable()` | `ss/docker ps` 不能完全发现 WSL/Docker 转发端口占用 | 端口扫描能识别 `8082` 实际不可用 |
| `deploy_all.py` | `scan_ports()` 只扫描本次选择的服务 | Harbor 部署不应混入 Jenkins/GitLab 等端口分配 | 部署摘要更接近实际服务 |
| `deploy_all.py` | Docker 端口正则支持 `127.0.0.1`、`188.188.88.4`、`[::]` | 旧逻辑只匹配 `0.0.0.0:port` | 提高端口占用检测覆盖率 |
| `deploy_all.py` | `deploy_services()` 在失败时返回 `False` | 原逻辑失败也返回 `True` | 主流程不再打印“部署流程完成”误导用户 |
| `deploy_all.py` | `main()` 检查 `deploy_services()` 返回值，失败则 `sys.exit(1)` | 上层需要明确知道部署失败 | CI/人工执行都能识别失败状态 |
| `deploy_all.py` | Harbor 后端从 `harbor-portal:8082` 改为 `devopsagent-harbor-proxy-1:8080` | Harbor 对外入口是 proxy，不是 portal | Nginx `18446` 能正确代理 Harbor |
| `deploy_all.py` | `_container_running()` 改为精确匹配容器名 | Docker `name=` 过滤默认模糊匹配，容易误判 | 防止把错误容器当成目标容器 |
| `deploy_all.py` | `_find_running_container()` 增加模糊候选兜底 | 兼容 compose 自动生成的带前缀容器名 | 在精确配置后仍保留一定容错能力 |