#!/usr/bin/env python3
"""
DevOpsAgent 一键部署脚本 v5.1.0 (Python)
=======================================
功能:
  - 环境扫描 (端口占用 / Docker 网络冲突 / 卷冲突)
  - 自动端口分配 (冲突时自动选未占用端口 → .env.auto)
  - 交互式或命令行模式部署
  - Nginx 反向代理自动集成
  - 数据卷备份 / 清理

用法:
  sudo python3 deploy_all.py                 # 交互式
  sudo python3 deploy_all.py --scan-only     # 仅扫描环境
  sudo python3 deploy_all.py --deploy-jenkins-standalone  # 一键部署 Jenkins
"""

import argparse
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR
ENV_FILE = PROJECT_ROOT / ".env"
ENV_EXAMPLE = PROJECT_ROOT / ".env.example"
ENV_AUTO = PROJECT_ROOT / ".env.auto"
DOCKER_COMPOSE_FILE = PROJECT_ROOT / "docker-compose.yml"
DEPLOY_LOG = PROJECT_ROOT / "deploy.log"
STATE_FILE = PROJECT_ROOT / ".deploy_state.json"
BACKUP_DIR = PROJECT_ROOT / "data" / "backups"

PORT_REGISTRY = {
    "jenkins":     {"web": 18081, "agent": 50000},
    "gitlab":      {"http": 19092, "https": 19443, "ssh": 2222},
    "mantisbt":    {"web": 19093},
    "mariadb":     {"db": 3307},
    "langfuse":    {"web": 3000},
    "nexus":       {"web": 8081},
    "harbor":      {"http": 8082, "https": 8445, "registry": 5002},
    "artifactory": {"web": 8084},
    "nginx": {
        "jenkins":    18440,
        "gitlab":     18441,
        "nexus":      18442,
        "mantisbt":   18443,
        "harbor":     18446,
        "langfuse":   18447,
        "artifactory": 18448,
    },
    "webhook":     5000,
}

SERVICE_CONFIG = {
    "jenkins": {
        "deploy_script": PROJECT_ROOT / "deploy_jenkins" / "deploy_jenkins.sh",
        "container": "devopsagent-jenkins",
        "nginx_port_key": ("nginx", "jenkins"),
        "nginx_container_port": 8440,
        "backend_host": "devopsagent-jenkins",
        "backend_port": 8080,
        "nginx_location": "/jenkins/",
    },
    "gitlab": {
        "deploy_script": PROJECT_ROOT / "deploy_gitlab" / "deploy_gitlab.sh",
        "container": "devopsagent-gitlab",
        "nginx_port_key": ("nginx", "gitlab"),
        "nginx_container_port": 8441,
        "backend_host": "devopsagent-gitlab",
        "backend_port": 80,
        "nginx_location": "/",
    },
    "nexus": {
        "deploy_script": PROJECT_ROOT / "deploy_nexus" / "deploy_nexus.sh",
        "container": "devopsagent-nexus",
        "nginx_port_key": ("nginx", "nexus"),
        "nginx_container_port": 8442,
        "backend_host": "devopsagent-nexus",
        "backend_port": 8081,
        "nginx_location": "/",
    },
    "mantisbt": {
        "deploy_script": PROJECT_ROOT / "deploy_MantisBT" / "deploy_mantisbt.sh",
        "container": "devopsagent-mantisbt",
        "nginx_port_key": ("nginx", "mantisbt"),
        "nginx_container_port": 8443,
        "backend_host": "devopsagent-mantisbt",
        "backend_port": 80,
        "nginx_location": "/",
    },
    "harbor": {
        "deploy_script": PROJECT_ROOT / "deploy_harbor" / "deploy_harbor.sh",
        "container": "harbor-portal",
        "nginx_port_key": ("nginx", "harbor"),
        "nginx_container_port": 8446,
        "backend_host": "harbor-portal",
        "backend_port": 8082,
        "nginx_location": "/",
    },
    "nginx": {
        "deploy_script": PROJECT_ROOT / "deploy_nginx" / "deploy_nginx.sh",
        "container": "devopsagent-nginx",
    },
    "langfuse": {
        "deploy_script": PROJECT_ROOT / "deploy_langfuse" / "deploy_langfuse.sh",
        "container": "langfuse-langfuse-web-1",
        "nginx_port_key": ("nginx", "langfuse"),
        "nginx_container_port": 8447,
        "backend_host": "langfuse-langfuse-web-1",
        "backend_port": 3000,
        "nginx_location": "/",
    },
    "artifactory": {
        "deploy_script": PROJECT_ROOT / "deploy_artifactory" / "deploy_artifactory.sh",
        "container": "devopsagent-artifactory",
        "nginx_port_key": ("nginx", "artifactory"),
        "nginx_container_port": 8448,
        "backend_host": "devopsagent-artifactory",
        "backend_port": 8081,
        "nginx_location": "/",
    },
}

DEPLOY_MODES = {
    1: ("full",        "完整部署 (Jenkins + GitLab + MantisBT + Langfuse + Nginx)",  ["jenkins", "gitlab", "mantisbt", "langfuse", "nginx"], True),
    2: ("full-only",   "完整部署 (无 Nginx, Jenkins + GitLab + MantisBT + Langfuse)",  ["jenkins", "gitlab", "mantisbt", "langfuse"],       False),
    3: ("jenkins",     "仅 Jenkins (+ Nginx HTTPS)",                               ["jenkins", "nginx"],                                   True),
    4: ("gitlab",      "仅 GitLab (+ Nginx HTTPS)",                                ["gitlab", "nginx"],                                    True),
    5: ("mantisbt",    "仅 MantisBT (+ Nginx HTTPS)",                               ["mantisbt", "nginx"],                                  True),
    6: ("langfuse",    "仅 Langfuse (+ Nginx HTTPS)",                               ["langfuse", "nginx"],                                  True),
    7: ("nginx",       "仅 Nginx 反向代理",                                          ["nginx"],                                              True),
    8: ("artifactory", "仅 JFrog Artifactory 制品仓库 (+ Nginx HTTPS)",            ["artifactory", "nginx"],                               True),
    9: ("nexus",       "仅 Sonatype Nexus3 制品仓库 (+ Nginx HTTPS)",             ["nexus", "nginx"],                                     True),
    10: ("harbor",     "仅 Harbor 镜像仓库 (+ Nginx HTTPS)",                        ["harbor", "nginx"],                                    True),
}

COLORS = {
    "RED": "\033[0;31m", "GREEN": "\033[0;32m", "YELLOW": "\033[1;33m",
    "BLUE": "\033[0;34m", "CYAN": "\033[0;36m", "BOLD": "\033[1m",
    "PURPLE": "\033[0;35m", "NC": "\033[0m",
}

log_file = None

def log(msg, level="INFO", color=None):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    c = COLORS.get(color, "") if color else ""
    nc = COLORS["NC"]
    prefix = {"INFO": "[INFO]", "WARN": "[WARN]", "ERROR": "[ERROR]", "STEP": "===", "OK": "[OK]"}
    line = f"{c}{prefix.get(level, '[INFO]')}{nc} {ts}  {msg}"
    print(line, flush=True)
    if log_file:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"{prefix.get(level, '[INFO]')} {ts}  {msg}\n")

def info(msg):    log(msg, "INFO", "GREEN")
def warn(msg):    log(msg, "WARN", "YELLOW")
def error(msg):   log(msg, "ERROR", "RED")
def step(msg):    log(msg, "STEP", "BLUE")

def run(cmd, timeout=300, check=False, env=None, input_text=None):
    """运行命令, 返回 CompletedProcess"""
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            check=check, env=env, input=input_text,
        )
        return result
    except subprocess.TimeoutExpired:
        error(f"命令超时 ({timeout}s): {' '.join(cmd)[:120]}")
        raise
    except subprocess.CalledProcessError as e:
        error(f"命令失败 (exit={e.returncode}): {' '.join(cmd)[:120]}")
        raise

def detect_local_ip():
    """只读取物理网卡 IP, 排除 docker/br-/veth/lo/tun 等虚拟接口"""
    try:
        r = run(["ip", "-4", "-o", "addr", "show"], timeout=5)
        best = None
        for line in r.stdout.split("\n"):
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            iface = parts[1]
            if re.match(r"(docker\d*|br-|veth|lo|tun\d*|dummy|tailscale|wg\d*)", iface):
                continue
            m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", line)
            if m:
                ip = m.group(1)
                if not ip.startswith("127."):
                    if iface.startswith("eth"):
                        return ip
                    if best is None:
                        best = ip
        if best:
            return best
    except Exception:
        pass
    return "127.0.0.1"

def load_env():
    env_vars = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").split("\n"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                env_vars[key.strip()] = val.strip().strip('"').strip("'")
    return env_vars

def save_env_auto(port_map):
    lines = [
        "# DevOpsAgent 自动生成的端口分配 (由 deploy_all.py --scan 生成)",
        f"# 生成时间: {datetime.now().isoformat()}",
        "",
    ]
    for service_name, ports in port_map.items():
        lines.append(f"# {service_name}")
        if isinstance(ports, dict):
            for key, val in ports.items():
                lines.append(f"{service_name.upper()}_PORT_{key.upper()}={val}")
        else:
            lines.append(f"{service_name.upper()}_PORT={ports}")
    ENV_AUTO.write_text("\n".join(lines) + "\n", encoding="utf-8")
    info(f"端口分配已写入: {ENV_AUTO}")

def apply_env_file():
    env_vars = load_env()
    if not env_vars:
        return
    os.environ.update(env_vars)

def _set_port_env(service_name, port_name, port):
    env_key = f"{service_name.upper()}_PORT_{port_name.upper()}"
    if service_name == "nginx":
        env_key = f"NGINX_PORT_{port_name.upper()}"
    elif service_name == "mariadb" and port_name == "db":
        env_key = "MARIADB_PORT"
    os.environ[env_key] = str(port)

    if service_name == "nginx" and port_name == "gitlab":
        os.environ["GITLAB_NGINX_PORT"] = str(port)
    elif service_name == "nginx" and port_name == "mantisbt":
        os.environ["MANTISBT_NGINX_PORT"] = str(port)

def apply_port_map(port_map):
    for service_name, ports in port_map.items():
        if isinstance(ports, dict):
            if service_name in PORT_REGISTRY and isinstance(PORT_REGISTRY[service_name], dict):
                PORT_REGISTRY[service_name].update(ports)
            for port_name, port in ports.items():
                _set_port_env(service_name, port_name, port)
        else:
            PORT_REGISTRY[service_name] = ports
            os.environ[f"{service_name.upper()}_PORT"] = str(ports)

# ═══════════════════════════════════════════════════════════════
# 端口扫描模块
# ═══════════════════════════════════════════════════════════════

def scan_occupied_ports():
    """扫描宿主机所有 LISTEN 端口 + Docker 容器已暴露端口 → 合并去重"""
    occupied = set()

    # 1. 宿主机 LISTEN 端口
    try:
        r = run(["ss", "-tlnp"], timeout=5)
        for line in r.stdout.split("\n"):
            m = re.search(r":(\d{1,5})\s", line)
            if m:
                occupied.add(int(m.group(1)))
    except Exception:
        pass

    # 2. Docker 容器暴露端口
    try:
        r = run(["docker", "ps", "--format", "{{.Ports}}"], timeout=10)
        for line in r.stdout.split("\n"):
            for m in re.finditer(r"0\.0\.0\.0:(\d+)", line):
                occupied.add(int(m.group(1)))
    except Exception:
        pass

    return occupied

def find_available_port(default_port, occupied, max_offset=50):
    """从默认端口开始, 找第一个可用端口"""
    for offset in range(max_offset):
        candidate = default_port + offset
        if candidate not in occupied:
            return candidate
    return default_port

def scan_ports(selected_services=None):
    """完整端口扫描 → 返回 {service: {key: port}}"""
    step("端口占用扫描")
    occupied = scan_occupied_ports()
    info(f"已占用端口: {len(occupied)} 个")
    for p in sorted(occupied):
        warn(f"  端口 {p} 已被占用")

    port_map = {}
    services_to_scan = selected_services or list(PORT_REGISTRY.keys())

    for service, ports in PORT_REGISTRY.items():
        if service == "nginx":
            nginx_ports = {}
            for sub_key, default_port in ports.items():
                available = find_available_port(default_port, occupied)
                if available != default_port:
                    warn(f"  [nginx/{sub_key}] {default_port} 已被占用 → 自动分配 {available}")
                nginx_ports[sub_key] = available
                occupied.add(available)
            port_map[service] = nginx_ports
        elif service == "webhook":
            available = find_available_port(ports, occupied)
            if available != ports:
                warn(f"  [webhook] {ports} 已被占用 → 自动分配 {available}")
            port_map[service] = available
            occupied.add(available)
        else:
            service_ports = {}
            for key, default_port in ports.items():
                available = find_available_port(default_port, occupied)
                if available != default_port:
                    warn(f"  [{service}/{key}] {default_port} 已被占用 → 自动分配 {available}")
                service_ports[key] = available
                occupied.add(available)
            port_map[service] = service_ports

    step("端口扫描完成")
    return port_map

# ═══════════════════════════════════════════════════════════════
# Docker 网络扫描模块
# ═══════════════════════════════════════════════════════════════

def scan_docker_network():
    step("Docker 网络扫描")
    conflicts = []

    # 1. 获取 Docker bridge 子网
    try:
        r = run(["docker", "network", "inspect", "devopsagent-network"], timeout=10)
        net_info = json.loads(r.stdout)
        if net_info:
            for config in net_info[0].get("IPAM", {}).get("Config", []):
                subnet = config.get("Subnet", "")
                if subnet:
                    info(f"Docker bridge 子网: {subnet}")
    except Exception:
        info("devopsagent-network 尚未创建, 跳过子网检测")
        return conflicts

    # 2. 检查宿主路由表冲突 (排除 Docker 自带路由)
    try:
        r = run(["ip", "route"], timeout=5)
        host_ranges = []
        for line in r.stdout.split("\n"):
            m = re.search(r"(172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)", line)
            if m and "docker" not in line.lower():
                host_ranges.append(m.group(1))
        if host_ranges:
            warn(f"宿主路由表包含非 Docker 私有网段: {list(set(host_ranges))}")
            conflicts.append(("HOST_ROUTE_OVERLAP", list(set(host_ranges))))
    except Exception:
        pass

    # 3. 检查物理网卡私有 IP (排除 docker/br-/veth/lo/tun)
    try:
        r = run(["ip", "-4", "-o", "addr", "show"], timeout=5)
        all_ips = []
        for line in r.stdout.split("\n"):
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            iface = parts[1]
            if re.match(r"(docker\d*|br-|veth|lo|tun\d*|dummy|tailscale|wg\d*)", iface):
                continue
            m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", line)
            if m:
                ip = m.group(1)
                if re.match(r"(10\.|172\.(?:1[6-9]|2\d|3[01])|192\.168\.)", ip):
                    all_ips.append(f"{ip}({iface})")
        if all_ips:
            info(f"物理网卡私有 IP: {', '.join(all_ips)}")
    except Exception:
        pass

    step("Docker 网络扫描完成")
    return conflicts

# ═══════════════════════════════════════════════════════════════
# 数据卷管理模块
# ═══════════════════════════════════════════════════════════════

def scan_volumes():
    step("Docker 卷扫描")
    volumes = {}
    try:
        r = run(["docker", "volume", "ls", "--format", "{{.Name}}"], timeout=10)
        for line in r.stdout.strip().split("\n"):
            name = line.strip()
            if name:
                volumes[name] = {}
    except Exception:
        return volumes

    # 获取卷大小
    if volumes:
        try:
            r = run(["docker", "system", "df", "-v", "--format", "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}"], timeout=15)
            info(f"已发现 {len(volumes)} 个卷")
            for vol_name in volumes:
                warn(f"  卷: {vol_name} (可能与其他实例冲突)")
        except Exception:
            pass

    return volumes

def backup_volume(volume_name):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_file = BACKUP_DIR / f"{volume_name}_{ts}.tar.gz"
    info(f"备份卷 {volume_name} → {backup_file}")
    try:
        run(["docker", "run", "--rm",
             "-v", f"{volume_name}:/data:ro",
             "-v", f"{BACKUP_DIR}:/backup",
             "alpine", "tar", "czf", f"/backup/{backup_file.name}", "-C", "/data", "."],
            timeout=600)
        info(f"备份完成: {backup_file} ({backup_file.stat().st_size // 1024 // 1024} MB)")
        return True
    except Exception as e:
        error(f"备份失败: {e}")
        return False

def cleanup_volumes(dry_run=True):
    try:
        flag = "-f" if not dry_run else "-f"
        r = run(["docker", "volume", "prune", flag], timeout=30)
        info(f"卷清理: {r.stdout.strip()}")
    except Exception as e:
        error(f"卷清理失败: {e}")

# ═══════════════════════════════════════════════════════════════
# 部署编排模块
# ═══════════════════════════════════════════════════════════════

# 子脚本命名卷映射: service → [(env_var, 默认卷名)]
VOLUME_MAP = {
    "jenkins": [
        ("JENKINS_VOLUME_HOME", "jenkins-home"),
    ],
    "gitlab": [
        ("GITLAB_VOLUME_CONFIG", "gitlab-config"),
        ("GITLAB_VOLUME_LOGS",   "gitlab-logs"),
        ("GITLAB_VOLUME_DATA",   "gitlab-data"),
    ],
    "mantisbt": [
        ("MANTISBT_VOLUME_WEB",  "mantisbt-web"),
        ("MARIADB_VOLUME_DATA",  "mantisbt-db-data"),
    ],
    "langfuse": [
        ("LANGFUSE_VOLUME_DATA",  "langfuse-data"),
    ],
}

def _resolve_volume_name(base_name):
    """检查 Docker 卷是否存在, 存在则追加 _1 _2 后缀直到可用"""
    try:
        r = run(["docker", "volume", "ls", "--format", "{{.Name}}"], timeout=10)
        existing = set(r.stdout.strip().split("\n"))
    except Exception:
        existing = set()

    name = base_name
    suffix = 0
    while name in existing:
        suffix += 1
        name = f"{base_name}_{suffix}"
    return name

def _resolve_service_volumes(service_name):
    """为指定服务解析唯一卷名, 返回 {env_var: resolved_name}"""
    result = {}
    for env_var, default_name in VOLUME_MAP.get(service_name, []):
        resolved = _resolve_volume_name(default_name)
        if resolved != default_name:
            warn(f"  [{service_name}] 卷 {default_name} 已存在 → 使用 {resolved}")
        result[env_var] = resolved
    return result

def deploy_service(service_name):
    cfg = SERVICE_CONFIG.get(service_name)
    if not cfg or not cfg["deploy_script"].exists():
        error(f"部署脚本不存在: {cfg['deploy_script'] if cfg else 'N/A'}")
        return False

    step(f"部署 {service_name}")
    script = cfg["deploy_script"]
    if not os.access(str(script), os.X_OK):
        run(["chmod", "+x", str(script)], timeout=5)

    # 解析唯一卷名, 通过环境变量传递给子脚本
    env = os.environ.copy()
    volumes = _resolve_service_volumes(service_name)
    if volumes:
        env.update(volumes)
        info(f"  卷: {', '.join(f'{k}={v}' for k, v in volumes.items())}")

    _cleanup_old_containers(service_name)

    timeout = 900 if service_name in ("gitlab", "mantisbt", "langfuse") else 600
    r = run([str(script), "--deploy"], timeout=timeout, env=env)

    if r.returncode != 0:
        warn(f"{service_name} 部署脚本返回 exit={r.returncode}, 检查容器是否已在运行...")
        if service_name == "mantisbt":
            error("mantisbt 部署脚本失败，可能是数据库初始化或管理员账号配置失败")
            if r.stdout:
                info(r.stdout[-3000:])
            if r.stderr:
                error(r.stderr[-1000:])
            return False
        container = cfg.get("container", "")
        if container and _container_running(container):
            info(f"✓ {service_name} 容器已在运行, 视为部署成功")
            return True
        error(f"{service_name} 部署失败 (exit={r.returncode})")
        if r.stdout:
            info(r.stdout[-2000:])
        if r.stderr:
            error(r.stderr[-1000:])
        return False
    info(f"✓ {service_name} 部署完成")
    return True

def _container_running(container_name):
    try:
        r = run(["docker", "ps", "--filter", f"name={container_name}", "--format", "{{.Names}}"], timeout=5)
        return bool(r.stdout.strip())
    except Exception:
        return False

def _find_running_container(candidate):
    """查找运行中的容器: 先精确匹配 candidate, 再尝试 devopsagent-* 前缀"""
    if _container_running(candidate):
        return candidate
    base = candidate.split("-", 1)[-1] if "-" in candidate else candidate
    for prefix in ("devopsagent-",):
        alt = f"{prefix}{base}"
        if alt != candidate and _container_running(alt):
            info(f"  容器 {candidate} 不存在, 使用 {alt}")
            return alt
    return None

def _cleanup_old_containers(service_name):
    """部署前停掉占用同一端口的旧容器 (devopsagent-*)"""
    if service_name == "langfuse":
        return
    cfg = SERVICE_CONFIG.get(service_name, {})
    containers = [cfg.get("container", "")]
    if service_name == "mantisbt":
        containers.append("devopsagent-mantisbt-db")
    for container in containers:
        if not container:
            continue
        base = container.split("-", 1)[-1] if "-" in container else container
        for prefix in ("devopsagent-",):
            old = f"{prefix}{base}" if "-" in container else f"{prefix}-{base}"
            if old == container:
                continue
            try:
                r = run(["docker", "ps", "-a", "--filter", f"name={old}", "--format", "{{.Status}}"], timeout=5)
                if r.stdout.strip():
                    info(f"  清理旧容器: {old}")
                    run(["docker", "stop", old], timeout=10)
                    run(["docker", "rm", old], timeout=10)
            except Exception:
                pass

def _generate_nginx_conf(conf_file, listen_port, container, back, ssl_dir, location="/"):
    if location == "/jenkins/":
        conf_content = f"""server {{
    listen {listen_port} ssl;
    listen [::]:{listen_port} ssl;

    server_name _;

    ssl_certificate /etc/nginx/ssl/devopsagent.crt;
    ssl_certificate_key /etc/nginx/ssl/devopsagent.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 100m;

    location = / {{
        return 301 $scheme://$http_host/jenkins/;
    }}

    location = /jenkins {{
        return 301 $scheme://$http_host/jenkins/;
    }}

    location /jenkins/ {{
        proxy_pass http://{container}:{back};
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header X-Forwarded-Port $server_port;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300;
        proxy_connect_timeout 5;
        proxy_send_timeout 90;
    }}
}}
"""
    else:
        conf_content = f"""server {{
    listen {listen_port} ssl;
    listen [::]:{listen_port} ssl;

    server_name _;

    ssl_certificate /etc/nginx/ssl/devopsagent.crt;
    ssl_certificate_key /etc/nginx/ssl/devopsagent.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 100m;

    location / {{
        proxy_pass http://{container}:{back};
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header X-Forwarded-Port $server_port;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300;
        proxy_connect_timeout 5;
        proxy_send_timeout 90;
    }}
}}
"""
    old_content = conf_file.read_text() if conf_file.exists() else ""
    if old_content.strip() == conf_content.strip():
        info(f"  {conf_file.name} 内容未变, 跳过")
        return
    conf_file.write_text(conf_content)
    if location == "/jenkins/":
        info(f"✓ {conf_file.name} 已更新 → proxy_pass http://{container}:{back} (location /jenkins/)")
    else:
        info(f"✓ {conf_file.name} 已更新 → proxy_pass http://{container}:{back}")

def deploy_services(services, use_nginx, nginx_bind="0.0.0.0"):
    _ensure_network()
    failed = []
    for svc in services:
        if svc == "nginx" and use_nginx:
            info("跳过独立 Nginx 子脚本，使用 deploy_all.py 内置反向代理编排")
            continue
        if not deploy_service(svc):
            failed.append(svc)
    if use_nginx:
        nginx_ok = ensure_nginx_proxy(nginx_bind)
        if not nginx_ok:
            failed.append("nginx")
    if failed:
        error(f"以下服务部署失败: {', '.join(failed)}")
        info("已成功部署的服务仍然可用，可单独修复失败的服务")
        return True
    return True

def configure_reverse_proxy_env(services, use_nginx, public_host):
    if not use_nginx:
        return

    nginx_ports = PORT_REGISTRY.get("nginx", {})
    if "gitlab" in services and isinstance(nginx_ports, dict):
        gitlab_port = nginx_ports.get("gitlab")
        if gitlab_port:
            os.environ["GITLAB_USE_HTTPS_PROXY"] = "true"
            os.environ["GITLAB_HOSTNAME"] = public_host
            os.environ["GITLAB_NGINX_PORT"] = str(gitlab_port)
            os.environ["GITLAB_EXTERNAL_URL"] = f"https://{public_host}:{gitlab_port}"
            info(f"GitLab HTTPS 反向代理地址: {os.environ['GITLAB_EXTERNAL_URL']}")

    if "mantisbt" in services and isinstance(nginx_ports, dict):
        mantisbt_port = nginx_ports.get("mantisbt")
        if mantisbt_port:
            os.environ["MANTISBT_USE_HTTPS_PROXY"] = "true"
            os.environ["MANTISBT_HOSTNAME"] = public_host
            os.environ["MANTISBT_NGINX_PORT"] = str(mantisbt_port)
            os.environ["MANTISBT_EXTERNAL_URL"] = f"https://{public_host}:{mantisbt_port}"
            info(f"MantisBT HTTPS 反向代理地址: {os.environ['MANTISBT_EXTERNAL_URL']}")

    if "jenkins" in services and isinstance(nginx_ports, dict):
        jenkins_port = nginx_ports.get("jenkins")
        if jenkins_port:
            os.environ["JENKINS_URL"] = f"https://{public_host}:{jenkins_port}/jenkins"
            info(f"Jenkins HTTPS 反向代理地址: {os.environ['JENKINS_URL']}")

    if "nexus" in services and isinstance(nginx_ports, dict):
        nexus_port = nginx_ports.get("nexus")
        if nexus_port:
            os.environ["NEXUS_URL"] = f"https://{public_host}:{nexus_port}"
            info(f"Nexus3 HTTPS 反向代理地址: {os.environ['NEXUS_URL']}")

    if "harbor" in services and isinstance(nginx_ports, dict):
        harbor_port = nginx_ports.get("harbor")
        if harbor_port:
            os.environ["HARBOR_URL"] = f"https://{public_host}:{harbor_port}"
            info(f"Harbor HTTPS 反向代理地址: {os.environ['HARBOR_URL']}")

    if "langfuse" in services and isinstance(nginx_ports, dict):
        langfuse_port = nginx_ports.get("langfuse")
        if langfuse_port:
            os.environ["LANGFUSE_USE_HTTPS_PROXY"] = "true"
            os.environ["LANGFUSE_HOSTNAME"] = public_host
            os.environ["LANGFUSE_NGINX_PORT"] = str(langfuse_port)
            os.environ["LANGFUSE_EXTERNAL_URL"] = f"https://{public_host}:{langfuse_port}"
            info(f"Langfuse HTTPS 反向代理地址: {os.environ['LANGFUSE_EXTERNAL_URL']}")

    if "artifactory" in services and isinstance(nginx_ports, dict):
        artifactory_port = nginx_ports.get("artifactory")
        if artifactory_port:
            os.environ["ARTIFACTORY_URL"] = f"https://{public_host}:{artifactory_port}"
            info(f"Artifactory HTTPS 反向代理地址: {os.environ['ARTIFACTORY_URL']}")

def _ensure_network():
    """确保 devopsagent-network 存在 (子脚本硬编码此网络名)"""
    r = run(["docker", "network", "ls", "--format", "{{.Name}}"], timeout=5)
    existing = set(r.stdout.strip().split("\n"))

    if "devopsagent-network" in existing:
        return "devopsagent-network"

    run(["docker", "network", "create", "devopsagent-network"], timeout=10)
    info("✓ 创建网络: devopsagent-network")
    return "devopsagent-network"

def ensure_nginx_proxy(nginx_bind="0.0.0.0"):
    step("配置 Nginx 反向代理")
    nginx_conf_d = PROJECT_ROOT / "deploy_nginx" / "nginx" / "conf.d"
    nginx_ssl_dir = PROJECT_ROOT / "deploy_nginx" / "nginx" / "ssl"
    nginx_ssl_dir.mkdir(parents=True, exist_ok=True)

    # SSL 证书
    cert_names = ["devopsagent"]
    for name in cert_names:
        crt_path = nginx_ssl_dir / f"{name}.crt"
        key_path = nginx_ssl_dir / f"{name}.key"
        if not crt_path.exists() or not key_path.exists():
            crt_path.unlink(missing_ok=True)
            key_path.unlink(missing_ok=True)
            run(["openssl", "req", "-x509", "-nodes", "-days", "3650", "-newkey", "rsa:2048",
                 "-keyout", str(key_path), "-out", str(crt_path),
                 "-subj", f"/C=CN/ST=Beijing/O=DevOpsAgent/CN={name}.local"], timeout=30)
            os.chmod(str(key_path), 0o600)
            info(f"✓ 证书已生成: {name}")

    # 检测后端容器并生成 conf
    detected = []
    detected_containers = []
    port_map_args = []

    nginx_confs = {
        "jenkins": ("devopsagent-jenkins", "8080", 8440, "/jenkins/"),
        "gitlab": ("devopsagent-gitlab", "80", 8441, "/"),
        "nexus": ("devopsagent-nexus", "8081", 8442, "/"),
        "mantisbt": ("devopsagent-mantisbt", "80", 8443, "/"),
        "harbor": ("harbor-portal", "8082", 8446, "/"),
        "langfuse": ("langfuse-langfuse-web-1", "3000", 8447, "/"),
        "artifactory": ("devopsagent-artifactory", "8081", 8448, "/"),
    }

    for svc, (container, back, listen_port, location) in nginx_confs.items():
        running_container = _find_running_container(container)
        if not running_container:
            info(f"- {svc} 容器未运行, 跳过")
            continue

        info(f"✓ 检测到 {svc} 容器 ({running_container})")
        detected.append(svc)
        detected_containers.append(running_container)
        nginx_port = PORT_REGISTRY["nginx"].get(svc, listen_port)
        port_map_args.append(f"{nginx_port}:{listen_port}")

        conf_file = nginx_conf_d / f"{svc}.conf"
        _generate_nginx_conf(conf_file, listen_port, running_container, back, nginx_ssl_dir, location)

    # 清理后端已不存在的 stale conf 文件 (防止 Nginx 因 DNS 解析失败而崩溃)
    for conf_file in nginx_conf_d.glob("*.conf"):
        svc_name = conf_file.stem
        if svc_name not in detected:
            info(f"  清理残留 conf: {conf_file.name} (后端容器已不存在)")
            conf_file.unlink()

    # 启动/重启 Nginx
    if detected:
        for container in detected_containers:
            run(["docker", "network", "connect", "devopsagent-network", container], timeout=10)
        run(["docker", "rm", "-f", "devopsagent-nginx"], timeout=30)
        cmd = ["docker", "run", "-d", "--name", "devopsagent-nginx",
               "--network", "devopsagent-network", "--restart", "unless-stopped",
               "-v", f"{PROJECT_ROOT}/deploy_nginx/nginx/nginx.conf:/etc/nginx/nginx.conf:ro",
               "-v", f"{nginx_conf_d}:/etc/nginx/conf.d:ro",
               "-v", f"{nginx_ssl_dir}:/etc/nginx/ssl:ro"]
        for pm in port_map_args:
            cmd.extend(["-p", f"{nginx_bind}:{pm}"])
        cmd.append("nginx:alpine")
        result = run(cmd, timeout=30)
        if result.returncode != 0:
            error("Nginx 容器启动失败")
            if result.stderr:
                error(result.stderr[-1000:])
            return False

        time.sleep(3)

        status_result = run(
            ["docker", "inspect", "-f", "{{.State.Status}}", "devopsagent-nginx"],
            timeout=10,
        )
        if status_result.returncode != 0 or status_result.stdout.strip() != "running":
            error(f"Nginx 容器状态异常: {status_result.stdout.strip() or 'unknown'}")
            logs = run(["docker", "logs", "--tail=80", "devopsagent-nginx"], timeout=10)
            if logs.stderr:
                error(logs.stderr[-1000:])
            if logs.stdout:
                error(logs.stdout[-1000:])
            return False

        test_result = run(["docker", "exec", "devopsagent-nginx", "nginx", "-t"], timeout=10)
        if test_result.returncode != 0:
            error("Nginx 配置检查失败")
            if test_result.stderr:
                error(test_result.stderr[-1000:])
            return False

        info("✓ Nginx 已启动")
        return True
    else:
        info("没有检测到运行中的后端容器, 跳过 Nginx 启动")
        return True

# ═══════════════════════════════════════════════════════════════
# 辅助命令
# ═══════════════════════════════════════════════════════════════

def get_jenkins_password():
    try:
        r = run(["docker", "exec", "devopsagent-jenkins", "cat",
                 "/var/jenkins_home/secrets/initialAdminPassword"], timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            info(f"Jenkins 初始密码: {r.stdout.strip()}")
            return r.stdout.strip()
    except Exception:
        pass
    warn("无法获取 Jenkins 密码 (容器可能未运行或已配置)")
    return None

def get_gitlab_password():
    try:
        r = run(["docker", "exec", "devopsagent-gitlab", "cat",
                 "/etc/gitlab/initial_root_password"], timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            info(f"GitLab root 密码: {r.stdout.strip()}")
            return r.stdout.strip()
    except Exception:
        pass
    warn("无法获取 GitLab 密码 (容器可能未运行或密码文件已过期)")
    return None

def reset_agent_device():
    error("Agent 服务已从部署菜单中移除，请直接使用 deploy_openclaw/ 中的脚本")

def generate_agent_token():
    token = secrets.token_hex(32)
    if ENV_FILE.exists():
        content = ENV_FILE.read_text()
        content = re.sub(
            r"^AGENT_GATEWAY_TOKEN=.*$",
            f"AGENT_GATEWAY_TOKEN={token}",
            content, flags=re.MULTILINE
        )
        ENV_FILE.write_text(content)
    info(f"Agent Gateway Token 已生成: {token}")
    return token

# ═══════════════════════════════════════════════════════════════
# 交互式菜单
# ═══════════════════════════════════════════════════════════════

def select_deploy_mode():
    print()
    print(f"{COLORS['BOLD']}请选择部署模式:{COLORS['NC']}")
    print()
    print(f"{COLORS['CYAN']}【带 Nginx 反向代理（推荐生产环境使用）】{COLORS['NC']}")
    for k in [1]:
        _, desc, _, _ = DEPLOY_MODES[k]
        print(f"  {COLORS['CYAN']}[{k}]{COLORS['NC']} {desc}")
    print(f"{COLORS['CYAN']}【单个服务 + Nginx】{COLORS['NC']}")
    for k in [3, 4, 5, 6, 8, 9, 10]:
        _, desc, _, _ = DEPLOY_MODES[k]
        print(f"  {COLORS['CYAN']}[{k}]{COLORS['NC']} {desc}")
    print()
    print(f"{COLORS['CYAN']}【无 Nginx（本地开发/测试环境）】{COLORS['NC']}")
    for k in [2]:
        _, desc, _, _ = DEPLOY_MODES[k]
        print(f"  {COLORS['CYAN']}[{k}]{COLORS['NC']} {desc}")
    print()
    print(f"{COLORS['CYAN']}【单独部署】{COLORS['NC']}")
    for k in [7]:
        _, desc, _, _ = DEPLOY_MODES[k]
        print(f"  {COLORS['CYAN']}[{k}]{COLORS['NC']} {desc}")
    print()

    try:
        choice = int(input(f"请输入选项 ({'/'.join(str(k) for k in DEPLOY_MODES)}): ").strip())
    except (ValueError, EOFError):
        error("无效输入")
        sys.exit(1)

    if choice not in DEPLOY_MODES:
        error(f"无效选项: {choice}")
        sys.exit(1)

    mode_name, desc, services, use_nginx = DEPLOY_MODES[choice]
    info(f"已选择: {desc}")
    info(f"服务: {services}, Nginx: {use_nginx}")
    return mode_name, services, use_nginx

def print_summary(mode, services, use_nginx):
    ip = detect_local_ip()
    print()
    print(f"{COLORS['GREEN']}{'='*60}{COLORS['NC']}")
    print(f"{COLORS['GREEN']}  DevOpsAgent 部署完成{COLORS['NC']}")
    print(f"{COLORS['GREEN']}{'='*60}{COLORS['NC']}")
    print()
    print(f"  模式: {mode}")
    print(f"  服务: {', '.join(services)}")
    print(f"  Nginx: {'启用' if use_nginx else '未启用'}")
    print()

    print(f"{COLORS['CYAN']}【Docker 数据卷】{COLORS['NC']}")
    for svc in VOLUME_MAP:
        for env_var, vol_name in VOLUME_MAP[svc]:
            resolved = os.environ.get(env_var, vol_name)
            try:
                r = run(["docker", "volume", "inspect", resolved, "--format", "{{.Mountpoint}}"], timeout=5)
                path = r.stdout.strip()
            except Exception:
                path = "?"
            print(f"  {svc:10s} {resolved:25s} → {path}")
    print()

    if use_nginx:
        print(f"{COLORS['CYAN']}【Nginx HTTPS 访问地址】{COLORS['NC']}")
        for svc in services:
            if svc != "nginx" and svc in SERVICE_CONFIG:
                port = PORT_REGISTRY["nginx"].get(svc, "?")
                print(f"  {svc}: https://{ip}:{port}")
        print()

    print(f"{COLORS['CYAN']}【直接 HTTP 访问地址】{COLORS['NC']}")
    for svc in services:
        if svc == "nginx":
            continue
        if svc in PORT_REGISTRY:
            ports = PORT_REGISTRY[svc]
            if isinstance(ports, dict):
                for key, port in ports.items():
                    if key == "agent":
                        continue
                    print(f"  {svc}{'/' + key if key != 'web' else ''}: http://{ip}:{port}")
            else:
                print(f"  {svc}: http://{ip}:{ports}")
    print()

    if "mantisbt" in services:
        print(f"{COLORS['CYAN']}【MantisBT 管理员登录】{COLORS['NC']}")
        print(f"  用户名: {os.environ.get('MANTISBT_ADMIN_USER', 'administrator')}")
        print(f"  密码:   {os.environ.get('MANTISBT_ADMIN_PASSWORD', 'root')}")
        print()

    if "jenkins" in services:
        print(f"{COLORS['CYAN']}【Jenkins 初始密码】{COLORS['NC']}")
        pwd = get_jenkins_password()
        if pwd:
            print(f"  管理员: admin")
            print(f"  密码:   {pwd}")
            print(f"  提示: 首次登录后请立即修改密码")
        else:
            print(f"  管理员: admin")
            print(f"  密码:   <容器未运行或已在首次登录时修改>")
        print()

    if "gitlab" in services:
        print(f"{COLORS['CYAN']}【GitLab root 密码】{COLORS['NC']}")
        pwd = get_gitlab_password()
        if pwd:
            print(f"  用户名: root")
            print(f"  密码:   {pwd}")
            print(f"  提示: 24 小时后密码文件会自动删除，请及时保存")
        else:
            print(f"  用户名: root")
            print(f"  密码:   <容器未运行或密码文件已过期>")
        print()

    if "artifactory" in services:
        print(f"{COLORS['CYAN']}【JFrog Artifactory 管理员登录】{COLORS['NC']}")
        print(f"  用户名: admin")
        print(f"  密码:   password")
        print(f"  访问地址: https://{ip}:{PORT_REGISTRY['nginx'].get('artifactory', '?')}/artifactory/webapp/")
        print(f"  提示: 首次登录后请立即修改密码")
        print()

    if "langfuse" in services:
        print(f"{COLORS['CYAN']}【Langfuse】{COLORS['NC']}")
        print(f"  首次访问请注册管理员账号")
        print(f"  注册后建议将 NEXT_PUBLIC_SIGN_UP_DISABLED 设为 true")
        print()

# ═══════════════════════════════════════════════════════════════
# 交互式 .env 配置
# ═══════════════════════════════════════════════════════════════

def _interactive_env_setup():
    print(f"\n{COLORS['CYAN']}===== .env 交互式配置 ====={COLORS['NC']}")
    print("(直接回车使用括号内的默认值)\n")

    defaults = {
        "JENKINS_PORT_WEB": "18081",
        "JENKINS_PORT_AGENT": "50000",
        "GITLAB_PORT_HTTP": "19092",
        "GITLAB_PORT_SSH": "2222",
        "MANTISBT_PORT_WEB": "19093",
        "MARIADB_PORT": "3307",
        "LANGFUSE_PORT_WEB": "3000",
        "NGINX_PORT_JENKINS": "18440",
        "NGINX_PORT_GITLAB": "18441",
        "NGINX_PORT_MANTISBT": "18443",
        "NGINX_PORT_LANGFUSE": "18447",
        "NGINX_BIND": "0.0.0.0",
        "JENKINS_URL": "http://127.0.0.1:18081/jenkins",
        "MANTISBT_DB_PASSWORD": "mantisbt_secret",
        "MANTISBT_ADMIN_USER": "administrator",
        "MANTISBT_ADMIN_PASSWORD": "root",
        "TIMEZONE": "Asia/Shanghai",
    }

    env_lines = [
        "# DevOpsAgent 环境配置",
        f"# 生成时间: {datetime.now().isoformat()}",
        "",
    ]

    print(f"{COLORS['BOLD']}--- 端口配置 ---{COLORS['NC']}")
    for key in ("JENKINS_PORT_WEB", "JENKINS_PORT_AGENT", "GITLAB_PORT_HTTP",
                "GITLAB_PORT_SSH", "MANTISBT_PORT_WEB", "MARIADB_PORT",
                "LANGFUSE_PORT_WEB",
                "NGINX_PORT_JENKINS", "NGINX_PORT_GITLAB", "NGINX_PORT_MANTISBT",
                "NGINX_PORT_LANGFUSE"):
        default = defaults[key]
        try:
            val = input(f"  {key} [{default}]: ").strip()
        except (EOFError, KeyboardInterrupt):
            val = ""
        env_lines.append(f"{key}={val or default}")

    print(f"\n{COLORS['BOLD']}--- 绑定地址 ---{COLORS['NC']}")
    try:
        val = input(f"  NGINX_BIND [{defaults['NGINX_BIND']}] (0.0.0.0=所有网卡, 127.0.0.1=仅本机): ").strip()
    except (EOFError, KeyboardInterrupt):
        val = ""
    env_lines.append(f"NGINX_BIND={val or defaults['NGINX_BIND']}")

    print(f"\n{COLORS['BOLD']}--- MantisBT 管理员 ---{COLORS['NC']}")
    for key in ("MANTISBT_ADMIN_USER", "MANTISBT_ADMIN_PASSWORD", "MANTISBT_DB_PASSWORD"):
        default = defaults[key]
        try:
            val = input(f"  {key} [{default}]: ").strip()
        except (EOFError, KeyboardInterrupt):
            val = ""
        env_lines.append(f"{key}={val or default}")

    env_lines.append("")
    ENV_FILE.write_text("\n".join(env_lines), encoding="utf-8")
    info(f"✓ .env 文件已创建: {ENV_FILE}")
    info("可随时编辑此文件修改配置")

# ═══════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════

def check_and_install_docker():
    """检测 Docker 是否安装，如未安装则自动安装"""
    import shutil as _shutil
    if _shutil.which("docker"):
        return True

    warn("Docker 未安装，正在尝试自动安装...")
    info("请等待安装完成，如需手动安装请运行: sudo bash deploy_docker/install_docker.sh")

    install_script = PROJECT_ROOT / "deploy_docker" / "install_docker.sh"
    if not install_script.exists():
        error(f"Docker 安装脚本不存在: {install_script}")
        info("请手动安装 Docker: https://docs.docker.com/engine/install/")
        return False

    try:
        result = subprocess.run(
            ["bash", str(install_script)],
            timeout=600,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and _shutil.which("docker"):
            info("✓ Docker 安装成功")
            return True
        else:
            error("Docker 安装失败")
            if result.stdout:
                print(result.stdout[-2000:])
            if result.stderr:
                print(result.stderr[-1000:])
            return False
    except subprocess.TimeoutExpired:
        error("Docker 安装超时 (10分钟)")
        return False
    except Exception as e:
        error(f"安装过程异常: {e}")
        return False

def check_sudo():
    if os.name == "nt":
        return
    if os.geteuid() != 0:
        error("此脚本需要 root 权限运行")
        info("请使用: sudo python3 deploy_all.py")
        sys.exit(1)

def main():
    global log_file
    log_file = DEPLOY_LOG

    parser = argparse.ArgumentParser(
        description="DevOpsAgent 一键部署脚本 v5.1.0 (Python)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--scan-only", action="store_true", help="仅扫描环境, 不部署")
    parser.add_argument("--backup", type=str, help="备份指定卷 (卷名)")
    parser.add_argument("--cleanup-volumes", action="store_true", help="清理悬空卷")
    parser.add_argument("--get-jenkins-password", action="store_true")
    parser.add_argument("--get-gitlab-password", action="store_true")
    parser.add_argument("--reset-agent-device", action="store_true")
    parser.add_argument("--generate-token", action="store_true", help="生成 Agent Gateway Token")
    parser.add_argument("--deploy-jenkins-standalone", action="store_true")
    parser.add_argument("--deploy-gitlab-standalone", action="store_true")
    parser.add_argument("--deploy-mantisbt-standalone", action="store_true")
    parser.add_argument("--deploy-langfuse-standalone", action="store_true")
    parser.add_argument("--deploy-nexus-standalone", action="store_true")
    parser.add_argument("--deploy-artifactory-standalone", action="store_true")
    parser.add_argument("--deploy-harbor-standalone", action="store_true")
    parser.add_argument("--deploy-nginx-standalone", action="store_true")
    parser.add_argument("--nginx-bind", type=str, default=None, help="Nginx 绑定地址 (默认使用交互式输入的 IP)")
    parser.add_argument("--auto-ip", action="store_true", help="自动检测 IP 地址，跳过手动输入确认 (适用于脚本化调用)")

    args = parser.parse_args()

    print(f"\n{COLORS['CYAN']}DevOpsAgent 一键部署脚本 v5.1.0 (Python){COLORS['NC']}\n")

    check_sudo()

    # 自动检测并安装 Docker（如未安装）
    if not check_and_install_docker():
        error("Docker 未安装且自动安装失败，请手动安装后重试")
        sys.exit(1)

    # 快捷命令 (不部署)
    if args.get_jenkins_password:
        get_jenkins_password(); return
    if args.get_gitlab_password:
        get_gitlab_password(); return
    if args.reset_agent_device:
        reset_agent_device(); return
    if args.generate_token:
        generate_agent_token(); return
    if args.backup:
        backup_volume(args.backup); return
    if args.cleanup_volumes:
        cleanup_volumes(dry_run=False); return

    # 扫描
    if args.scan_only:
        step("环境扫描模式")
        apply_env_file()
        port_map = scan_ports()
        save_env_auto(port_map)
        scan_docker_network()
        scan_volumes()
        return

    # standalone 部署
    standalone_map = {
        "jenkins": args.deploy_jenkins_standalone,
        "gitlab": args.deploy_gitlab_standalone,
        "mantisbt": args.deploy_mantisbt_standalone,
        "langfuse": args.deploy_langfuse_standalone,
        "nexus": args.deploy_nexus_standalone,
        "artifactory": args.deploy_artifactory_standalone,
        "harbor": args.deploy_harbor_standalone,
        "nginx": args.deploy_nginx_standalone,
    }

    standalone_svc = [k for k, v in standalone_map.items() if v]
    if standalone_svc:
        services = standalone_svc
        use_nginx = any(s != "nginx" for s in services)
        mode = "standalone"
    else:
        # 交互模式
        mode, services, use_nginx = select_deploy_mode()

    # 环境扫描 (部署前)
    if ENV_FILE.exists():
        apply_env_file()

    port_map = scan_ports(services)
    apply_port_map(port_map)
    save_env_auto(port_map)
    scan_docker_network()
    scan_volumes()

    # 交互式 .env 配置引导
    if not ENV_FILE.exists():
        if args.auto_ip:
            info("跳过 .env 交互配置（--auto-ip 模式），使用默认值")
        else:
            print(f"\n{COLORS['YELLOW']}⚠ 未检测到 .env 文件{COLORS['NC']}")
            print(f"  DevOpsAgent 使用 .env 文件保存自定义配置（端口、密码等）。")
            print(f"  跳过则使用默认值部署，后续可随时编辑 .env 文件。")
            print()
            try:
                answer = input("是否现在创建 .env 配置文件? (y/N): ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                answer = "n"
            if answer in ("y", "yes"):
                _interactive_env_setup()
                apply_env_file()
                apply_port_map(port_map)
            else:
                info("跳过 .env 配置，使用默认值")
    else:
        info(f"已加载 .env 文件: {ENV_FILE}")

    # IP 地址确认
    auto_ip = detect_local_ip()
    if args.auto_ip:
        bind_ip = auto_ip
        info(f"使用自动检测 IP: {bind_ip}")
    else:
        print(f"\n{COLORS['CYAN']}【服务器 IP 地址】{COLORS['NC']}")
        print(f"  自动检测: {auto_ip}")
        print(f"  部署后将通过此 IP 访问各服务（如 https://{auto_ip}:18440）")
        print(f"  如果自动检测不正确，请手动输入正确的 IP 地址")
        try:
            custom_ip = input(f"  输入 IP 地址 (直接回车使用 {auto_ip}): ").strip()
        except (EOFError, KeyboardInterrupt):
            custom_ip = ""
        bind_ip = custom_ip or auto_ip
    info(f"使用 IP: {bind_ip}")

    configure_reverse_proxy_env(services, use_nginx, bind_ip)

    # 部署
    step(f"开始部署: 模式={mode}, 服务={services}")
    bind = args.nginx_bind or bind_ip
    info(f"Nginx 绑定地址: {bind}")
    deploy_services(services, use_nginx, bind)

    print_summary(mode, services, use_nginx)
    info("部署流程完成!")

if __name__ == "__main__":
    main()
