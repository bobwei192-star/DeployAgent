# DevOpsAgent 生产级安全/合规/性能/稳定性审计报告

> **审计日期**: 2026-05-29
> **项目版本**: v5.1.0
> **审计范围**: 全部源代码、配置、部署脚本、Docker编排、网络架构
> **结论**: ⚠️ **存在 5 个严重安全问题、3 个高风险问题，强烈建议修复后再上线生产环境**

---

## 执行摘要

### 🔴 5个严重问题（必须修，但要用安全的方式修）

| # | 严重问题 | 必须修？ | 修改风险 | 安全修改方式 |
|---|---|---|---|---|
| 1 | SSL私钥在Git仓库中 | ✅ 必须 | 中 | 先备份 → 重新生成证书 → 清理Git历史 → 测试部署 |
| 2 | Jenkins root + docker.sock | ✅ 必须 | 高 | 不要直接改！先搭测试环境验证 |
| 3 | Artifactory 以 root 运行 | ✅ 必须 | 中 | 改前确认数据卷权限，改后chown |
| 4 | MantisBT MD5 + 明文密码 | ✅ 必须 | 低 | 改SQL语句 + 改用secrets文件 |
| 5 | 文件权限755/777 | ✅ 必须 | 极低 | 直接chmod，无风险 |

### 🟠 高风险问题（可以缓一缓，但建议修）

| # | 问题 | 建议 | 风险 |
|---|---|---|---|
| 1 | 弱默认密码 | 部署后强制改密码，或脚本里随机生成 | 低 |
| 2 | SSL密码套件过时 | 改nginx配置后reload即可 | 极低 |
| 3 | set -e 太粗暴 | 可以不改，但要加 trap 回滚 | 中 |

### ⏱️ 执行时间表

| 时间 | 动作 |
|---|---|
| **今天** | 改文件权限、改.gitignore、改nginx配置 |
| **本周** | 清理Git历史（用git-filter-repo）、重新生成SSL证书和Token |
| **周末** | 搭测试环境，验证Jenkins和Artifactory非root运行 |
| **上线前** | 确保5个严重问题全部解决 |
| **上线后第一周** | 修高风险问题、加资源限制 |

> **底线**: 5个严重问题不解决，绝对不要上生产。私钥在Git里等于裸奔，Jenkins root + docker.sock 等于给攻击者留了后门。

---

## 目录

1. [第一部分：立即执行（零风险，今晚就能做）](#第一部分立即执行零风险今晚就能做)
2. [第二部分：需要测试环境验证](#第二部分需要测试环境验证)
3. [第三部分：可以延后](#第三部分可以延后)
4. [第四部分：详细修复指导](#第四部分详细修复指导)
5. [第五部分：性能与稳定性评估](#第五部分性能与稳定性评估)
6. [第六部分：合规性评估](#第六部分合规性评估)

---

## 第一部分：立即执行（零风险，今晚就能做）

### 1.1 修改文件权限

```bash
# 将敏感文件权限改为仅所有者可读写（零风险）
chmod 600 .env .env.auto
chmod 600 deploy_nginx/nginx/ssl/*.key
chmod 600 config/artifactory/system.yaml 2>/dev/null || true
```

**验证**:
```bash
ls -la .env
ls -la deploy_nginx/nginx/ssl/*.key
# 应显示 -rw------- (600)
```

---

### 1.2 修正 .gitignore（零风险，但别忘后续清理Git历史）

**当前问题**: `.gitignore` 中路径全部写成 `deploy/xxx` 前缀，实际文件都在项目根目录，导致 `.env`、`.key`、`.env.auto` 全部进了Git历史。

**修改操作** — 用以下内容**完全替换** `.gitignore`:

```bash
cat > /home/zs/DeployAgent/.gitignore << 'EOF'
# ============================================================
# 系统/IDE
# ============================================================
.idea/
.vscode/
*.swp
*.swo
*~
.DS_Store
Thumbs.db

# ============================================================
# 敏感文件（绝不可提交）
# ============================================================
.env
.env.auto
.env.example
*.key
*.pem
*.crt
deploy_nginx/nginx/ssl/
config/artifactory/system.yaml
config/**/*.new

# ============================================================
# 运行时数据
# ============================================================
data/
deploy.log
*.log
*.pid

# ============================================================
# Python
# ============================================================
__pycache__/
*.pyc
*.pyo
.venv/
venv/

# ============================================================
# Docker
# ============================================================
docker-compose.override.yml

# ============================================================
# 临时文件
# ============================================================
tmp/
temp/
*.tmp
EOF
```

---

### 1.3 Nginx worker_connections 提升

**位置**: `deploy_nginx/nginx/nginx.conf`

**问题**: `worker_connections 1024` 对生产环境过低，仅支持约500并发。

**修改**: 将 `1024` 改为 `4096`

```nginx
worker_connections 4096;
```

**生效方式**: 重新部署nginx容器 或 `docker exec devopsagent-nginx nginx -s reload`

---

## 第二部分：需要测试环境验证

### 2.1 Jenkins root + docker.sock 容器逃逸风险

**严重程度**: 🔴 CRITICAL | **修改风险**: 高

**当前状态**:
```yaml
# docker-compose.yml
jenkins:
  user: root                                    # ← 容器内root
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro  # ← 即使ro也不安全
```

**攻击路径**: Jenkins 任意 Job → 执行 Shell → `docker run -v /:/host ...` → 宿主机 root

**安全修改流程（重要：不要直接改生产！）**:

```
步骤1: 从当前代码切分支
  git checkout -b security-fix-jenkins

步骤2: 在测试机/虚拟机完整跑一遍部署
  python3 deploy_all.py

步骤3: 逐个验证服务正常
  curl -k https://172.21.201.77:18440/jenkins/login

步骤4: 改 docker-compose.yml 中 jenkins 的 user
  user: "1000:1000"

步骤5: 重新部署测试
  docker compose down jenkins
  docker compose up -d jenkins

步骤6: 验证 Jenkins 能启动、Job能执行、数据完整
```

> ⚠️ **注意事项**:
> - 改 `user: "1000:1000"` 后，`/var/jenkins_home` 目录权限可能不对，需要 `chown -R 1000:1000 jenkins_volume`
> - 去掉 `docker.sock` 后，所有用到 Docker 的 Job 会失败
> - **建议**: 先保留 `docker.sock:ro`，只改 user，验证 Jenkins 能启动后再考虑替代方案（如 Docker-in-Docker 或远程 Docker API over TLS）

---

### 2.2 Artifactory root 运行

**严重程度**: 🔴 CRITICAL | **修改风险**: 中

**当前状态**:
```bash
# deploy_artifactory/deploy_artifactory.sh
docker run -d \
    --user root \    # ← 容器内root
    ...
```

**安全修改流程**:

```
步骤1: 确认数据卷当前权限
  docker exec devopsagent-artifactory ls -la /var/opt/jfrog/artifactory

步骤2: 查官方文档确认推荐UID
  # Artifactory OSS 推荐 UID: 1030 (artifactory用户)

步骤3: 修改部署脚本，去掉 --user root

步骤4: 部署前 chown 数据卷
  docker run --rm -v artifactory_data:/data alpine chown -R 1030:1030 /data

步骤5: 重新部署并测试
```

---

### 2.3 MantisBT MD5 密码 + 管理员密码暴露

**严重程度**: 🔴 CRITICAL | **修改风险**: 低

**问题1**: MD5哈希可被秒级彩虹表破解
**问题2**: 数据库密码通过 `docker run -e` 传入，在 `docker inspect` 和 `/proc/*/environ` 中明文可见

**修复要点**:
- MantisBT 密码改用 bcrypt 哈希（需升级镜像或打补丁）
- 数据库密码改用 Docker Secrets 或文件挂载方式传入
- 详见 [第四部分 4.4](#44-mantisbt-修复详细步骤)

---

### 2.4 清理 Git 历史中的敏感文件

**严重程度**: 🔴 CRITICAL | **修改风险**: 中

> ⚠️ **重要警告**: 审计报告初版使用的 `git filter-branch` 已废弃且容易搞坏仓库，请改用 `git filter-repo`。

**安全操作流程**:

```
步骤1: 备份！备份！备份！
  cp -r /home/zs/DeployAgent /home/zs/DeployAgent.backup.$(date +%Y%m%d)
  tar czf deployagent-backup-$(date +%Y%m%d).tar.gz /home/zs/DeployAgent

步骤2: 吊销所有已泄露的凭据
  # 1. 吊销所有SSL私钥对应的证书（如果用于生产）
  # 2. 在.env中生成新的 AGENT_GATEWAY_TOKEN
  # 3. 重新生成所有自签名SSL证书

步骤3: 安装 git-filter-repo
  pip install git-filter-repo

步骤4: 清理Git历史（比filter-branch更安全）
  git filter-repo \
    --path deploy_nginx/nginx/ssl/ \
    --path .env \
    --path .env.auto \
    --invert-paths

步骤5: 重新生成SSL证书
  cd /home/zs/DeployAgent/deploy_nginx/nginx/ssl/
  # 对每个服务重新生成（使用原脚本或openssl）
  # 参考 deploy_all.py 中的证书生成逻辑

步骤6: 重新添加remote并推送
  git remote add origin <your-repo-url>
  git push origin --force --all
  git push origin --force --tags

步骤7: 通知所有协作者
  # 所有人必须重新clone仓库，不能pull！
```

---

## 第三部分：可以延后

### 3.1 弱默认密码（全部6个服务）

| 服务 | 默认用户 | 默认密码 | 修改方式 |
|---|---|---|---|
| Harbor | admin | Harbor12345 | 登录后右上角→修改密码 |
| Artifactory | admin | password | 登录后 Edit Profile → Change Password |
| MantisBT | administrator | root | 登录后 My Account → Change Password |
| MantisBT DB | root | mantisbt_secret | MariaDB `ALTER USER 'root'@'...' IDENTIFIED BY '新密码';` |
| GitLab | root | 自动生成(24h过期) | 登录后 Edit Profile → Password |
| Agent | - | AGENT_GATEWAY_TOKEN | 环境变量 `.env` 中 |

**建议**: 在 `deploy_all.py` 部署完成后打印醒目的密码修改提醒，或首登强制改密。

---

### 3.2 SSL 密码套件过时

**位置**: `deploy_nginx/nginx/conf.d/*.conf`

**当前**:
```nginx
ssl_ciphers HIGH:!aNULL:!MD5;  # ← HIGH 包含CBC模式，已不推荐
```

**修改为**:
```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
```

**生效**: `docker exec devopsagent-nginx nginx -s reload` （零风险）

---

### 3.3 部署脚本 set -e 缺少回滚

所有 `deploy_*.sh` 使用 `set -e`，中途失败会留下半部署状态。

**建议**: 关键步骤添加 `trap` 和条件处理，非关键步骤使用 `|| true` 容错。

---

## 第四部分：详细修复指导

### 4.1 .gitignore 修复详细步骤

```bash
cd /home/zs/DeployAgent

# 1. 确认当前已追踪的敏感文件
git ls-files | grep -E '\.env$|\.key$|\.crt$|ssl/'

# 2. 替换 .gitignore（使用第一部分中的完整内容）
# （已完成，见第一部分 1.2）

# 3. 取消Git对这些文件的追踪（不删除本地文件）
git rm --cached .env .env.auto 2>/dev/null || true
git rm --cached -r deploy_nginx/nginx/ssl/ 2>/dev/null || true

# 4. 提交
git add .gitignore
git commit -m "fix: 修正.gitignore，取消追踪敏感文件"

# 5. 后续必须用 git filter-repo 清理历史（见2.4）
```

---

### 4.2 SSL 证书重新生成详细步骤

```bash
cd /home/zs/DeployAgent/deploy_nginx/nginx/ssl/

# 备份旧证书
mkdir -p ../ssl-backup-$(date +%Y%m%d)
cp *.key *.crt ../ssl-backup-$(date +%Y%m%d)/ 2>/dev/null || true

# 删除旧私钥和证书
rm -f *.key *.crt

# 重新生成各服务证书（根据实际域名调整CN）
for svc in jenkins gitlab agent mantisbt; do
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout ${svc}.key \
        -out ${svc}.crt \
        -subj "/CN=${svc}.devopsagent.local"
    chmod 600 ${svc}.key
done

echo "证书重新生成完成，需重新部署nginx使其生效"
```

---

### 4.3 Jenkins 安全修复详细步骤

**目标**: 去掉 `user: root`，保留 `docker.sock:ro`

```bash
# 1. 在测试环境验证（不要直接动生产！）
git checkout -b security-fix-jenkins

# 2. 修改 docker-compose.yml 中 jenkins 服务的 user
#    user: "1000:1000"

# 3. 备份现有数据
docker run --rm -v devopsagent_jenkins-home:/data -v $(pwd):/backup alpine \
    tar czf /backup/jenkins-backup-$(date +%Y%m%d).tar.gz -C /data .

# 4. 修正数据卷权限
docker run --rm -v devopsagent_jenkins-home:/data alpine chown -R 1000:1000 /data

# 5. 重新部署
docker compose down jenkins
docker compose up -d jenkins

# 6. 验证
# - Jenkins Web界面能正常访问
# - 已有Job配置和数据完整
# - 能执行新的构建任务
```

**终极替代方案（推荐，但更复杂）**:

不要直接挂载 `docker.sock`，改用 Docker-in-Docker (dind):

```yaml
services:
  jenkins:
    user: "1000:1000"
    environment:
      - DOCKER_HOST=tcp://dind:2375
    # 注意: 不再挂载 docker.sock

  dind:
    image: docker:dind
    privileged: true   # ← dind需要，但是隔离在容器内
    command: ["dockerd", "--host=tcp://0.0.0.0:2375", "--storage-driver=overlay2"]
    volumes:
      - dind-data:/var/lib/docker
```

---

### 4.4 MantisBT 修复详细步骤

**问题**: 管理员密码用MD5，数据库root密码通过 `-e` 传入

**短期修复**（低风险，快速上线）:

```bash
# 1. 修改数据库root密码
docker exec -it devopsagent-mantisbt-db mysql -u root -p
# 输入当前密码 mantisbt_secret 后执行:
ALTER USER 'root'@'%' IDENTIFIED BY '新的安全密码';
FLUSH PRIVILEGES;

# 2. 修改MantisBT管理员密码（已部署的实例）
docker exec -it devopsagent-mantisbt bash -c "
    cd /var/www/html &&
    php -r \"
        \$hash = password_hash('新的管理员密码', PASSWORD_BCRYPT);
        echo '新bcrypt哈希: ' . \$hash;
    \"
"
# 然后用这个hash去更新数据库

# 3. 更新 .env 中的密码变量
# MANISBT_DB_PASSWORD=新的安全密码
```

**长期修复**（用Docker Secrets替代环境变量）:

```yaml
# docker-compose.yml
services:
  mantisbt-db:
    secrets:
      - mantisbt_db_password
    environment:
      - MYSQL_ROOT_PASSWORD_FILE=/run/secrets/mantisbt_db_password

secrets:
  mantisbt_db_password:
    file: ./secrets/mantisbt_db_password.txt  # 权限600，不提交Git
```

---

### 4.5 Artifactory 修复详细步骤

```bash
# 1. 确认当前容器运行用户
docker inspect devopsagent-artifactory --format '{{.Config.User}}'

# 2. 确认数据卷挂载点
docker inspect devopsagent-artifactory --format '{{range .Mounts}}{{.Destination}} {{end}}'

# 3. 修改部署脚本 deploy_artifactory/deploy_artifactory.sh
#    删除 --user root 这一行

# 4. 部署前修正数据卷权限（UID 1030 是 Artifactory 官方用户）
docker run --rm -v devopsagent_artifactory-data:/data alpine \
    chown -R 1030:1030 /data

# 5. 重新部署 Artifactory
```

---

## 第五部分：性能与稳定性评估

### 5.1 容器资源限制

✅ **已修复**: `docker-compose.yml` 中所有服务已添加 `deploy.resources` 限制。

| 服务 | 内存硬限制 | CPU硬限制 | 内存预留 | CPU预留 |
|---|---|---|---|---|
| devopsagent | 256m | 1.0 | 128m | 0.5 |
| jenkins | 4g | 2.0 | 2g | 1.0 |
| gitlab | 4g | 2.0 | 2g | 1.0 |
| mantisbt-db | 1g | 1.0 | 512m | 0.5 |
| mantisbt | 512m | 0.5 | 256m | 0.25 |
| nginx | 256m | 0.5 | 128m | 0.25 |

> **注意**: `deploy.resources` 需要 Docker Compose v2+ (docker compose plugin) 支持。如果是旧版 `docker-compose` (python版)，需改用 `mem_limit` + `cpus` 语法。

### 5.2 其他性能建议

| 项目 | 当前值 | 建议值 | 状态 |
|---|---|---|---|
| Nginx worker_connections | 1024 → 4096 | 10000+ | 🟡 已部分改进 |
| Nginx keepalive | 65s | 保持 | ✅ |
| Nginx gzip | Level 6 | 保持 | ✅ |
| Jenkins JVM | -Xmx2g | -Xmx4g | 🟡 待调优 |
| GitLab shm | 512m | 1g | 🟡 待调优 |
| 镜像版本固定 | GitLab/Jenkins ✅ | Artifactory/MantisBT ❌ | 🟡 部分待修复 |

### 5.3 稳定性待改进

| 场景 | 当前表现 | 建议 |
|---|---|---|
| 单服务崩溃 | `restart: unless-stopped` ✅ | - |
| 宿主机重启 | 自动恢复 ✅ | - |
| 磁盘满 | 无预警 | 加磁盘监控 |
| OOM | 无限制 → 已加 | ✅ 但需重新部署生效 |
| 部署脚本中断 | set -e直接退出 | 加trap回滚 |
| Harbor docker load孤儿进程 | 后台不被清理 | 加trap |
| 日志轮转 | Nginx无rotate | 加logrotate配置 |

---

## 第六部分：合规性评估

| 合规项 | 状态 | 说明 |
|---|---|---|
| 数据加密 at rest | ❌ | 数据在未加密Docker卷中 |
| 数据加密 in transit | ⚠️ | Nginx HTTPS，后端HTTP明文 |
| 访问审计日志 | ❌ | 无集中审计 |
| 密钥轮换 | ❌ | 无自动轮换 |
| 最小权限原则 | ❌→🟡 | Jenkins/Artifactory待修复 |
| 密码策略 | ❌ | 弱默认密码 |
| 软件供应链 | ⚠️ | 部分latest镜像 |
| 依赖漏洞扫描 | ❌ | 未集成Trivy/Clair |
| 等保2.0 (GB/T 22239) | ❌ | 多项不满足 |

---

## 附录A：各组件默认凭据汇总

> ⚠️ **部署后第一时间必须修改！**

| 服务 | 地址 | 用户 | 密码 | 修改方法 |
|---|---|---|---|---|
| Jenkins | :18440/jenkins | admin | `ec68cfaf00a74f0b94d3d758acd048c0` | 登录后 Settings → Manage Users |
| GitLab | :18441 | root | 24h过期，需`gitlab-rake gitlab:password:reset`重置 | 登录后 Edit Profile → Password |
| Harbor | :18446 | admin | Harbor12345 | 登录后右上角→修改密码 |
| Artifactory | :18448 | admin | password | Admin → Edit Profile → Change Password |
| MantisBT | :18443 | administrator | root | My Account → Change Password |
| MantisBT DB | :3307 | root | mantisbt_secret | `ALTER USER 'root'@'%' IDENTIFIED BY '新密码';` |
| Agent | :18442 | - | 见 `.env` 中 `AGENT_GATEWAY_TOKEN` | 更新 `.env` 并重新部署 |

---

## 附录B：Git清理命令速查

```bash
# === 备份（必须！）===
cp -r /home/zs/DeployAgent /home/zs/DeployAgent.backup.$(date +%Y%m%d)

# === 安装 git-filter-repo ===
pip install git-filter-repo

# === 从Git历史中删除敏感文件 ===
git filter-repo \
  --path deploy_nginx/nginx/ssl/ \
  --path .env \
  --path .env.auto \
  --path .crt \
  --invert-paths

# === 重新关联远程仓库 ===
git remote add origin <your-repo-url>
git push origin --force --all
git push origin --force --tags

# === 重新生成所有敏感凭据 ===
# 1. 重新生成 SSL 证书（见4.2）
# 2. 重新生成 AGENT_GATEWAY_TOKEN:
#    openssl rand -hex 32
# 3. 更新 .env 中的 TOKEN
# 4. 通知所有协作者重新clone
```

---

## 附录C：代码冗余清单

| 文件 | 重复内容 |
|---|---|
| `lib/common.sh` ↔ `deploy_docker/install_docker.sh` | 日志函数、颜色定义、`pull_image_with_fallback`、`get_jenkins_password`、`get_gitlab_password` 各复制一份 |
| `.gitignore` | `data/harbor/data/`、`deploy.log`、`__pycache__/`、`*.pyc` 原各重复3次（已修复） |

**建议**: 抽取公共函数到 `lib/` 目录，各脚本 `source` 统一引用。

---

*报告结束 — 生成于 2026-05-29*

---

## 修复执行记录

> 记录每条修复的执行时间、操作内容和验证结果。

| # | 日期 | 项目 | 操作 | 结果 |
|---|---|---|---|---|
| 1 | 2026-05-29 10:44 | 文件权限 chmod 600 | `chmod 600 .env .env.auto deploy_nginx/nginx/ssl/*.key` | ✅ 全部 10 个文件已改为 `rw-------` |
| 2 | 2026-05-29 10:49 | .gitignore 修正 | 替换为完整版 .gitignore (52行) | ✅ 已写入；`git rm --cached` 待执行 |
| 3 | 2026-05-29 10:58 | Nginx worker_connections | `deploy_nginx/nginx/nginx.conf` 1024→4096 | ✅ 已修改，需重新部署nginx生效 |
| 4 | 2026-05-29 10:59 | Nginx SSL密码套件 | 5个conf: `HIGH:!aNULL:!MD5` → 现代密码套件 + `ssl_ecdh_curve` | ✅ 5文件全部修改，需nginx reload生效 |
| 5 | 2026-05-29 11:01 | SSL证书权限 | `chmod 644 deploy_nginx/nginx/ssl/*.crt` (755→644) | ✅ 8个.crt文件已改为 `rw-r--r--` |
| 6 | 2026-05-29 11:05 | Jenkins非root运行 | `user: root`→`user: "1000:989"` (compose+脚本) | ✅ 两处已修改，保留docker.sock，需重建容器生效 |
| 7 | 2026-05-29 11:07 | Artifactory非root运行 | `--user root`→`--user "1030:1030"` | ✅ 已修改，需重新部署容器生效 |
| 8 | 2026-05-29 11:09 | MantisBT密码安全 | 硬编码密码→随机生成、root→专用DB用户 | ✅ deploy_mantisbt.sh + docker-compose.yml 已修改 |
| 9 | 2026-05-29 11:13 | Harbor默认密码 | `Harbor12345`→`openssl rand -hex 12` 随机生成 | ✅ deploy_harbor.sh 已修改 |
| 10 | 2026-05-29 11:14 | Artifactory DB密码 | `artifactory_secret`→`openssl rand -hex 16` 随机生成 | ✅ deploy_artifactory.sh 已修改 |
| 11 | 2026-05-29 13:15 | deploy_all.py 硬编码密码 | Harbor/Artifactory/MantisBT 汇总输出硬编码→读env | ✅ deploy_all.py + deploy_harbor.sh 已修改 |
| | | | | |
