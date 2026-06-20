# 🚀 Harness CI/CD 平台

> 现代化的持续交付平台 —— 声明式部署、内置金丝雀、AI 驱动运维

## 模块定位

这个模块聚焦于 **Harness.io 持续交付平台**的工程实践。它让你理解一个现代化的 CD 平台是如何设计的，以及如何用它将 AI Agent 安全地部署到生产环境。

注意：这个 Harness 是 **Harness.io（CI/CD 公司）**，不同于 Claude Code 中的 Harness 层。

## 为什么需要这个模块？

```
传统 CI/CD:
  Jenkins 写 Groovy 脚本 → 维护噩梦
  手动写部署脚本 → 每次上线都在赌

Harness CD:
  声明式 YAML → 描述目标，平台执行
  内置金丝雀/蓝绿 → 一键切换，自动回滚
  AI 异常检测 → 智能判断部署是否健康
```

## 📚 文档列表

| # | 文档 | 核心主题 | 预计时间 |
|---|------|---------|----------|
| 01 | [平台概览](./01-platform-overview.md) | 架构设计、核心概念、与 Jenkins/GitLab 对比 | 1.5h |
| 02 | [流水线与工作流](./02-pipelines-and-workflows.md) | Pipeline 模板化、多环境、审批流、AI Agent 部署实践 | 2h |
| 03 | [部署策略](./03-deployment-strategies.md) | 滚动/蓝绿/金丝雀/影子部署、Feature Flags、AI Agent 金丝雀指标 | 2h |

## 🗺️ 学习路线

```
推荐阅读顺序:

01 平台概览 ← 先建立对 Harness 的整体认知
    ↓
02 流水线与工作流 ← 理解 Pipeline 怎么设计
    ↓
03 部署策略 ← 深入各种部署方式的细节和选择
```

## 🔗 与其他模块的关系

```
harness-cicd/ (本模块)
  ├── 负责把 AI 应用安全地交付到生产环境
  │
  ├── 与 ai-harness/ 的关系：
  │   ai-harness 提供评估和测试能力
  │   本模块把这些评估作为 Pipeline 的门禁
  │   评估通过 → 金丝雀部署 → 验证 → 全量
  │
  └── 与 claude-code-harness/ 的关系：
      claude-code-harness 的配置管理思想（分层、权限）
      可以类比到 Harness 的 Pipeline 模板和 RBAC
```

## 🎯 学完这个模块你会

- ✅ 理解 Harness CD 平台的架构和核心概念
- ✅ 能设计多环境、带审批的 CI/CD Pipeline
- ✅ 掌握金丝雀、蓝绿、滚动、影子部署的区别和选择
- ✅ 能为 AI Agent 设计专属的部署策略
- ✅ 能将 Harness 的思想映射到其他 CI/CD 工具

## 🛠️ 涉及的技术

- **Harness Platform**: SaaS 控制平面 + 自托管 Delegate
- **Kubernetes**: 主要的部署目标（也支持 ECS/VM/Lambda）
- **YAML**: Pipeline 和服务定义
- **监控集成**: Datadog / Prometheus / New Relic

## 💡 关键设计思想

```
1. 声明式 > 脚本式 — 描述"要什么"而非"怎么做"
2. 部署策略内置 — 金丝雀不是脚本，是配置
3. 治理优先 — RBAC + 审批流 + OPA 策略，安全不缺位
4. AI 驱动 — 自动异常检测、智能回滚、部署验证
5. 模板化 — 提取共性为模板，减少重复配置
```

---

**模块入口**：[01-平台概览](./01-platform-overview.md)

**返回总览**：[Harness Engineering 学习指南](../README.md)
