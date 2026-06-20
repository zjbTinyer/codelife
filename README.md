# 🛠️ Harness Engineering 学习指南

> 构建可靠的 AI 工程系统：评估框架 · 安全护栏 · CI/CD 平台 · 运行时机制

---

## 什么是 Harness Engineering？

**Harness** 在英语中意为"马具、安全带、控制装置"。在工程领域，它引申为**让强大但不可控的力量变得可控的系统**。

在 AI/LLM 时代，Harness Engineering 涵盖三个层次：

```
┌─────────────────────────────────────────────────────────────┐
│                      Harness Engineering                     │
│                                                               │
│  ┌─────────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │   AI 评估与控制   │  │ Claude Code   │  │  Harness CI/CD  │  │
│  │   Engineering    │  │   Harness     │  │   Platform      │  │
│  │                  │  │               │  │                 │  │
│  │ 让AI输出可控     │  │ 让AI工具可管  │  │ 让交付可自动化  │  │
│  │                  │  │               │  │                 │  │
│  │ 📁 ai-harness/   │  │ 📁 claude-    │  │ 📁 harness-     │  │
│  │                  │  │ code-harness/ │  │ cicd/           │  │
│  └─────────────────┘  └──────────────┘  └────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 三个层次的关系

| 层次 | 目录 | 解决的问题 |
|------|------|-----------|
| **AI 评估与控制** | [ai-harness/](./ai-harness/) | 作为开发者，如何评估、防护、监控 AI 系统的质量 |
| **Claude Code 运行时** | [claude-code-harness/](./claude-code-harness/) | Claude Code 内部如何安全地管理工具调用和权限 |
| **CI/CD 平台** | [harness-cicd/](./harness-cicd/) | Harness.io 平台如何自动化软件交付流程 |

---

## 📂 目录结构

```
codelife/
├── README.md                          # 👈 你在这里（总入口）
│
├── ai-harness/                        # 模块一：AI 评估与控制工程
│   ├── README.md                      #    模块入口
│   ├── 01-evaluation-frameworks.md    #    评估框架
│   ├── 02-guardrails-and-safety.md    #    护栏与安全
│   ├── 03-reliability-engineering.md  #    可靠性工程
│   ├── 04-prompt-infrastructure.md    #    Prompt 基础设施
│   └── 05-observability-and-monitoring.md  # 可观测性
│
├── claude-code-harness/               # 模块二：Claude Code 运行时
│   ├── README.md                      #    模块入口
│   ├── 01-tool-runtime.md             #    工具运行时
│   ├── 02-hooks-system.md             #    Hooks 系统
│   ├── 03-permissions-and-security.md #    权限与安全
│   └── 04-settings-and-configuration.md    # 配置体系
│
├── harness-cicd/                      # 模块三：Harness CI/CD 平台
│   ├── README.md                      #    模块入口
│   ├── 01-platform-overview.md        #    平台概览
│   ├── 02-pipelines-and-workflows.md  #    流水线与工作流
│   └── 03-deployment-strategies.md    #    部署策略
│
└── agent-learning/                    # 前置学习：LLM Agent 开发
    └── README.md                      #    详见 agent-learning 目录
```

---

## 🗺️ 学习路线（3 周）

### 第 1 周：AI 评估与控制工程 → [📁 ai-harness/](./ai-harness/)

```
Day 1-2: 01 评估框架       → 建立"如何衡量 AI 质量"的思维
Day 3-4: 02 护栏与安全      → 理解 AI 系统的安全边界
Day 5:   03 可靠性工程      → 熔断、重试、降级模式
Day 6:   04 Prompt 基础设施 → 工程化 Prompt 管理
Day 7:   05 可观测性        → 追踪、指标、日志
```

**目标**：能独立设计 AI 应用的评估、防护、监控体系

### 第 2 周：Claude Code Harness → [📁 claude-code-harness/](./claude-code-harness/)

```
Day 1-2: 01 工具运行时      → 理解工具调用全链路
Day 3-4: 02 Hooks 系统      → 事件拦截和自定义脚本
Day 5:   03 权限与安全      → 多层权限模型设计
Day 6-7: 04 配置体系        → 配置分层 + 动手实践
```

**目标**：理解 Claude Code 的安全设计，能写自定义 Hook、配置多环境权限

### 第 3 周：Harness CI/CD 平台 → [📁 harness-cicd/](./harness-cicd/)

```
Day 1-2: 01 平台概览        → 理解现代 CD 平台设计
Day 3-4: 02 流水线与工作流   → Pipeline 设计、审批、模板化
Day 5-7: 03 部署策略        → 金丝雀、蓝绿、滚动 + 综合实践
```

**目标**：能设计 AI Agent 专属的 CI/CD Pipeline

---

## 🎯 前置知识

| 知识点 | 参考 |
|--------|------|
| LLM Agent 开发基础 | [agent-learning/](../agent-learning/README.md) |
| 后端开发经验 | Java (Spring Boot) / Python (FastAPI) |
| CI/CD 基本概念 | Jenkins / GitLab CI / GitHub Actions |

---

## 🏗️ 三个模块如何协同

```
你写的 AI Agent 应用
      │
      ├── 开发阶段
      │   └── ai-harness/ 提供质量和安全保障
      │       ├── 评估框架 → 跑测试集
      │       ├── 护栏安全 → Prompt Injection 防护
      │       └── 可观测性 → 追踪每个请求
      │
      ├── 配置阶段
      │   └── claude-code-harness/ 管理运行时
      │       ├── 权限配置 → 谁可以用什么工具
      │       └── Hooks → 自动格式化、安全扫描
      │
      └── 交付阶段
          └── harness-cicd/ 安全部署到生产
              ├── Pipeline → 构建 → 测试 → 审批
              └── 金丝雀部署 → 观察指标 → 全量/回滚
```

---

## 🚀 快速开始

**如果你只有 2 小时**，读这三篇：

| 顺序 | 文档 | 为什么 |
|------|------|--------|
| 1 | [评估框架](./ai-harness/01-evaluation-frameworks.md) | 建立"如何衡量 AI 质量"的核心认知 |
| 2 | [工具运行时](./claude-code-harness/01-tool-runtime.md) | 理解 Claude Code 安全机制的核心 |
| 3 | [平台概览](./harness-cicd/01-platform-overview.md) | 快速理解现代 CD 平台 |

**如果你想按模块深入**，从各模块的 README 入口开始：

- → [🤖 AI 评估与控制工程](./ai-harness/README.md)
- → [⚙️ Claude Code Harness 运行时](./claude-code-harness/README.md)
- → [🚀 Harness CI/CD 平台](./harness-cicd/README.md)

---

> 💡 **核心理念**：Harness Engineering 不是某个具体的技术，而是一种工程思维方式——**把不可控变得可控，把不确定变得确定**。
