#!/usr/bin/env python3
"""
测试 Artifactory 部署完成后的打印信息
"""
import subprocess
import sys

def test_artifactory_print_summary():
    """测试 print_summary 函数中 Artifactory 部分"""
    print("=" * 70)
    print("测试: Artifactory 部署完成打印信息")
    print("=" * 70)
    
    deploy_all_path = "/home/zs/DeployAgent/deploy/deploy_all.py"
    
    try:
        with open(deploy_all_path, 'r') as f:
            content = f.read()
        
        # 检查是否包含 Artifactory 打印代码
        if "【JFrog Artifactory 管理员登录】" in content:
            print("✓ 已添加 Artifactory 管理员登录信息打印")
        else:
            print("✗ 未找到 Artifactory 管理员登录信息打印")
            return False
        
        if "用户名: admin" in content and "密码:   password" in content:
            print("✓ Artifactory 默认登录凭证已配置")
        else:
            print("✗ Artifactory 默认登录凭证配置不完整")
            return False
        
        if "访问地址: https://" in content and "/artifactory/webapp/" in content:
            print("✓ Artifactory 访问地址已配置")
        else:
            print("✗ Artifactory 访问地址配置不完整")
            return False
        
        if "首次登录后请立即修改密码" in content:
            print("✓ Artifactory 安全提示已添加")
        else:
            print("✗ Artifactory 安全提示缺失")
            return False
        
        return True
        
    except Exception as e:
        print(f"✗ 读取配置文件失败: {e}")
        return False

if __name__ == "__main__":
    print("\n" + "=" * 70)
    print("Artifactory 打印信息测试")
    print("=" * 70)
    
    result = test_artifactory_print_summary()
    
    print("\n" + "=" * 70)
    if result:
        print("✓ 所有测试通过!")
        print("=" * 70)
        print("\n部署 Artifactory 后将显示:")
        print("""
【JFrog Artifactory 管理员登录】
  用户名: admin
  密码:   password
  访问地址: https://<IP>:<PORT>/artifactory/webapp/
  提示: 首次登录后请立即修改密码
""")
        sys.exit(0)
    else:
        print("✗ 部分测试失败")
        sys.exit(1)