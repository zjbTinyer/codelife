# 3.1 — Harness CI/CD 平台概览

## 1. 什么是 Harness？

Harness 是一个现代化的持续交付（CD）平台，它的核心理念是**用智能自动化替代手工操作和脚本化部署**。

```
传统 CI/CD 的痛点:
  Jenkins    — 脚本即管道，维护噩梦
  GitLab CI  — 写 YAML，但缺乏部署策略
  GitHub Actions — CI 强但 CD 弱

Harness 的差异:
  - 声明式而非脚本式: 描述"要什么"而不是"怎么做"
  - 内置部署策略: 金丝雀、蓝绿、滚动开箱即用
  - AI 驱动: 自动回滚、异常检测、部署验证
  - 治理优先: RBAC、审批流、审计日志一应俱全
```

## 2. 核心架构

```
┌──────────────────────────────────────────────────────┐
│                 Harness Platform                       │
│                                                        │
│  ┌─────────────┐ ┌──────────────┐ ┌───────────────┐  │
│  │  Delegate    │ │   Manager    │ │   Delegates   │  │
│  │  (管理节点)   │ │  (控制平面)   │ │  (执行节点)    │  │
│  └─────────────┘ └──────────────┘ └───────────────┘  │
│                                                        │
│  ┌─────────────────────────────────────────────────┐  │
│  │              核心模块                            │  │
│  ├──────────────┬──────────────┬───────────────────┤  │
│  │ Pipeline     │ Deployment   │ Feature Flags     │  │
│  │ (流水线)     │ Strategies   │ & Chaos           │  │
│  │              │ (部署策略)    │ (特性开关+混沌)   │  │
│  └──────────────┴──────────────┴───────────────────┘  │
└──────────────────────────────────────────────────────┘
```

### 核心概念

| 概念 | 说明 | Jenkins 类比 |
|------|------|-------------|
| **Project** | 项目的顶层组织单元 | Jenkins Folder |
| **Pipeline** | 定义构建、部署的完整流程 | Jenkins Pipeline |
| **Stage** | Pipeline 中的阶段 | Pipeline Stage |
| **Step** | Stage 中的具体步骤 | Pipeline Step |
| **Service** | 被部署的微服务 | - |
| **Environment** | 部署目标环境 (dev/staging/prod) | - |
| **Infrastructure** | 基础设施定义 (K8s/ECS/VM) | - |
| **Delegate** | 在目标环境中执行的代理 | Jenkins Agent |
| **Connector** | 连接外部系统 (Git/Artifactory/K8s) | Plugin |

## 3. Harness vs Jenkins vs GitLab CI

```
┌─────────────┬──────────────┬──────────────┬──────────────┐
│    维度      │   Harness     │   Jenkins     │  GitLab CI   │
├─────────────┼──────────────┼──────────────┼──────────────┤
│ 定位         │ CD (专注部署) │ CI/CD 通用    │ CI/CD 集成    │
│ 配置方式     │ YAML + UI     │ Groovy/UI     │ YAML         │
│ 部署策略     │ 内置金丝雀等  │ 需插件/脚本   │ 需手动实现   │
│ 回滚         │ 一键/自动     │ 脚本实现      │ 手动         │
│ AI/ML 能力   │ 内置异常检测  │ 无            │ 无           │
│ 治理         │ RBAC+审批流   │ 插件实现      │ 基本权限     │
│ 学习曲线     │ 中等          │ 陡峭          │ 平缓         │
│ 适用场景     │ 复杂CD需求    │ 高度定制化    │ 中小团队     │
└─────────────┴──────────────┴──────────────┴──────────────┘
```

## 4. Pipeline 基础结构

```yaml
# Harness Pipeline YAML 示例
pipeline:
  name: "order-service-cd"
  identifier: order_service_cd
  projectIdentifier: ecommerce
  orgIdentifier: default

  # === 构建阶段（CI部分，通常对接CI系统） ===
  stages:
    - stage:
        name: "Build"
        type: CI
        spec:
          execution:
            steps:
              - step:
                  type: Run
                  name: "Maven Build"
                  spec:
                    connectorRef: maven_central
                    image: maven:3.8-openjdk-8
                    command: mvn clean package -DskipTests

    # === 部署到开发环境 ===
    - stage:
        name: "Deploy to Dev"
        type: CD
        spec:
          service:
            serviceRef: order_service
          environment:
            environmentRef: dev
            infrastructureDefinition:
              type: Kubernetes
              spec:
                connectorRef: dev_k8s_cluster
                namespace: dev
          execution:
            steps:
              - step:
                  type: K8sRollingDeploy
                  name: "Rolling Deploy"
                  spec:
                    timeout: 10m

    # === 部署到生产（带审批和策略） ===
    - stage:
        name: "Deploy to Production"
        type: CD
        spec:
          service:
            serviceRef: order_service
          environment:
            environmentRef: production
          execution:
            rollbackSteps:
              - step:
                  type: K8sRollingRollback
                  name: "Rollback"
            steps:
              # 审批步骤
              - step:
                  type: Approval
                  name: "Production Approval"
                  spec:
                    approvalMessage: "确认部署到生产环境？"
                    approvers:
                      userGroups: ["release-managers"]
                      minimumCount: 2

              # 金丝雀部署
              - step:
                  type: K8sCanaryDeploy
                  name: "Canary Deploy"
                  spec:
                    instanceSelection:
                      count: 10%  # 先部署10%
                    timeout: 15m

              # 金丝雀验证
              - step:
                  type: K8sCanaryDelete
                  name: "Canary Cleanup"
                  spec: {}
```

## 5. Harness Delegate（核心组件）

```
Delegate 是 Harness 的"执行代理"，运行在你的基础设施中:

你的 VPC/K8s 集群
┌─────────────────────────────────┐
│  ┌───────────────────────────┐  │
│  │    Harness Delegate        │  │  ← 轻量级 JVM 进程
│  │    (作为 Pod/容器运行)     │  │
│  │                            │  │
│  │  - 接收 Harness Manager 指令│  │
│  │  - 在你的环境中执行部署    │  │
│  │  - 回传执行状态和日志     │  │
│  │  - 不需要暴露端口到公网   │  │
│  └───────────────────────────┘  │
│            ↕ (HTTPS outbound)    │
└─────────────────────────────────┘
              ↕
┌─────────────────────────────────┐
│      Harness Manager (SaaS)      │
│      所有控制逻辑在云端          │
└─────────────────────────────────┘

优势:
  ✅ Delegate 主动连接 Manager（不需要公网入口）
  ✅ 所有敏感凭据在 Delegate 端，不经过 Manager
  ✅ 轻量级（< 200MB），支持水平扩展
```

## 6. 关键概念：Service + Environment + Infrastructure

```yaml
# Service: 定义"要部署什么"
service:
  name: "Order Service"
  identifier: order_service
  serviceDefinition:
    type: Kubernetes
    spec:
      manifests:
        - manifest:
            type: Values  # Helm values
            spec:
              store:
                type: Git
                spec:
                  connectorRef: git_repo
                  branch: main
                  paths:
                    - helm/order-service/values.yaml
      artifacts:
        primary:
          type: Docker
          spec:
            connectorRef: docker_hub
            imagePath: mycompany/order-service
            tag: "<+artifacts.primary.tag>"

# Environment: 定义"部署到哪里"
environment:
  name: "Production"
  identifier: production
  type: Production  # 标记为生产环境 → 触发额外保护

# Infrastructure Definition: 定义"具体怎么部署"
infrastructure:
  type: KubernetesDirect
  spec:
    connectorRef: prod_k8s_cluster
    namespace: production
    releaseName: order-service-<+env.name>
```

## 7. Harness 的治理能力

```yaml
# RBAC (基于角色的访问控制)
roleBindings:
  - name: "Developer"
    permissions:
      - "core_pipeline_view"
      - "core_pipeline_execute"
    resourceGroups:
      - resourceGroupIdentifier: "dev_environments"

  - name: "Release Manager"
    permissions:
      - "core_pipeline_execute"
      - "core_deployment_approve"
      - "core_secret_view"
    resourceGroups:
      - resourceGroupIdentifier: "all_environments"

# Pipeline Governance (流水线治理规则)
governanceRule:
  name: "Production Deploy Must Have Approval"
  enforcement: "REQUIRED"
  condition: "<+env.type> == 'Production'"
  action: "REQUIRE_APPROVAL"
  approvers: ["release-managers"]

# OPA Policy (Open Policy Agent 集成)
opaPolicy:
  name: "Block non-HTTPS endpoints"
  rego: |
    package harness
    deny[msg] {
      input.service.endpoint.protocol != "https"
      msg := "生产环境服务必须使用 HTTPS"
    }
```

## 8. 与 Agent/LLM 系统的结合点

```
AI Agent 部署场景中的 Harness 应用:

1. Agent 灰度发布
   金丝雀部署 Agent 新版本 → 自动验证 → 全量或回滚

2. 多 Agent 系统编排
   用 Pipeline Stage 管理不同 Agent 的部署顺序

3. 自动化回滚
   Agent 错误率上升 → Harness 自动检测 → 触发回滚

4. 审批集成
   Agent 的 System Prompt 修改 → 走 Harness Approval → 部署

5. 混沌工程
   Harness Chaos Engineering → 测试 Agent 的可靠性
```

## 9. 总结

```
Harness CD 平台核心价值:

1. 声明式 CD: 描述目标状态，平台负责达到
2. 部署策略内置: 金丝雀、蓝绿、滚动，不需要自己写脚本
3. 安全治理: RBAC + 审批流 + OPA 策略
4. AI 驱动运维: 自动异常检测、智能回滚
5. 混合云: 一个平台管理所有环境的部署

Java 类比:
  Harness Delegate = Jenkins Agent (但更轻量、更安全)
  Pipeline        = Jenkins Pipeline (但声明式，非脚本式)
  Service/Env     = Spring Cloud 中的服务与环境抽象
  Governance      = Spring Security + OPA
```
