# 🏭 Workflow Skills — 日常工作流自动化

> 基于 Harness Engineering 思想，将 Java 开发日常写成可复用的 Skills

---

## 快速开始

```bash
# 1. 将 skills/ 加入 PATH
export PATH="$PATH:$(pwd)/skills"

# 2. 赋予执行权限
chmod +x skills/*.sh skills/*.py

# 3. 在你的 Spring Boot 项目根目录执行
cd /path/to/your/spring-boot-project
pre-mr-gate.sh          # 提 MR 前检查
coverage-hunt.py 80     # 覆盖率分析（目标 80%）
```

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

### 工作流串联

```
开发新功能:
  /pre-mr-gate → 检查通过 → 提 MR
  ↓ (如果覆盖率不达标)
  /coverage-hunt → 生成测试骨架 → 补测试 → /pre-mr-gate

Jenkins 构建后:
  /scan-triage → 查看 Sonar/NexusIQ/Cyberflow 报告 → AI 修复建议

部署后:
  /deploy-guard → 健康检查 → API 冒烟
  /db-inspect → PostgreSQL 诊断 → 确认数据正常

出问题时:
  /jenkins-debug → 分析 Pipeline 失败原因
  /db-inspect → 查数据库状态
```

---

## 各 Skill 详解

### 1. `/pre-mr-gate` — 提 MR 前自动门禁

```bash
# 基础用法
pre-mr-gate.sh

# 指定覆盖率阈值
COVERAGE_LINE=80 COVERAGE_BRANCH=70 pre-mr-gate.sh

# 跳过 BDD 测试
SKIP_BDD=true pre-mr-gate.sh

# 只检查特定模块
MODULE=order-service pre-mr-gate.sh
```

**检查项：**
- Maven 编译通过
- 单元测试全部通过
- 行覆盖率 >= 阈值
- 分支覆盖率 >= 阈值
- BDD 测试（可选）

### 2. `/scan-triage` — 扫描结果智能分类

```bash
# 解析本地 Sonar 报告
scan-triage.py --sonar target/sonar/report.json

# 解析 Jenkins 构建日志中的扫描结果
scan-triage.py --jenkins-url https://jenkins.company.com/job/order-service/123

# 自动修复低风险问题
scan-triage.py --sonar report.json --auto-fix --dry-run  # 先预览
scan-triage.py --sonar report.json --auto-fix             # 执行修复
```

### 3. `/coverage-hunt` — 覆盖率缺口分析

```bash
# 分析覆盖率，目标 80%
coverage-hunt.py 80

# 输出 top 10 未覆盖方法
coverage-hunt.py 80 --top 10

# 生成测试骨架
coverage-hunt.py 80 --generate-tests
```

### 4. `/deploy-guard` — 部署后健康检查

```bash
# 检查开发环境
deploy-guard.sh dev

# 检查生产环境（需要确认）
deploy-guard.sh prod --confirm

# 指定健康检查 URL
HEALTH_URL=https://myapp.com/actuator/health deploy-guard.sh prod
```

### 5. `/db-inspect` — GCP PostgreSQL 诊断

```bash
# 连接并查看表
db-inspect.sh --db mydb --tables

# 执行诊断查询（只读）
db-inspect.sh --db mydb --diagnose

# 执行自定义查询（需要确认）
db-inspect.sh --db mydb --query "SELECT count(*) FROM orders WHERE created_at > NOW() - INTERVAL '1 hour'"
```

### 6. `/jenkins-debug` — Jenkins 问题定位

```bash
# 分析最近的构建
jenkins-debug.sh --job order-service --build last

# 分析指定构建
jenkins-debug.sh --job order-service --build 1234

# 从本地日志文件分析
jenkins-debug.sh --log console.log
```

---

## Claude Code 集成

### 注册 Slash Commands

将 `claude-code/settings-skills.json` 的内容合并到你的 `.claude/settings.json`：

```json
{
  "slashCommands": [
    {
      "name": "/pre-mr-gate",
      "description": "提 MR 前一键检查：编译+单测+覆盖率+BDD",
      "prompt": "执行 skills/pre-mr-gate.sh 进行 MR 前检查。如果失败，分析原因并给出修复建议。如果覆盖率不足，建议运行 /coverage-hunt。"
    },
    {
      "name": "/scan-triage",
      "description": "分析扫描报告（Sonar/NexusIQ/Cyberflow）并给出修复建议",
      "prompt": "执行 skills/scan-triage.py 分析扫描报告。对问题分类（严重度/类型），对低风险问题直接生成修复代码，对高风险问题给出详细修复方案。"
    }
  ]
}
```

### 配置 Hooks

```bash
# PreToolUse Hook — Bash 命令执行前安全检查
cp claude-code/hooks/pre-tool-use-validate.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/pre-tool-use-validate.sh
```

---

## 目录结构

```
workflow-skills/
├── README.md                    # 👈 你在这里
├── ARCHITECTURE.md              # 架构设计文档
├── skills/                      # 可执行脚本
│   ├── pre-mr-gate.sh          # MR 前门禁
│   ├── scan-triage.py          # 扫描分类
│   ├── coverage-hunt.py        # 覆盖率分析
│   ├── deploy-guard.sh         # 部署验证
│   ├── db-inspect.sh           # 数据库诊断
│   └── jenkins-debug.sh        # Jenkins 调试
└── claude-code/                 # Claude Code 集成配置
    ├── settings-skills.json    # Slash Commands 注册模板
    └── hooks/                   # 自定义 Hooks
```

---

## 扩展指南

### 新增一个 Skill

1. 在 `skills/` 下创建脚本
2. 遵循统一输出格式（见 ARCHITECTURE.md）
3. 在 `settings-skills.json` 中注册 Slash Command
4. 在本文档中添加说明

### 与 Jenkins Pipeline 集成

```groovy
// 在 Jenkinsfile 中调用
stage('Post-Deploy Check') {
    steps {
        sh '''
            export PGPASSWORD=${DB_PASSWORD}
            ./skills/deploy-guard.sh prod --confirm
        '''
    }
}
```

---

> 💡 **Harness 思想**: 把不可控的手动流程变成可控的自动化 Skill，每个 Skill 都是独立、可组合、可审计的单元。
