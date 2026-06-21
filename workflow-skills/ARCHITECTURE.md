# 🏭 ARCHITECTURE.md — Workflow Skills 架构设计

## 为什么要有这套 Skills？

```
现状:
  开发功能 → 手动跑测试 → 手动看覆盖率 → 提 MR
  → Jenkins 跑扫描 → 手动看 Sonar/NexusIQ/Cyberflow 报告
  → 逐个手动修复 → 再跑扫描 → 部署
  → 手动连 PostgreSQL 查问题 → 改代码 → 循环

  痛点: 太多手动步骤，每个都耗时且容易遗漏

目标:
  开发功能 → /pre-mr-gate → /coverage-hunt
  → 提 MR → Jenkins Pipeline
  → /scan-triage → AI 辅助修复
  → /deploy-guard → /db-inspect
  → 问题闭环

  效果: 自动化重复步骤，AI 辅助分析和修复
```

## 架构全景

```
┌──────────────────────────────────────────────────────────────┐
│                    Claude Code (交互层)                        │
│                                                               │
│  /pre-mr-gate  /scan-triage  /coverage-hunt  /deploy-guard   │
│  /db-inspect   /jenkins-debug                                 │
│                                                               │
│  每个 Skill 通过 工具(Bash/Grep/Read/Write) 执行实际操作      │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────┴───────────────────────────────────┐
│                    Skill 执行层                                │
│                                                               │
│  ┌────────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐ │
│  │ Shell 脚本  │  │ Python   │  │ Maven    │  │ psql       │ │
│  │ 门禁/部署   │  │ 分析/分类 │  │ 编译/测试 │  │ 数据库诊断 │ │
│  └────────────┘  └──────────┘  └──────────┘  └────────────┘ │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────┴───────────────────────────────────┐
│                    外部系统                                    │
│                                                               │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐  │
│  │  Maven   │ │  Sonar   │ │  GCP     │ │ Jenkins        │  │
│  │  本地构建 │ │  NexusIQ │ │PostgreSQL│ │ Pipeline       │  │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## 设计原则

### 1. 单一职责 — 每个 Skill 只做一件事

```
✅ /pre-mr-gate   → 只负责"检查"，不负责"修复"
✅ /scan-triage   → 只负责"分析和建议"，修复由开发者和 AI 协同完成
✅ /coverage-hunt → 只负责"找出缺口和生成骨架"，运行测试是/gate 的事
✅ /deploy-guard  → 只负责"验证"，不负责"回滚"
```

### 2. 安全护栏 — Harness 思想落地

```
每个 Skill 都内置安全控制:

Layer 1 — 操作前检查:
  - /pre-mr-gate: 检查是否在项目根目录
  - /db-inspect:  检查连接参数是否完整，只允许 SELECT
  - /deploy-guard: 确认环境非生产或用户已确认

Layer 2 — 危险操作确认:
  - /db-inspect: 任何非 SELECT 操作需要用户显式确认
  - /deploy-guard: 生产环境操作需要双重确认

Layer 3 — 操作后审计:
  - 所有 Skill 输出 json 格式的审计日志
  - 关键操作记录时间戳和执行结果
```

### 3. 可观测 — 结构化输出

```
每个 Skill 输出统一格式:

{
  "skill": "pre-mr-gate",
  "timestamp": "2024-01-15T10:30:00",
  "result": "pass|fail|warn",
  "checks": [...],
  "suggestions": [...],
  "duration_ms": 1234
}

这个 JSON 可以被下一个 Skill 消费（可组合）
也可以被 Jenkins Pipeline 解析
```

### 4. 可组合 — Pipeline 思维

```
Skills 可以链式调用:

开发阶段:
  /pre-mr-gate → 通过 → /coverage-hunt → 补测试 → 再 /pre-mr-gate

部署阶段:
  Jenkins Pipeline → /scan-triage → 手动修复 → /deploy-guard → /db-inspect

CI 集成:
  Jenkins Groovy 可以调用这些脚本作为 Pipeline Step
```

## 技术决策

### 为什么 Shell + Python 混合？

| 语言 | 适用场景 | 原因 |
|------|---------|------|
| **Shell (Bash)** | 编排 Maven、Git、psql | 直接调用系统命令，最低延迟 |
| **Python** | 解析报告、AI 分类、生成代码 | 文本处理强、JSON 支持好、可集成 AI API |

### 为什么不过度依赖框架？

```
LangChain/LangGraph → 学习成本高，对于这个场景过于重量级
自定义脚本 + Claude Code → 最小化抽象，每一行都理解
```

### Claude Code 集成方式

```
方式 1: Slash Commands（推荐）
  → settings.json 中注册 /pre-mr-gate 等命令
  → Claude Code 可以直接调用对应脚本
  → 用户输入 /pre-mr-gate 即可执行

方式 2: Hooks 自动触发
  → PreToolUse Hook 在 Bash 工具调用前做安全检查
  → PostToolUse Hook 在文件写入后自动格式化

方式 3: 手动执行
  → 直接在终端运行 skills/pre-mr-gate.sh
  → 或者在 Claude Code 中说"运行 pre-mr-gate 检查"
```

## 与现有 Jenkins Pipeline 的关系

```
开发阶段 (本地 + Claude Code):
  ┌─────────────┐   ┌──────────────┐   ┌──────────────┐
  │ /pre-mr-gate │ → │ /coverage-hunt│ → │ 提 MR        │
  └─────────────┘   └──────────────┘   └──────┬───────┘
                                              │
Jenkins 阶段 (CI/CD Pipeline):                 ▼
  ┌──────────────────────────────────────────────────────┐
  │  devx build → test → Sonar → NexusIQ → Cyberflow     │
  │       → G3 deploy → health check                      │
  └──────────────────┬───────────────────────────────────┘
                     │
部署后验证 (本地 + Claude Code):                     ▼
  ┌─────────────┐   ┌──────────────┐   ┌──────────────┐
  │ /deploy-guard│ → │ /db-inspect  │ → │ /scan-triage  │
  └─────────────┘   └──────────────┘   └──────────────┘
```

## 文件命名和位置约定

```
${PROJECT_ROOT}/
├── .claude/
│   ├── settings.json              → 注册 Slash Commands + Hooks
│   └── settings.local.json        → 个人覆盖（不提交 Git）
│
├── scripts/                        → 项目级脚本（可选，团队共享）
│   └── ...
│
└── ~~~/codelife/workflow-skills/   → 本仓库（学习 + 模板）
    ├── skills/                     → 通用 Skill 脚本
    └── claude-code/                → Claude Code 集成模板
```

## Harness Engineering 能力矩阵

每个 Skill 通过共享基础设施库 (`skills/lib/harness-utils.sh` / `.py`) 获得以下能力：

### 安全护栏

| 能力 | Shell 实现 | Python 实现 |
|------|-----------|------------|
| 危险命令检测 | `security_scan()` 匹配 15 种危险模式 | `security_scan()` 同 |
| PII 脱敏 | `sanitize_pii()` 手机/身份证/API Key/Email | `Harness._sanitize_pii()` 同 |
| 输入校验 | `validate_input()` 长度+注入检测 | 内建 |
| SQL 安全 | `run_psql()` 只允许 SELECT | `validate_sql()` |
| 操作风险评估 | CRITICAL→block, HIGH→warn, LOW→allow | 同 |
| 干跑保护 | `DRY_RUN` 模式 + `safe_write_file()` | `dry_run` 参数 |
| 生产环境保护 | `--confirm` 二次确认 | `CircuitBreaker` 状态文件 |

### 失败处理

| 能力 | Shell 实现 | Python 实现 |
|------|-----------|------------|
| 错误分类 | `classify_error()` → TRANSIENT/PERMANENT/DEGRADED | `classify_error()` 同 |
| 结构化错误 | JSON 输出含 `type` 和 `detail` | 同 |
| 优雅降级 | `degradation_level` 自动调整 + `check_degradation()` | `result="degraded"` 输出 |
| 部分成功 | 非关键检查失败 → 降级通过 | 同 |

### 弹性模式

| 能力 | Shell 实现 | Python 实现 |
|------|-----------|------------|
| 指数退避重试 | `retry_with_backoff()` 1s→2s→4s + jitter | `@retry()` 装饰器 |
| 熔断器 | `circuit_breaker_check/record()` 连续5次→暂停60s | `CircuitBreaker` 类 |
| 超时控制 | `run_with_timeout()` + fallback 回调 | 内建 |
| 限流 | 指标计数 + 会话级限制 | 同 |
| 降级管理 | `degradation_level` 0→1→2 三级 | `result="degraded"` |

### 可观测性

| 能力 | Shell 实现 | Python 实现 |
|------|-----------|------------|
| Trace ID | `HARNESS_TRACE_ID` 贯穿全链路 | `Harness.trace_id` |
| 审计日志 | `audit_log()` → `~/.claude/skill-audit/audit.jsonl` | `Harness._audit()` 同 |
| 指标收集 | `metric_incr/latency/last_value()` → `~/.claude/skill-metrics/` | `Harness.metric_*()` 同 |
| 结构化输出 | `harness_output()` 统一 JSON | `Harness.output()` 同 |
| 告警阈值 | 缓存命中率<95%、死元组>5表、错误率>阈值 | 熔断器打开 |
| 成功率追踪 | `successful_runs/total_runs` 实时计算 | 同 |

## 目录结构 (升级后)

```
workflow-skills/
├── README.md
├── ARCHITECTURE.md              # 👈 你在这里
├── skills/
│   ├── lib/                     # ✨ 共享基础设施库
│   │   ├── harness-utils.sh     #    Shell: 安全+重试+熔断+审计
│   │   └── harness-utils.py     #    Python: 安全+重试+熔断+审计
│   ├── pre-mr-gate.sh          # 🔄 已接入 harness-utils.sh
│   ├── deploy-guard.sh         # 🔄 已接入 harness-utils.sh
│   ├── db-inspect.sh           # 🔄 已接入 harness-utils.sh
│   ├── jenkins-debug.sh        # 🔄 已接入 harness-utils.sh
│   ├── scan-triage.py          # 🔄 已接入 harness-utils.py
│   └── coverage-hunt.py        # 🔄 已接入 harness-utils.py
└── claude-code/
    ├── settings-skills.json
    └── hooks/
```

## 扩展路线

```
Phase 1 (当前): 6 个核心 Skill + Harness 基础设施 ✅
Phase 2: 与 Jenkins Pipeline 深度集成，自动触发
Phase 3: 添加 Agent 自主决策能力（扫描结果 → 自动判断是否阻塞发布）
Phase 4: 多项目模板化，新人一键接入
```
