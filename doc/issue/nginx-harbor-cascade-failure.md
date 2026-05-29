# Nginx ↔ Harbor 级联故障分析 & 解耦方案

> **日期:** 2026-05-29  
> **影响:** Jenkins / GitLab / Harbor / Artifactory 全部通过 Nginx 不可访问  
> **状态:** 已修复, 待优化

---

## 一、故障现象

```
https://172.21.201.77:18440/jenkins  → 无法访问
https://172.21.201.77:18441/         → 无法访问
https://172.21.201.77:18446/         → 无法访问
https://172.21.201.77:18448/         → 无法访问
```

`docker ps` 显示 Nginx 持续 `Restarting (1)`，重启计数高达 **51 次**。

---

## 二、根因分析

### 2.1 直接原因：Harbor proxy + portal 容器死亡 → Nginx 崩溃循环

```
Nginx 启动 → 加载 harbor.conf
           → proxy_pass http://devopsagent-harbor-proxy-1:8080
           → DNS 解析失败 (proxy 容器已死)
           → nginx: [emerg] host not found in upstream
           → 进程 exit
           → restart: always → 再次启动 → 再次崩溃 → 死循环
```

### 2.2 为什么 Harbor proxy/portal 会死？

**关键证据：**

```
docker inspect devopsagent-harbor-proxy-1:
  ExitCode: 128
  Error: "failed to create task for container: 
          failed to initialize logging driver: 
          dial tcp 127.0.0.1:1514: connect: connection refused"
```

**完整时间线（精确到秒）：**

| 时间 (UTC) | 事件 |
|---|---|
| **06:37:53** | **所有 10 个 Harbor 容器同时停止** |
| 06:38:30 | harbor-log 停止并重启 |
| 06:38:32 | harbor-log 启动成功 `127.0.0.1:1514` |
| 06:38:32-33 | core / redis / postgresql / registry 等成功重启 |
| 06:38:32+ | **proxy / portal 启动失败**: logging driver 连不上 `127.0.0.1:1514` (log 尚未就绪) → exit 128 |
| 此后 | proxy / portal **从未被 Docker 自动重试** (RestartCount 保持 0) |
| 07:22 | 人工 `docker start` 手动救活 |

### 2.3 根本原因：Harbor 的 syslog 日志驱动 + Docker 启动顺序不确定

**Harbor 所有 10 个容器都使用 syslog 驱动，全部指向 `tcp://localhost:1514`**：

```yaml
# harbor/docker-compose.yml (每个服务都有这段)
logging:
  driver: "syslog"
  options:
    syslog-address: "tcp://localhost:1514"
    tag: "proxy"
```

**问题链：**

```
Docker daemon 重启
  → 所有容器同时被 kill
  → Docker 尝试并⾏重启所有 restart:always 容器
  → depends_on 是 Compose 层面概念，Docker engine 不保证启动顺序
  → proxy/portal 启动 → logging driver 初始化
  → 尝试连接 tcp://127.0.0.1:1514 (harbor-log 容器)
  → harbor-log 还没启动好 → connection refused
  → Docker 创建容器任务失败 → exit code 128
  → exit 128 是"容器创建阶段失败"，不是运行阶段失败
  → Docker 的 restart policy 可能不处理这个错误
  → proxy/portal 永久死亡，RestartCount=0
```

### 2.4 什么触发了 Docker daemon 重启？

10 个 Harbor 容器 + Nginx + Jenkins + GitLab + Artifactory + MantisBT **全部在同一秒 (06:37:53) 停止**，这是典型的 Docker daemon 级事件：

- **最可能原因**: WSL 环境断连 / Windows 宿主机休眠或重启
- **或**: `systemctl restart docker` / dockerd 崩溃
- **不是** Git 操作导致 — 没有任何文件丢失
- **不是** DeployAgent 代码问题 — 是 Docker 基础设施层面的行为

---

## 三、为什么影响范围这么大？

架构图：

```
                    ┌──────────────────────────┐
                    │     Nginx (反向代理)       │
                    │    监听 18440-18448       │
                    │    restart: always        │
                    └──────┬───────────────────┘
                           │
          ┌────────────────┼────────────────────────┐
          │                │                │        │
     ┌────▼────┐    ┌──────▼──────┐   ┌────▼───┐  ┌─▼──────────┐
     │ Jenkins │    │   GitLab    │   │ Harbor │  │ Artifactory │
     │  :8080  │    │    :80      │   │ :8080  │  │   :8082     │
     └─────────┘    └─────────────┘   └────────┘  └─────────────┘
                                           │
                                      proxy 挂了!
```

**Nginx 是单点瓶颈** — 任意一个 upstream 的 hostname 不可解析，整个 Nginx 进程就无法启动，导致 **全部服务不可用**, 不只是一个。

---

## 四、解决方案

### 4.1 短期：Nginx 解耦 — 让 Nginx 容忍上游不可用

**核心思路：** 使用 `resolver` + 变量 `proxy_pass`，让 Nginx **在请求时解析**，而非启动时解析。

**当前代码（会崩溃）：**

```nginx
# harbor.conf — 启动时解析，失败则 crash
location / {
    proxy_pass http://devopsagent-harbor-proxy-1:8080;
}
```

**修复后（容忍上游宕机）：**

```nginx
# harbor.conf — 请求时解析，失败返回 502，不影响启动
server {
    listen 8446 ssl;
    # ... SSL 配置 ...

    # Docker 内嵌 DNS (127.0.0.11)
    resolver 127.0.0.11 valid=10s ipv6=off;
    resolver_timeout 3s;

    location / {
        set $backend "devopsagent-harbor-proxy-1:8080";
        proxy_pass http://$backend;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # ... 其他 proxy_set_header ...
    }
}
```

**效果：**
- Nginx 启动时不再解析 upstream hostname → **启动成功**
- 请求到达时动态解析 → 如果 Harbor 挂了，返回 `502 Bad Gateway`
- **其他服务 (Jenkins/GitLab) 不受影响**，各自独立可用
- 对 `deploy_all.py` 中 `_generate_nginx_conf()` 生成的所有 conf 文件统一修改

### 4.2 中期：deploy_all.py 已有防御（需确认生效）

`deploy_all.py` 的 `ensure_nginx_proxy()` 第 903-908 行已有清理逻辑：

```python
# 清理后端已不存在的 stale conf 文件
for conf_file in nginx_conf_d.glob("*.conf"):
    svc_name = conf_file.stem
    if svc_name not in detected:
        info(f"  清理残留 conf: {conf_file.name} (后端容器已不存在)")
        conf_file.unlink()
```

但当前 Nginx 是由 `deploy_nginx.sh` standlone 模式创建的，不是 `deploy_all.py` 创建，所以这个清理没生效。**如果 Nginx 始终由 `deploy_all.py` 管理，可以部分缓解此问题。**

### 4.3 长期：Harbor 容器健康检查 + 启动顺序保证

- 给 Harbor proxy/portal 增加 `depends_on` 的 `condition: service_healthy`
- 或使用 Docker Compose v3 的 `start_period` + `healthcheck` 组合
- Harbor 官方 `docker-compose.yml` (v2.3) 的 `depends_on` 不带健康检查条件

---

## 五、修改计划

### 需要修改的文件

| 文件 | 修改内容 |
|---|---|
| `deploy_all.py` `_generate_nginx_conf()` | 在生成的 nginx conf 中增加 `resolver` + 变量 `proxy_pass` |
| `deploy_nginx/deploy_nginx.sh` | `ensure_nginx_proxy()` 和 `deploy_nginx()` 中生成的 conf 同样修改 |
| `deploy_nginx/nginx/conf.d/*.conf` | 手动维护的静态 conf 也一并修改 |

### 修改影响

- **无破坏性变更** — 变量 `proxy_pass` 是标准 Nginx 功能
- **向后兼容** — 上游正常时行为完全一致
- **收益** — 单个服务宕机不再拖垮整个反向代理

---

## 六、相关日志

```
# Nginx 反复崩溃
2026/05/29 07:16:28 [emerg] host not found in upstream "devopsagent-harbor-proxy-1" 
                     in /etc/nginx/conf.d/harbor.conf:19
2026/05/29 07:17:29 [emerg] host not found in upstream "devopsagent-harbor-proxy-1"
                     in /etc/nginx/conf.d/harbor.conf:19
2026/05/29 07:18:29 [emerg] host not found in upstream "devopsagent-harbor-proxy-1"
                     in /etc/nginx/conf.d/harbor.conf:19

# Harbor proxy 死亡原因
ExitCode: 128
Error: "failed to create task for container: 
        failed to initialize logging driver: 
        dial tcp 127.0.0.1:1514: connect: connection refused"

# Nginx 重启统计
RestartCount: 51
```
