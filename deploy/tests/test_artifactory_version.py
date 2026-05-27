#!/usr/bin/env python3
"""
测试 Artifactory 版本配置
"""
import re

def test_artifactory_version_config():
    """验证 Artifactory 版本配置"""
    print("=" * 70)
    print("测试: Artifactory 版本配置验证")
    print("=" * 70)
    
    deploy_artifactory_path = "/home/zs/DeployAgent/deploy/deploy_artifactory/deploy_artifactory.sh"
    
    try:
        with open(deploy_artifactory_path, 'r') as f:
            content = f.read()
        
        # 检查镜像名称
        if 'IMAGE_NAME="releases-docker.jfrog.io/jfrog/artifactory-oss"' in content:
            print("✓ 镜像名称已更新为官方源")
        else:
            print("✗ 镜像名称未正确配置")
            return False
        
        # 检查版本标签
        if 'TAG="latest"' in content:
            print("✓ 版本标签已更新为 latest")
        else:
            print("✗ 版本标签未正确配置")
            return False
        
        # 检查官方镜像源优先级
        if 'releases-docker.jfrog.io/jfrog/artifactory-oss:latest' in content:
            print("✓ 官方镜像源已配置")
        else:
            print("✗ 官方镜像源未配置")
            return False
        
        # 检查镜像拉取顺序
        official_section = content.find('第1步: 尝试 JFrog 官方镜像源')
        third_party_section = content.find('第2步: 尝试第三方搬运镜像')
        
        if official_section > 0 and third_party_section > 0 and official_section < third_party_section:
            print("✓ 官方镜像源优先级正确（第1步）")
        else:
            print("✗ 镜像源优先级配置错误")
            return False
        
        return True
        
    except Exception as e:
        print(f"✗ 读取配置文件失败: {e}")
        return False

if __name__ == "__main__":
    print("\n" + "=" * 70)
    print("Artifactory 版本配置测试")
    print("=" * 70)
    
    result = test_artifactory_version_config()
    
    print("\n" + "=" * 70)
    if result:
        print("✓ 所有测试通过!")
        print("=" * 70)
        print("\n配置总结:")
        print("  镜像源: releases-docker.jfrog.io/jfrog/artifactory-oss:latest")
        print("  版本: latest (最新版本)")
        print("  优先级: 官方镜像源 > 第三方搬运镜像")
        print("\n版本评价:")
        print("  latest 标签指向最新版本，始终使用最新功能和安全修复")
        print("  比固定版本 7.77.3 更新，但可能包含未测试的新特性")
        print("\n建议:")
        print("  生产环境建议使用固定版本（如 7.77.3）以确保稳定性")
        print("  测试环境可以使用 latest 版本以获取最新功能")
        print("\n命令:")
        print("  docker pull releases-docker.jfrog.io/jfrog/artifactory-oss:latest")
        exit(0)
    else:
        print("✗ 部分测试失败")
        exit(1)