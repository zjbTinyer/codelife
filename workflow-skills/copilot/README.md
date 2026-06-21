# Copilot 集成 — Workflow Skills

> 把这些 Skill 注册到 GitHub Copilot，让 Copilot 能直接建议和执行

---

## 方式 1: Copilot 自定义指令（推荐）

将 `copilot-instructions.md` 的内容复制到你项目的 `.github/copilot-instructions.md`，Copilot 就会在合适场景下主动建议这些命令。

### 它能做到什么

```
你在 Copilot Chat 里说:                    Copilot 就会:
"帮我做 MR 前的检查"                    →  建议并执行 pre-mr-gate.sh
"这个 Sonar 问题怎么修"                 →  建议运行 scan-triage.py --auto-fix
"覆盖率不够，帮我补测试"                 →  建议运行 coverage-hunt.py --generate-tests
"刚部署完，帮我检查一下"                 →  建议运行 deploy-guard.sh
"连数据库看看有没有慢查询"               →  建议运行 db-inspect.sh --diagnose
"Jenkins 构建失败了，帮我看看"           →  建议运行 jenkins-debug.sh
```

---

## 方式 2: VS Code Tasks

将 `.vscode/tasks.json` 复制到你项目的 `.vscode/` 目录，每个 Skill 变成一个可点击的 Task：

- `Ctrl+Shift+P` → `Tasks: Run Task` → 选择 skill
- 或者在 Copilot Chat 中说 "run task pre-mr-gate"

---

## 方式 3: Makefile（最通用）

将 `Makefile` 复制到项目根目录：

```bash
make gate        # 等同于 pre-mr-gate.sh
make coverage    # 等同于 coverage-hunt.py 80
make scan-fix    # 等同于 scan-triage.py --auto-fix --dry-run
make deploy-check ENV=staging  # 等同于 deploy-guard.sh staging
make db-diagnose INSTANCE=xxx DB=xxx KEY=xxx
make jenkins-log JOB=xxx BUILD=last
```

---

## 文件清单

```
copilot/
├── README.md                         # 👈 你在这里
├── copilot-instructions.md           # 复制到 .github/copilot-instructions.md
├── tasks.json                        # 复制到 .vscode/tasks.json
└── Makefile                          # 复制到项目根目录
```
