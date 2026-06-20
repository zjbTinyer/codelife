# 3.2 — 流水线与工作流设计

## 1. Pipeline 设计原则

```
好的 Pipeline 设计:

1. 声明式 > 脚本式
   ✅ 描述部署目标
   ❌ 编写部署步骤脚本

2. 幂等性
   同样的 Pipeline 运行两次，结果一致

3. 可回滚
   任何部署都能一键回到上一个正常工作版本

4. 渐进式发布
   小范围 → 验证 → 扩大 → 全量

5. 审批在关键节点
   不是所有步骤都要审批，只在关键决策点引入
```

## 2. Pipeline 模板化

### 2.1 Pipeline Template

```yaml
# pipeline-templates/microservice-deploy.yaml
# 微服务部署的通用模板 — 所有微服务复用
template:
  name: "Microservice Deploy Template"
  type: Pipeline
  spec:
    variables:
      - name: serviceName
        type: String
      - name: artifactTag
        type: String
      - name: deployEnv
        type: String

    stages:
      - stage:
          name: "Deploy to <+stage.variables.deployEnv>"
          type: CD
          spec:
            service:
              serviceRef: <+pipeline.variables.serviceName>
            environment:
              environmentRef: <+pipeline.variables.deployEnv>
            execution:
              steps:
                # 每个服务都可以覆盖这些步骤
```

### 2.2 使用模板

```yaml
# 具体服务的 Pipeline（引用模板）
pipeline:
  name: "Order Service CD"
  identifier: order_service_cd
  template:
    templateRef: microservice_deploy_template
    versionLabel: "1.0"
    templateInputs:
      variables:
        serviceName: order_service
        artifactTag: "<+trigger.artifactTag>"
        deployEnv: "<+pipeline.variables.env>"
```

## 3. 多环境流水线

```
开发 → 测试 → 预发布 → 生产

┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│   Dev    │→ │  Staging │→ │ Pre-Prod │→ │   Prod   │
│  自动部署 │  │  自动部署 │  │  需审批  │  │ 需双重审批│
│          │  │ +自动化测试│  │ +性能测试│  │ +金丝雀  │
└──────────┘  └──────────┘  └──────────┘  └──────────┘
```

### 多环境配置

```yaml
pipeline:
  name: "Order Service Multi-Env"
  identifier: order_service_multi_env

  stages:
    # Stage 1: 开发环境（自动）
    - stage:
        name: "Deploy to Dev"
        type: CD
        spec:
          environment:
            environmentRef: dev
          execution:
            steps:
              - step:
                  type: K8sRollingDeploy
                  name: "Deploy"

    # Stage 2: 预发布环境
    - stage:
        name: "Deploy to Staging"
        type: CD
        spec:
          environment:
            environmentRef: staging
          execution:
            steps:
              - step:
                  type: K8sRollingDeploy
                  name: "Deploy"
              # 自动化验证
              - step:
                  type: HttpStep
                  name: "Smoke Test"
                  spec:
                    url: https://staging-api.example.com/health
                    method: GET
                    assertion: "response.status == 200"

    # Stage 3: 生产环境（需要审批）
    - stage:
        name: "Deploy to Production"
        type: CD
        spec:
          environment:
            environmentRef: production
          execution:
            steps:
              # 第一步：审批门禁
              - step:
                  type: Approval
                  name: "Release Approval"
                  spec:
                    approvers:
                      minimumCount: 2
                      userGroups:
                        - release-managers
                        - tech-leads

              # 第二步：金丝雀（10%）
              - step:
                  type: K8sCanaryDeploy
                  name: "Canary 10%"
                  spec:
                    instanceSelection:
                      count: 10%

              # 第三步：验证（观察5分钟）
              - step:
                  type: HttpStep
                  name: "Verify Canary"
                  spec:
                    url: https://api.example.com/health
                    timeout: 5m
                    assertion: |
                      response.status == 200
                      && metrics.errorRate10m < 0.01

              # 第四步：全量部署
              - step:
                  type: K8sCanaryDeploy
                  name: "Rollout 100%"
                  spec:
                    instanceSelection:
                      count: 100%
```

## 4. 条件执行与动态流程

### 4.1 条件 Stage

```yaml
# 只在特定条件下执行 Stage
stages:
  - stage:
      name: "Performance Test"
      description: "仅在 Master/main 分支合并时运行性能测试"
      when:
        type: PipelineStatus
        pipelineStatus: Success
        condition: |
          <+trigger.sourceBranch> == "main"
          || <+pipeline.variables.runPerfTest> == "true"

  - stage:
      name: "Notify Slack"
      when:
        type: DeploymentStatus
        status: Failed
      # 只在部署失败时通知
```

### 4.2 动态并行

```yaml
# 并行部署多个服务
pipeline:
  stages:
    - stage:
        name: "Parallel Service Deploy"
        type: CD
        spec:
          execution:
            steps:
              - parallel:
                  - step:
                      type: K8sRollingDeploy
                      name: "Deploy Service A"
                      spec:
                        serviceRef: service_a
                  - step:
                      type: K8sRollingDeploy
                      name: "Deploy Service B"
                      spec:
                        serviceRef: service_b
                  - step:
                      type: K8sRollingDeploy
                      name: "Deploy Service C"
                      spec:
                        serviceRef: service_c
```

## 5. 审批流设计

```yaml
# 多层审批示例
approvalStages:
  # 第一层：QA 确认
  - stage:
      name: "QA Approval"
      type: Approval
      spec:
        approvalMessage: "功能测试是否通过？"
        approvers:
          userGroups: ["qa-team"]
          minimumCount: 1

  # 第二层：安全审查（生产环境特有）
  - stage:
      name: "Security Review"
      type: Approval
      when:
        condition: "<+env.type> == 'Production'"
      spec:
        approvalMessage: "安全审查是否通过？请附上审查记录链接。"
        approvers:
          userGroups: ["security-team"]
          minimumCount: 1

  # 第三层：最终放行
  - stage:
      name: "Final Release Approval"
      type: Approval
      spec:
        approvalMessage: "确认发布到生产环境。请确认：\n1. 回滚方案已准备\n2. 监控告警已设置\n3. 值班人员已就位"
        approvers:
          userGroups: ["release-managers"]
          minimumCount: 2
```

## 6. 失败处理与回滚

### 6.1 自动回滚策略

```yaml
stage:
  name: "Production Deploy"
  type: CD
  spec:
    execution:
      # 定义回滚步骤
      rollbackSteps:
        - step:
            type: K8sRollingRollback
            name: "Auto Rollback"
            spec:
              timeout: 5m

      steps:
        - step:
            type: K8sRollingDeploy
            name: "Deploy New Version"

        - step:
            type: HttpStep
            name: "Health Check"
            spec:
              url: https://api.example.com/health
              timeout: 3m

        # 如果此步骤失败 → 自动触发 rollbackSteps
        - step:
            type: HttpStep
            name: "Business Verification"
            spec:
              url: https://api.example.com/api/orders/count
              assertion: "response.body.count > 0"
              failureStrategies:
                - onFailure:
                    action:
                      type: StageRollback  # 触发回滚
```

### 6.2 失败策略矩阵

```yaml
failureStrategies:
  # 忽略（非关键步骤）
  - onFailure:
      errors: [AuthenticationError]
      action:
        type: Ignore

  # 重试
  - onFailure:
      errors: [TimeoutError, ConnectionError]
      action:
        type: Retry
        spec:
          retryCount: 3
          retryIntervals: [30s, 1m, 2m]

  # 标记为成功（降级）
  - onFailure:
      errors: [VerificationWarning]
      action:
        type: MarkAsSuccess

  # 中断 Pipeline
  - onFailure:
      errors: [AllErrors]
      action:
        type: Abort

  # 触发回滚
  - onFailure:
      errors: [DeploymentError, VerificationError]
      action:
        type: StageRollback
```

## 7. AI Agent 部署 Pipeline（实践案例）

```yaml
pipeline:
  name: "AI Agent Service Deployment"
  identifier: agent_service_deploy

  variables:
    - name: agentVersion
      type: String
      value: "<+trigger.tag>"
    - name: canaryPercentage
      type: Number
      value: 10

  stages:
    # 1. 评估测试（Agent 特有）
    - stage:
        name: "Agent Evaluation"
        type: CI
        spec:
          execution:
            steps:
              - step:
                  type: Run
                  name: "Run Eval Suite"
                  spec:
                    image: python:3.11
                    command: |
                      pip install -r requirements.txt
                      python -m evals.run --mode release-blocker
                      # 如果评估通过率 < 95%，标记失败
                  failureStrategies:
                    - onFailure:
                        action:
                          type: Abort

    # 2. 部署到沙箱环境（Agent 特有）
    - stage:
        name: "Deploy to Sandbox"
        type: CD
        spec:
          environment:
            environmentRef: agent_sandbox
          execution:
            steps:
              - step:
                  type: K8sRollingDeploy
                  name: "Deploy Agent Sandbox"
              - step:
                  type: Run
                  name: "Warm Up Agent"
                  spec:
                    command: |
                      # 预热：发送几个测试请求让模型缓存就绪
                      curl -X POST https://sandbox-agent.example.com/warmup

    # 3. 安全红队测试（Agent 特有）
    - stage:
        name: "Security Red Team"
        type: CI
        spec:
          execution:
            steps:
              - step:
                  type: Run
                  name: "Run Red Team Tests"
                  spec:
                    command: |
                      python -m security.red_team --agent-url https://sandbox-agent.example.com
                      # 安全评分必须 > 0.9
                  failureStrategies:
                    - onFailure:
                        action:
                          type: Abort

    # 4. 生产环境金丝雀
    - stage:
        name: "Production Canary Deploy"
        type: CD
        spec:
          environment:
            environmentRef: production
          execution:
            rollbackSteps:
              - step:
                  type: K8sRollingRollback
                  name: "Rollback Agent"
            steps:
              # 审批
              - step:
                  type: Approval
                  name: "Deploy Agent to Production"
                  spec:
                    approvers:
                      minimumCount: 2
                      userGroups: ["ai-team-leads"]

              # 金丝雀部署
              - step:
                  type: K8sCanaryDeploy
                  name: "Canary Agent 10%"
                  spec:
                    instanceSelection:
                      count: <+pipeline.variables.canaryPercentage>

              # Agent 特有监控验证
              - step:
                  type: HttpStep
                  name: "Verify Agent Quality"
                  spec:
                    timeout: 15m
                    url: https://monitoring.internal/api/eval/agent
                    assertion: |
                      response.body.canary.avg_quality > 0.9
                      && response.body.canary.error_rate < 0.05
                      && response.body.canary.avg_cost < 0.01

              # 全量
              - step:
                  type: K8sCanaryDeploy
                  name: "Full Rollout"
                  spec:
                    instanceSelection:
                      count: 100%
```

## 8. 总结

```
Pipeline 设计最佳实践:

1. 模板化: 提取通用模式为模板，减少重复配置
2. 环境递进: Dev → Staging → Canary → Prod
3. 门禁设计: 每个环境之间设置合适的审批和数据验证
4. 自动回滚: 失败时有明确的回滚路径
5. AI 系统特别关注:
   - 部署前先跑评估测试
   - 金丝雀阶段观察 Agent 质量指标
   - 安全测试是 CI/CD 的一环，不是事后检查

Java 类比:
  Pipeline Template    = 抽象类 / 泛型
  Stage                = 方法
  Step                 = 语句
  Failure Strategy     = try-catch / @ExceptionHandler
  Rollback             = @Transactional(rollbackFor=Exception)
```
