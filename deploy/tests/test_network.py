"""
测试端口扫描和网络功能
"""
import pytest
import os
import sys
import socket

sys.path.insert(0, '/home/zs/DeployAgent/deploy')

from deploy_all import (
    scan_ports,
    scan_docker_network,
    scan_docker_volumes,
    get_physical_ip,
    _ensure_network,
)


class TestPortScan:
    """测试端口扫描功能"""

    def test_scan_ports_function_exists(self):
        """验证函数存在"""
        assert callable(scan_ports)

    def test_scan_ports_returns_dict(self):
        """验证返回字典"""
        result = scan_ports({})
        assert isinstance(result, dict)


class TestNetworkScan:
    """测试网络扫描功能"""

    def test_scan_docker_network_function_exists(self):
        """验证函数存在"""
        assert callable(scan_docker_network)

    def test_get_physical_ip_function_exists(self):
        """验证函数存在"""
        assert callable(get_physical_ip)


class TestVolumeScan:
    """测试卷扫描功能"""

    def test_scan_docker_volumes_function_exists(self):
        """验证函数存在"""
        assert callable(scan_docker_volumes)


class TestNetworkEnsure:
    """测试网络确保功能"""

    def test_ensure_network_function_exists(self):
        """验证函数存在"""
        assert callable(_ensure_network)


class TestIPDetection:
    """测试 IP 检测功能"""

    def test_get_physical_ip_returns_string(self):
        """验证返回字符串"""
        result = get_physical_ip()
        assert isinstance(result, str)

    def test_get_physical_ip_format(self):
        """验证 IP 格式正确"""
        ip = get_physical_ip()
        if ip:
            parts = ip.split('.')
            assert len(parts) == 4, f"无效的 IP 地址格式: {ip}"
            for part in parts:
                assert part.isdigit(), f"IP 地址包含非数字: {ip}"
                assert 0 <= int(part) <= 255, f"IP 地址范围无效: {ip}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
