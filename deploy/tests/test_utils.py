"""
测试部署脚本中的工具函数
"""
import pytest
import os
import sys
import subprocess

sys.path.insert(0, '/home/zs/DeployAgent/deploy')

from deploy_all import (
    run, 
    log, 
    info, 
    warn, 
    error, 
    check_sudo,
    check_and_install_docker,
    is_port_available,
    get_available_port,
)


class TestUtils:
    """测试工具函数"""

    def test_run_function_exists(self):
        """验证 run 函数存在"""
        assert callable(run)

    def test_log_functions_exists(self):
        """验证日志函数存在"""
        assert callable(log)
        assert callable(info)
        assert callable(warn)
        assert callable(error)

    def test_port_check_functions_exists(self):
        """验证端口检查函数存在"""
        assert callable(is_port_available)
        assert callable(get_available_port)

    def test_is_port_available_returns_bool(self):
        """验证 is_port_available 返回布尔值"""
        result = is_port_available(65535)  # 不太可能被占用的端口
        assert isinstance(result, bool)

    def test_get_available_port_returns_int(self):
        """验证 get_available_port 返回整数"""
        result = get_available_port()
        assert isinstance(result, int)
        assert 1 <= result <= 65535

    def test_get_available_port_finds_open_port(self):
        """验证 get_available_port 能找到可用端口"""
        # 请求多个端口，应该都能找到
        ports = set()
        for _ in range(5):
            port = get_available_port()
            assert port not in ports, "返回了重复的端口"
            ports.add(port)


class TestDockerCheck:
    """测试 Docker 检查功能"""

    def test_check_and_install_docker_function_exists(self):
        """验证函数存在"""
        assert callable(check_and_install_docker)


class TestSudoCheck:
    """测试 sudo 检查功能"""

    def test_check_sudo_function_exists(self):
        """验证函数存在"""
        assert callable(check_sudo)


class TestDeployScripts:
    """测试部署脚本文件"""

    def test_artifactory_script_exists(self):
        """验证 Artifactory 部署脚本存在"""
        script_path = "/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh"
        assert os.path.exists(script_path), f"Artifactory 脚本不存在: {script_path}"
        assert os.path.isfile(script_path), f"{script_path} 不是文件"

    def test_harbor_script_exists(self):
        """验证 Harbor 部署脚本存在"""
        script_path = "/home/zs/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh"
        assert os.path.exists(script_path), f"Harbor 脚本不存在: {script_path}"
        assert os.path.isfile(script_path), f"{script_path} 不是文件"

    def test_scripts_are_executable(self):
        """验证脚本有执行权限"""
        scripts = [
            "/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh",
            "/home/zs/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh",
            "/home/zs/DeployAgent/deploy/deploy_jenkins/deploy_jenkins.sh",
            "/home/zs/DeployAgent/deploy/deploy_gitlab/deploy_gitlab.sh",
        ]
        
        for script in scripts:
            if os.path.exists(script):
                assert os.access(script, os.X_OK), f"{script} 没有执行权限"

    def test_artifactory_script_has_function(self):
        """验证 Artifactory 脚本包含 deploy_artifactory 函数"""
        script_path = "/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh"
        with open(script_path, 'r') as f:
            content = f.read()
        assert "deploy_artifactory()" in content, "Artifactory 脚本缺少 deploy_artifactory 函数"

    def test_harbor_script_has_function(self):
        """验证 Harbor 脚本包含 deploy_harbor 函数"""
        script_path = "/home/zs/DeployAgent/deploy/deploy_harbor/deploy_harbor.sh"
        with open(script_path, 'r') as f:
            content = f.read()
        assert "deploy_harbor()" in content, "Harbor 脚本缺少 deploy_harbor 函数"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
