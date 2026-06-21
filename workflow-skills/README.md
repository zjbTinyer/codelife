# 🏭 Workflow Skills — 日常工作流自动化

> 基于 Harness Engineering 思想，将 Java 开发日常写成可复用的 Skills
>
> **每个 Skill 内置**：安全护栏 · 指数退避重试 · 熔断器 · 超时降级 · 审计日志 · 指标收集

---

## 快速开始

```bash
# 1. 加入 PATH
export PATH="$PATH:$(pwd)/skills"

# 2. 赋予执行权限
chmod +x skills/*.sh skills/*.py skills/lib/*.sh

# 3. 在你的 Spring Boot 项目根目录执行
cd /path/to/your/spring-boot-project
pre-mr-gate.sh          # 提 MR 前检查
coverage-hunt.py 80     # 覆盖率分析

# 4. 查看审计日志
tail -f ~/.claude/skill-audit/audit.jsonl | jq .
```

---

## 6 个核心 Skill

```
开发阶段              部署阶段              诊断阶段
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ 1. pre-mr-gate│    │ 4. deploy-guard│   │ 5. db-inspect │
│    门禁检查   │    │    部署验证    │    │    数据库诊断  │
├──────────────┤    ├──────────────┤    ├──────────────┤
│ 2. scan-triage│    │ 6. jenkins-debug│  │              │
│    扫描分类   │    │    流水线调试  │    │              │
├──────────────┤    └──────────────┘    └──────────────┘
│ 3.coverage-hunt│
│    覆盖率补全  │
└──────────────┘
```

---

## 各 Skill 详解

### 1. `/pre-mr-gate` — 提 MR 前自动门禁

**数据来源**：`mvn jacoco:report` → 解析 `target/site/jacoco/jacoco.csv`（逐行累加 `LINE_MISSED/LINE_COVERED/BRANCH_MISSED/BRANCH_COVERED`）

**前提**：`pom.xml` 中需配置 `jacoco-maven-plugin`

```bash
pre-mr-gate.sh                              # 全部检查
COVERAGE_LINE=80 COVERAGE_BRANCH=70 pre-mr-gate.sh  # 自定义阈值
MODULE=order-service pre-mr-gate.sh         # 只检查指定模块
SKIP_BDD=true pre-mr-gate.sh                # 跳过 BDD
```

**检查项**：编译 → 单元测试 → 行覆盖率 → 分支覆盖率 → BDD（可选）

- Maven 编译失败 → `PERMANENT` 错误，不重试，直接报告
- 测试失败 → 解析 `Tests run:/Failures:/Errors:` 统计失败数
- 覆盖率不足 → `metric_incr "coverage_gaps"`，建议运行 `/coverage-hunt`
- BDD 失败 → 降级处理（不阻塞 MR）

---

### 2. `/scan-triage` — 扫描结果智能分类 + 修复

#### 获取 Sonar 报告（4 种方式）

| 方式 | 命令 | 适用场景 |
|------|------|---------|
| **SonarQube API** | `--sonar-url https://sonar.company.com --sonar-project-key com.company:order-service` | Jenkins 已跑过扫描 |
| **本地触发+API** | `--trigger-scan --sonar-url https://sonar.company.com` | 想立即看到最新结果 |
| **本地 JSON 文件** | `--sonar target/sonar/report.json` | pom.xml 配置了本地输出 |
| **Jenkins 日志** | `--jenkins-url https://jenkins.company.com --jenkins-job order-service` | 从构建日志提取 |

```bash
# 最常用：从 SonarQube API 拉取（需要 SONAR_TOKEN 环境变量）
export SONAR_TOKEN="squ_xxxx"
scan-triage.py --sonar-url https://sonarqube.company.com \
               --sonar-project-key com.company:order-service

# 本地触发 + API 拉取
scan-triage.py --trigger-scan \
               --sonar-url https://sonarqube.company.com

# 自动修复（仅 Sonar 代码规范，不动安全漏洞和依赖）
scan-triage.py --sonar-url ... --auto-fix --dry-run   # 先预览
scan-triage.py --sonar-url ... --auto-fix              # 执行
```

#### 三类扫描的修复能力

| 扫描源 | 能自动修？ | 做了什么 | 为什么限制 |
|--------|-----------|---------|-----------|
| **Sonar** | ✅ 14 条规则 | 删未用 import、System.out→logger、工具类加 private 构造器 | 改动安全，错了最多编译不过 |
| **NexusIQ** | ⚠️ 建议升级 | 解析 pom.xml 找依赖当前版本 → 给出安全版本建议 | 升级可能 API 不兼容 |
| **Cyberflow SAST** | ❌ 人工审查 | SQL注入→PreparedStatement 示例、XSS→HtmlUtils 示例 | 安全修复必须人判断 |
| **Cyberflow Container** | ⚠️ 建议修改 | Dockerfile 基础镜像升级、apt-get upgrade 提示 | 怕镜像行为异常 |

---

### 3. `/coverage-hunt` — 覆盖率缺口分析 + 测试生成

**数据来源**：`mvn jacoco:report` → 解析 `jacoco.csv`(覆盖率) + `jacoco.xml`(方法级细节)

```bash
coverage-hunt.py 80                            # 分析，目标 80%
coverage-hunt.py 80 --top 10                   # Top 10 未覆盖类
coverage-hunt.py 80 --generate-tests            # 生成 JUnit 5 测试骨架
coverage-hunt.py 80 --generate-tests --dry-run  # 预览生成位置
```

**生成骨架包含**：`@ExtendWith(MockitoExtension.class)` + `@Nested` 三级分类(正常/边界/异常) + `@DisplayName` TODO 提示。你只需填写 Given-When-Then 逻辑。

---

### 4. `/deploy-guard` — 部署后健康验证

```bash
deploy-guard.sh dev                    # 开发环境
deploy-guard.sh staging                # 预发布环境
deploy-guard.sh prod --confirm         # 生产（需二次确认）
SKIP_DB=true deploy-guard.sh dev       # 跳过数据库检查
```

**检查项**：`/actuator/health` → 详细组件状态 → PostgreSQL 连接 + 表行数 → API 冒烟 → 5xx 错误指标

- 健康检查失败 → 带重试（指数退避，最多 2 次）
- 非关键检查失败 → 降级通过（`result=degraded`）
- 生产环境 → 仅执行只读操作，写操作被安全规则自动阻止

---

### 5. `/db-inspect` — GCP PostgreSQL 诊断

**核心能力**：自动启动 Cloud SQL Proxy → 用 SA Key 认证 → 连接 → 诊断 → 退出时自动关闭 Proxy

```bash
# === GCP 连接方式 ===

# 方式 1: 自动匹配 SA Key（推荐）
# 从 --gcp-instance 中提取 project ID，自动在 ~/.gcp-keys/ 中找对应 key
db-inspect.sh --gcp-instance order-prod:us-central1:order-pg \
              --db orderdb --diagnose

# 方式 2: 手动指定 key 文件
db-inspect.sh --gcp-instance order-prod:us-central1:order-pg \
              --gcp-key ~/.gcp-keys/order-prod-sa.json \
              --db orderdb --diagnose

# 方式 3: Proxy 已经在跑
db-inspect.sh --db orderdb --no-proxy --diagnose

# 方式 4: IAM 认证（不用密码）
db-inspect.sh --gcp-instance ... --gcp-iam-auth --db orderdb --diagnose

# === 管理 SA Key ===
db-inspect.sh --list-keys                  # 列出所有本地 key 文件
db-inspect.sh --gcp-key-dir ~/my-keys ...  # 自定义 key 存放目录

# === 诊断操作（全部只读） ===
db-inspect.sh --gcp-instance ... --db orderdb --diagnose   # 全面诊断
db-inspect.sh --gcp-instance ... --db orderdb --tables     # 列出所有表
db-inspect.sh --gcp-instance ... --db orderdb --schema orders  # 查看表结构
db-inspect.sh --gcp-instance ... --db orderdb --monitor    # 实时监控
db-inspect.sh --gcp-instance ... --db orderdb \
              --query "SELECT count(*) FROM orders WHERE created_at > NOW() - INTERVAL '1 hour'"
```

**SA Key 自动匹配逻辑**：`--gcp-instance` 中提取 project ID → 在 `~/.gcp-keys/` 中按文件名匹配 → 按 JSON 内 `project_id` 字段匹配 → 兜底用目录下第一个 key。

**诊断报告包含**：连接数 · 慢查询(>5s) · 锁等待 · 表大小 Top20 · 缓存命中率 · 未使用索引 · 死元组(VACUUM) · 阈值告警（命中率<95%、死元组过多）

---

### 6. `/jenkins-debug` — Jenkins Pipeline 问题定位

```bash
jenkins-debug.sh --job order-service --build last
jenkins-debug.sh --job order-service --build 1234
jenkins-debug.sh --log console.log          # 分析本地日志
```

**分析能力**：定位失败 Stage → 14 种错误模式匹配 → 错误分类（TRANSIENT/PERMANENT）→ 提取异常堆栈 → 给出修复命令建议。

---

## 🛡️ Harness Engineering 内置能力

所有 Skill 通过 `skills/lib/harness-utils.sh` / `.py` 共享以下基础设施：

| 能力 | 位置 | 说明 |
|------|------|------|
| **安全护栏** | `security_scan()` | 14 种危险模式检测（rm -rf、curl\|sh、sudo、API Key 泄露）；PII 脱敏（手机/身份证/邮箱） |
| **指数退避重试** | `retry_with_backoff()` / `@retry()` | 1s→2s→4s + ±30% 随机抖动；错误分类后自动判断是否重试 |
| **熔断器** | `circuit_breaker_check/record()` / `CircuitBreaker` | 连续失败 5 次 → 暂停 60 秒 → 半开尝试 → 恢复或继续熔断 |
| **超时降级** | `run_with_timeout()` + fallback | 超时后执行降级回调解而非直接失败 |
| **审计日志** | `~/.claude/skill-audit/audit.jsonl` | 每次执行完整记录：trace_id、skill、事件、耗时 |
| **指标收集** | `~/.claude/skill-metrics/` | 成功/失败/重试/超时计数 + 延迟分布 |
| **Trace ID** | `HARNESS_TRACE_ID` | 一次执行全链路可串联 |

---

## 目录结构

```
workflow-skills/
├── README.md                       # 👈 你在这里
├── ARCHITECTURE.md                 # 架构文档 + Harness 能力矩阵
├── skills/
│   ├── lib/                        # ✨ 共享基础设施
│   │   ├── harness-utils.sh        #    Shell: 安全 + 重试 + 熔断 + 审计
│   │   └── harness-utils.py        #    Python: 同上
│   ├── pre-mr-gate.sh             # MR 前门禁
│   ├── scan-triage.py             # 扫描分类 + 修复
│   ├── coverage-hunt.py           # 覆盖率分析 + 测试生成
│   ├── deploy-guard.sh            # 部署后验证
│   ├── db-inspect.sh              # GCP PostgreSQL 诊断
│   └── jenkins-debug.sh           # Jenkins 问题定位
└── claude-code/
    ├── settings-skills.json       # Slash Commands 注册模板
    └── hooks/                      # PreToolUse/PostToolUse 钩子
```

---

## 与你工作流的对应

| 日常操作 | Skill | 数据来源 |
|---------|-------|---------|
| 提 MR 前检查 | `/pre-mr-gate` | `mvn jacoco:report` → `jacoco.csv` |
| 覆盖率不够 | `/coverage-hunt` | `jacoco.csv` + `jacoco.xml` |
| Sonar 问题多 | `/scan-triage --sonar-url` | SonarQube Web API |
| NexusIQ 漏洞 | `/scan-triage --nexusiq` | NexusIQ HTML 报告 |
| Cyberflow 问题 | `/scan-triage --cyberflow-*` | Cyberflow JSON 报告 |
| G3 部署后 | `/deploy-guard` | `/actuator/health` + `psql` |
| 连数据库查问题 | `/db-inspect --gcp-instance` | Cloud SQL Proxy + SA Key |
| Jenkins 红了 | `/jenkins-debug` | Jenkins Console Log |

---

> 💡 **核心思想**: 每个 Skill 独立可用、可组合、内置安全护栏、全链路可审计。`source lib/harness-utils.sh` 一行即可给新 Skill 接入全部 Harness 能力。
