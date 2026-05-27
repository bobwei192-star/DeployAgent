"""
测试部署配置和常量
"""
import pytest
import os
import sys

sys.path.insert(0, '/home/zs/DeployAgent/deploy')

from deploy_all import PORT_REGISTRY, SERVICE_CONFIG, DEPLOY_MODES


class TestPortRegistry:
    """测试端口注册配置"""

    def test_port_registry_exists(self):
        """验证端口注册配置存在"""
        assert PORT_REGISTRY is not None
        assert isinstance(PORT_REGISTRY, dict)

    def test_core_services_have_ports(self):
        """验证核心服务都有端口配置"""
        core_services = ["jenkins", "gitlab", "mantisbt", "langfuse", "artifactory", "harbor"]
        for service in core_services:
            assert service in PORT_REGISTRY, f"{service} 不在端口配置中"

    def test_nginx_ports_configured(self):
        """验证 Nginx 反向代理端口配置"""
        assert "nginx" in PORT_REGISTRY
        nginx_ports = PORT_REGISTRY["nginx"]
        assert isinstance(nginx_ports, dict)
        
        expected_proxies = ["jenkins", "gitlab", "mantisbt", "langfuse", "artifactory", "harbor"]
        for proxy in expected_proxies:
            assert proxy in nginx_ports, f"Nginx 缺少 {proxy} 的端口配置"
            assert isinstance(nginx_ports[proxy], int), f"{proxy} 的端口不是整数"

    def test_port_values_are_valid(self):
        """验证端口值在有效范围内"""
        for service, ports in PORT_REGISTRY.items():
            if isinstance(ports, dict):
                for port_name, port_value in ports.items():
                    if isinstance(port_value, int):
                        assert 1 <= port_value <= 65535, \
                            f"无效端口值 {port_value} for {service}/{port_name}"


class TestServiceConfig:
    """测试服务配置"""

    def test_service_config_exists(self):
        """验证服务配置存在"""
        assert SERVICE_CONFIG is not None
        assert isinstance(SERVICE_CONFIG, dict)

    def test_all_services_have_config(self):
        """验证所有服务都有完整配置"""
        required_fields = ["deploy_script", "container"]
        
        for service, config in SERVICE_CONFIG.items():
            for field in required_fields:
                assert field in config, f"{service} 缺少 {field} 配置"
            
            # 检查部署脚本路径是否存在
            if "deploy_script" in config:
                script_path = str(config["deploy_script"])
                assert script_path.endswith(".sh"), f"{service} 的部署脚本不是 .sh 文件"

    def test_nginx_config_has_required_fields(self):
        """验证需要 Nginx 反向代理的服务配置完整"""
        for service, config in SERVICE_CONFIG.items():
            if service != "nginx":
                assert "nginx_port_key" in config, f"{service} 缺少 nginx_port_key"
                assert "backend_host" in config, f"{service} 缺少 backend_host"
                assert "backend_port" in config, f"{service} 缺少 backend_port"


class TestDeployModes:
    """测试部署模式配置"""

    def test_deploy_modes_exists(self):
        """验证部署模式配置存在"""
        assert DEPLOY_MODES is not None
        assert isinstance(DEPLOY_MODES, dict)

    def test_all_modes_have_valid_structure(self):
        """验证所有部署模式结构正确"""
        for mode_id, mode_info in DEPLOY_MODES.items():
            assert len(mode_info) == 4, f"模式 {mode_id} 结构不正确"
            mode_name, description, services, use_nginx = mode_info
            
            assert isinstance(mode_name, str), f"模式 {mode_id} 的名称不是字符串"
            assert isinstance(description, str), f"模式 {mode_id} 的描述不是字符串"
            assert isinstance(services, list), f"模式 {mode_id} 的服务列表不是列表"
            assert isinstance(use_nginx, bool), f"模式 {mode_id} 的 use_nginx 不是布尔值"

    def test_full_deploy_has_all_services(self):
        """验证完整部署包含所有服务"""
        full_mode = DEPLOY_MODES[1]
        services = full_mode[2]
        
        expected_services = ["jenkins", "gitlab", "mantisbt", "langfuse", "nginx"]
        for service in expected_services:
            assert service in services, f"完整部署缺少 {service}"

    def test_standalone_modes_have_correct_services(self):
        """验证独立部署模式服务配置正确"""
        # Jenkins 独立部署
        assert DEPLOY_MODES[3][2] == ["jenkins", "nginx"]
        # GitLab 独立部署
        assert DEPLOY_MODES[4][2] == ["gitlab", "nginx"]
        # Artifactory 独立部署
        assert DEPLOY_MODES[8][2] == ["artifactory", "nginx"]
        # Harbor 独立部署
        assert DEPLOY_MODES[9][2] == ["harbor", "nginx"]

    def test_new_services_included(self):
        """验证新增服务（Artifactory、Harbor）已加入配置"""
        assert 8 in DEPLOY_MODES, "Artifactory 部署模式未配置"
        assert 9 in DEPLOY_MODES, "Harbor 部署模式未配置"
        
        artifactory_mode = DEPLOY_MODES[8]
        harbor_mode = DEPLOY_MODES[9]
        
        assert "artifactory" in artifactory_mode[2], "Artifactory 模式缺少 artifactory 服务"
        assert "harbor" in harbor_mode[2], "Harbor 模式缺少 harbor 服务"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
