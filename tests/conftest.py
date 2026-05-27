"""
DevOpsAgent 部署脚本测试配置
"""
import os
import sys
import pytest

# 添加项目路径
sys.path.insert(0, '/home/zs/DeployAgent/deploy')

@pytest.fixture(scope="session")
def project_root():
    """项目根目录"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

@pytest.fixture(scope="session")
def mock_env():
    """模拟环境变量"""
    original_env = os.environ.copy()
    os.environ["SKIP_DOCKER_CHECK"] = "true"
    os.environ["SKIP_PORT_CHECK"] = "true"
    yield
    os.environ.clear()
    os.environ.update(original_env)

@pytest.fixture
def capsys(capsys):
    """捕获标准输出/错误"""
    return capsys