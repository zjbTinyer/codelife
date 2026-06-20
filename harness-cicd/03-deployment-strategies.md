# 3.3 — 部署策略与集成

## 1. 部署策略全景

```
┌─────────────────────────────────────────────────────────┐
│                    部署策略对比                          │
├──────────┬──────────┬──────────┬────────────┬──────────┤
│   策略    │  风险    │  成本    │  回滚速度  │ 适用场景  │
├──────────┼──────────┼──────────┼────────────┼──────────┤
│ 滚动更新  │  中      │  低      │  中        │ 普通服务  │
│ 蓝绿部署  │  低      │  高      │  快        │ 关键服务  │
│ 金丝雀    │  最低    │  中      │  最快      │ AI/Agent  │
│ 全量替换  │  高      │  最低    │  慢        │ 非生产环境 │
│ 影子部署  │  极低    │  高      │  N/A       │ 流量验证  │
└──────────┴──────────┴──────────┴────────────┴──────────┘
```

## 2. 滚动更新 (Rolling Update)

```
逐步替换旧实例 → 始终保持服务可用

时间线:
  Instance 1: [New] ← 替换
  Instance 2: [Old] [Old] [New] ← 逐个替换
  Instance 3: [Old] [Old] [Old] [New]
  Instance 4: [Old] [Old] [Old] [Old] [New]

特点:
  ✅ 零停机
  ✅ 不需要额外资源
  ❌ 新旧版本共存期间可能有问题
  ❌ 回滚慢（需要反向滚动）
```

```yaml
# Harness 滚动更新配置
step:
  type: K8sRollingDeploy
  name: "Rolling Update"
  spec:
    timeout: 10m
    # Kubernetes 原生 rolling update 策略
    # maxSurge: 25% (允许多出25%的Pod)
    # maxUnavailable: 25% (允许最多25%的Pod不可用)
```

## 3. 蓝绿部署 (Blue-Green)

```
维护两套完整环境 → 一键切换

         ┌─────────────┐
  Blue:  │ v1.0 (Active)│  ← 当前活跃
         └─────────────┘
         ┌─────────────┐
  Green: │ v2.0 (Idle)  │  ← 部署完待命
         └─────────────┘

步骤:
  1. 在 Green 上部署 v2.0
  2. 验证 Green 正常运行
  3. 切换流量: Blue → Green
  4. Blue 保留一段时间（用于回滚）

切换方式:
  - K8s Service selector: app=v1 → app=v2
  - Load Balancer 切换后端
  - DNS 切换
```

```yaml
# Harness 蓝绿部署配置
stage:
  name: "Blue-Green Deploy"
  spec:
    execution:
      steps:
        # 步骤1: 部署到非活跃环境
        - step:
            type: K8sBlueGreenDeploy
            name: "Deploy to Green"
            spec:
              timeout: 10m

        # 步骤2: 验证
        - step:
            type: HttpStep
            name: "Verify Green"
            spec:
              url: https://green-api.example.com/health
              timeout: 3m

        # 步骤3: 切换流量（可自动化或手动审批）
        - step:
            type: K8sSwapServiceSelectors
            name: "Swap Traffic to Green"
            spec:
              # 自动切换
              # 或者加 Approval 步骤做手动切换

        # 步骤4: 保留 Blue 一段时间
        - step:
            type: K8sScale
            name: "Scale Down Blue (after 1 hour)"
            spec:
              # 可以用定时任务延迟执行
```

## 4. 金丝雀部署 (Canary) ⭐ — AI Agent 推荐

```
逐步增加新版本流量 → 观察指标 → 自动决策

          v1.0 (90%) ←────────→ v2.0 (10%)
                        ↑
                  流量分配器
                        │
                  用户请求

时间线:
  0min:  v2.0 0% 流量（部署但不接收流量）
  5min:  v2.0 10% 流量（开始金丝雀）
  10min: 观察指标（错误率、延迟、业务指标）
  15min: v2.0 25% 流量（扩大）
  20min: 观察指标
  25min: v2.0 100% 流量（全量）
  ... 如果任何阶段指标异常 → 自动回滚
```

### AI Agent 的金丝雀指标

```python
# AI Agent 部署时特有的金丝雀观察指标

AGENT_CANARY_METRICS = {
    # 基础指标（所有服务通用）
    "error_rate_5m": {"threshold": 0.05, "action": "rollback"},
    "p95_latency_ms": {"threshold": 5000, "action": "rollback"},

    # Agent 特有指标
    "tool_selection_accuracy": {
        "threshold": 0.95,      # 工具选择准确率 > 95%
        "action": "rollback",
        "description": "金丝雀版本的 Agent 是否选对了工具"
    },
    "task_completion_rate": {
        "threshold": 0.90,
        "action": "pause",      # 暂停但不回滚，人工判断
        "description": "任务完成率（和 baseline 对比）"
    },
    "avg_tokens_per_request": {
        "threshold": 1.5,       # 相对 baseline 的倍数
        "action": "warn",       # 警告但不操作
        "description": "Token 消耗是否突变"
    },
    "safety_violation_rate": {
        "threshold": 0.001,     # 安全违规率 > 0.1%
        "action": "rollback",
        "description": "安全违规立即回滚"
    },
    "user_satisfaction_score": {
        "threshold": 0.8,
        "action": "pause",
        "description": "用户满意度评分"
    },
}
```

### Harness 金丝雀配置

```yaml
stage:
  name: "Canary Agent Deploy"
  spec:
    execution:
      rollbackSteps:
        - step:
            type: K8sCanaryDelete
            name: "Rollback Canary"
      steps:
        # Phase 1: 10% 金丝雀
        - step:
            type: K8sCanaryDeploy
            name: "Canary 10%"
            spec:
              instanceSelection:
                count: 10

        # Phase 2: 观察期（集成监控）
        - step:
            type: Verify
            name: "Monitor Canary"
            spec:
              type: Datadog  # 或 Prometheus/New Relic
              spec:
                monitoringService: datadog_connector
                verificationTimeout: 15m
                sensitivity: HIGH  # 敏感度
                # 自动对比 canary pod 和 baseline pod 的指标
                baseline:
                  type: LAST_SUCCESSFUL  # 对比上一次成功的部署

        # Phase 3: 25% 扩大
        - step:
            type: K8sCanaryDeploy
            name: "Canary 25%"
            spec:
              instanceSelection:
                count: 25

        # Phase 4: 再次观察
        - step:
            type: Verify
            name: "Monitor 25%"
            spec:
              verificationTimeout: 10m
              sensitivity: HIGH

        # Phase 5: 100% 全量
        - step:
            type: K8sCanaryDeploy
            name: "Full Rollout"
            spec:
              instanceSelection:
                count: 100
```

## 5. 影子部署 (Traffic Mirroring)

```
复制生产流量到新版本 → 对比结果 → 不返回给用户

用户请求 ──→ v1.0 ──→ 返回给用户
             │
             └──→ v2.0 ──→ 丢弃/只记录日志

场景:
  - 高风险变更验证（如模型升级）
  - 对比新旧 Agent 的输出质量
  - 零风险的性能测试

成本:
  需要双倍资源（但安全性最高）
```

## 6. 部署策略选择指南

```
什么场景用什么策略?

AI/LLM Agent 部署:
  推荐: 金丝雀 > 蓝绿 > 影子部署
  原因: 需要对比 Agent 行为指标，逐步验证

普通微服务:
  推荐: 滚动更新 (低风险) / 金丝雀 (高风险)
  原因: 已通过 CI 测试验证

数据库变更:
  推荐: 蓝绿 (切换快) / 滚动 (兼容性变更)
  原因: Schema 变更难以回滚

前端应用:
  推荐: 蓝绿 (切换快) / 金丝雀 (A/B 测试)
  原因: 用户体验敏感

基础设施变更:
  推荐: 蓝绿 (环境级切换)
  原因: 影响面大，需要快速回滚
```

## 7. 部署后自动验证

```yaml
# 部署完成后的自动验证步骤
stage:
  name: "Post-Deploy Verification"
  spec:
    execution:
      steps:
        # 1. 健康检查
        - step:
            type: HttpStep
            name: "Health Check"
            spec:
              url: https://api.example.com/health
              method: GET
              timeout: 2m
              retry:
                count: 10
                interval: 5s

        # 2. 冒烟测试（调用关键 API）
        - step:
            type: HttpStep
            name: "Smoke Test - Orders API"
            spec:
              url: https://api.example.com/api/orders
              method: GET
              assertion: "response.status == 200 && response.body.total > 0"
              timeout: 1m

        # 3. Agent 专用：评估验证
        - step:
            type: Run
            name: "Agent Quality Check"
            spec:
              image: python:3.11
              command: |
                python -m agent.eval_quick_check \
                  --agent-url https://agent.example.com \
                  --test-suite production_smoke \
                  --min-score 0.9

        # 4. 通知
        - step:
            type: Notification
            name: "Deploy Success Notification"
            spec:
              type: Slack
              spec:
                channel: "#deployments"
                message: |
                  ✅ {service} v{version} 部署成功
                  环境: {env}
                  耗时: {duration}
```

## 8. Feature Flags 集成

```yaml
# Harness Feature Flags 与部署策略结合

# 场景: 新 Agent Prompt 上线
# 部署新版本代码，但用 Feature Flag 控制是否启用新 Prompt

pipeline:
  stages:
    - stage:
        name: "Deploy Agent v2 with Feature Flag"
        spec:
          execution:
            steps:
              # 1. 部署新版本（新 Prompt 默认关闭）
              - step:
                  type: K8sRollingDeploy
                  name: "Deploy Agent v2"
                  spec:
                    env:
                      FF_NEW_PROMPT_ENABLED: "false"

              # 2. 验证部署成功
              - step:
                  type: HttpStep
                  name: "Verify Deploy"

              # 3. 逐步开启 Feature Flag
              - step:
                  type: FeatureFlag
                  name: "Enable New Prompt for 10%"
                  spec:
                    flag: "new_agent_prompt"
                    environment: "<+env.name>"
                    state: "on"
                    targeting:
                      rules:
                        - percentage: 10

              # 4. 观察
              - step:
                  type: Verify
                  name: "Monitor with New Prompt"
                  spec:
                    verificationTimeout: 30m

              # 5. 全量开启（自动或人工）
              - step:
                  type: FeatureFlag
                  name: "Enable New Prompt 100%"
                  spec:
                    flag: "new_agent_prompt"
                    state: "on"
                    # 100%
```

## 9. 总结

```
部署策略选择:

1. 金丝雀 — 最安全，AI Agent 的首选
   渐进式验证 + 自动回滚 + 指标驱动决策

2. 蓝绿 — 切换最快，适合快速回滚
   但需要双倍资源

3. 滚动 — 最简单，适合大部分场景
   零额外资源，但回滚慢

4. 影子 — 最保守，适合极高风险变更
   双倍资源，零用户影响

5. Feature Flags — 代码和配置分离
   最适合 Prompt/AI 行为的渐进式发布

AI Agent 部署金三角:
  Canary（流量控制）+ FF（功能控制）+ 自动验证（质量门禁）
```
