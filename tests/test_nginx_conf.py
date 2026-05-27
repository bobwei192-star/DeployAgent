#!/usr/bin/env python3
"""
Nginx 配置测试用例
验证容器名配置与实际运行容器的一致性
"""
import subprocess
import sys

def test_nginx_confs_container_names():
    """验证 nginx_confs 中的容器名配置"""
    print("=" * 70)
    print("测试: Nginx 配置容器名验证")
    print("=" * 70)
    
    # 定义预期的容器名映射
    expected_confs = {
        "jenkins": "devopsagent-jenkins",
        "gitlab": "devopsagent-gitlab",
        "nexus": "devopsagent-nexus",
        "mantisbt": "devopsagent-mantisbt",
        "harbor": "harbor-portal",
        "langfuse": "langfuse-langfuse-web-1",
        "artifactory": "devopsagent-artifactory",
    }
    
    # 读取 deploy_all.py 中的 nginx_confs 配置
    deploy_all_path = "/home/zs/DeployAgent/deploy/deploy_all.py"
    try:
        with open(deploy_all_path, 'r') as f:
            content = f.read()
        
        # 提取 nginx_confs 字典
        start_idx = content.find('nginx_confs = {')
        end_idx = content.find('}', start_idx) + 1
        nginx_confs_str = content[start_idx:end_idx]
        
        print(f"\n从 {deploy_all_path} 读取的 nginx_confs:")
        print(nginx_confs_str)
        
        # 验证每个服务的容器名
        all_pass = True
        for svc, expected_container in expected_confs.items():
            if f'"{svc}": ("{expected_container}"' in nginx_confs_str:
                print(f"✓ {svc}: 容器名正确 ({expected_container})")
            else:
                print(f"✗ {svc}: 容器名配置错误，期望: {expected_container}")
                all_pass = False
        
        return all_pass
        
    except Exception as e:
        print(f"✗ 读取配置文件失败: {e}")
        return False

def test_running_containers():
    """检查实际运行的容器"""
    print("\n" + "=" * 70)
    print("测试: 检查运行中的容器")
    print("=" * 70)
    
    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            print(f"✗ 执行 docker ps 失败: {result.stderr}")
            return False
        
        running_containers = result.stdout.strip().split('\n')
        print(f"\n当前运行的容器:")
        for container in running_containers:
            if container:
                print(f"  - {container}")
        
        # 检查关键容器是否在运行
        critical_containers = [
            "devopsagent-jenkins",
            "devopsagent-gitlab", 
            "devopsagent-mantisbt",
            "devopsagent-artifactory",
            "langfuse-langfuse-web-1"
        ]
        
        print("\n关键容器状态:")
        all_running = True
        for container in critical_containers:
            if container in running_containers:
                print(f"✓ {container}: 运行中")
            else:
                print(f"✗ {container}: 未运行")
                all_running = False
        
        return all_running
        
    except Exception as e:
        print(f"✗ 检查容器失败: {e}")
        return False

def test_docker_network_connectivity():
    """检查容器网络连接"""
    print("\n" + "=" * 70)
    print("测试: 检查 Docker 网络连接")
    print("=" * 70)
    
    try:
        # 检查网络是否存在
        result = subprocess.run(
            ["docker", "network", "ls", "--filter", "name=devopsagent-network", "--format", "{{.Name}}"],
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            print(f"✗ 检查网络失败: {result.stderr}")
            return False
        
        if "devopsagent-network" in result.stdout:
            print("✓ devopsagent-network 网络存在")
        else:
            print("✗ devopsagent-network 网络不存在")
            return False
        
        return True
        
    except Exception as e:
        print(f"✗ 检查网络失败: {e}")
        return False

if __name__ == "__main__":
    print("\n" + "=" * 70)
    print("Nginx 配置测试套件")
    print("=" * 70)
    
    results = []
    
    # 运行所有测试
    results.append(test_nginx_confs_container_names())
    results.append(test_running_containers())
    results.append(test_docker_network_connectivity())
    
    print("\n" + "=" * 70)
    if all(results):
        print("✓ 所有测试通过!")
        print("=" * 70)
        print("\n建议下一步操作:")
        print("1. 删除旧的 langfuse.conf 配置文件")
        print("2. 重新部署 Nginx")
        print("\n命令:")
        print("  sudo rm /home/zs/DeployAgent/deploy/deploy_nginx/nginx/conf.d/langfuse.conf")
        print("  cd /home/zs/DeployAgent/deploy && sudo python3 deploy_all.py")
        print("  选择 [7] 仅部署 Nginx")
        sys.exit(0)
    else:
        print("✗ 部分测试失败，请检查错误信息")
        sys.exit(1)