#!/usr/bin/env python3
"""
简单测试验证脚本（不依赖 pytest）
"""
import sys
import os

sys.path.insert(0, '/home/zs/DeployAgent/deploy')

from deploy_all import (
    PORT_REGISTRY, 
    SERVICE_CONFIG, 
    DEPLOY_MODES,
    find_available_port,
    detect_local_ip,
)

def test_port_registry():
    """测试端口配置"""
    print("[测试] 端口配置验证...")
    
    assert PORT_REGISTRY is not None, "PORT_REGISTRY 为空"
    assert isinstance(PORT_REGISTRY, dict), "PORT_REGISTRY 不是字典"
    
    core_services = ["jenkins", "gitlab", "mantisbt", "langfuse", "artifactory", "harbor"]
    for service in core_services:
        assert service in PORT_REGISTRY, f"{service} 不在端口配置中"
    
    assert "nginx" in PORT_REGISTRY, "Nginx 端口配置缺失"
    nginx_ports = PORT_REGISTRY["nginx"]
    expected_proxies = ["jenkins", "gitlab", "mantisbt", "langfuse", "artifactory", "harbor"]
    for proxy in expected_proxies:
        assert proxy in nginx_ports, f"Nginx 缺少 {proxy} 的端口配置"
    
    print("  ✓ 端口配置验证通过")

def test_service_config():
    """测试服务配置"""
    print("[测试] 服务配置验证...")
    
    assert SERVICE_CONFIG is not None, "SERVICE_CONFIG 为空"
    assert isinstance(SERVICE_CONFIG, dict), "SERVICE_CONFIG 不是字典"
    
    required_fields = ["deploy_script", "container"]
    for service, config in SERVICE_CONFIG.items():
        for field in required_fields:
            assert field in config, f"{service} 缺少 {field} 配置"
    
    print("  ✓ 服务配置验证通过")

def test_deploy_modes():
    """测试部署模式"""
    print("[测试] 部署模式验证...")
    
    assert DEPLOY_MODES is not None, "DEPLOY_MODES 为空"
    assert isinstance(DEPLOY_MODES, dict), "DEPLOY_MODES 不是字典"
    
    # 验证新增的模式
    assert 8 in DEPLOY_MODES, "Artifactory 部署模式未配置"
    assert 9 in DEPLOY_MODES, "Harbor 部署模式未配置"
    
    artifactory_mode = DEPLOY_MODES[8]
    harbor_mode = DEPLOY_MODES[9]
    
    assert "artifactory" in artifactory_mode[2], "Artifactory 模式缺少 artifactory 服务"
    assert "harbor" in harbor_mode[2], "Harbor 模式缺少 harbor 服务"
    
    print("  ✓ 部署模式验证通过")

def test_util_functions():
    """测试工具函数"""
    print("[测试] 工具函数验证...")
    
    # 获取可用端口
    port = find_available_port(18081, set())
    assert isinstance(port, int), "find_available_port 未返回整数"
    assert 1 <= port <= 65535, f"端口值超出范围: {port}"
    
    # IP 检测
    ip = detect_local_ip()
    assert isinstance(ip, str), "detect_local_ip 未返回字符串"
    
    print("  ✓ 工具函数验证通过")

def test_deploy_scripts():
    """测试部署脚本文件"""
    print("[测试] 部署脚本验证...")
    
    scripts = [
        "/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh",
        "/home/zs/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh",
    ]
    
    for script in scripts:
        assert os.path.exists(script), f"脚本不存在: {script}"
        assert os.path.isfile(script), f"{script} 不是文件"
        assert os.access(script, os.X_OK), f"{script} 没有执行权限"
    
    # 检查脚本内容
    with open("/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh", 'r') as f:
        content = f.read()
        assert "deploy_artifactory()" in content, "Artifactory 脚本缺少 deploy_artifactory 函数"
    
    with open("/home/zs/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh", 'r') as f:
        content = f.read()
        assert "deploy_harbor()" in content, "Harbor 脚本缺少 deploy_harbor 函数"
    
    print("  ✓ 部署脚本验证通过")

def main():
    """运行所有测试"""
    print("\n" + "="*60)
    print(" DevOpsAgent 部署脚本测试套件")
    print("="*60 + "\n")
    
    try:
        test_port_registry()
        test_service_config()
        test_deploy_modes()
        test_util_functions()
        test_deploy_scripts()
        
        print("\n" + "="*60)
        print(" ✅ 所有测试通过!")
        print("="*60)
        return 0
    except AssertionError as e:
        print(f"\n ❌ 测试失败: {e}")
        return 1
    except Exception as e:
        print(f"\n ❌ 测试异常: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    sys.exit(main())
