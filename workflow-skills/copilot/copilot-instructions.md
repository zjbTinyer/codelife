# Copilot 自定义指令
#
# 使用方法: 将此文件内容复制到你的项目根目录的 .github/copilot-instructions.md
# 或者合并到你已有的 copilot-instructions.md 中
#
# 文档: https://docs.github.com/en/copilot/customizing-copilot/adding-custom-instructions

## 项目技能 (Workflow Skills)

本项目在 `skills/` 目录下有一组自动化脚本，每个脚本都内置安全护栏、重试、熔断和审计。

### 可用命令

| 命令 | 用途 | 何时使用 |
|------|------|---------|
| `./skills/pre-mr-gate.sh` | MR 前检查：编译+测试+覆盖率+BDD | 开发完成准备提 MR |
| `./skills/coverage-hunt.py <目标%>` | 覆盖率缺口分析+测试生成 | 覆盖率不达标 |
| `./skills/scan-triage.py --sonar-url <url> --sonar-project-key <key>` | Sonar/NexusIQ/Cyberflow 报告分析 | Jenkins 扫描后发现新问题 |
| `./skills/scan-triage.py --auto-fix --dry-run` | 预览自动修复 | 想看看哪些能自动修 |
| `./skills/deploy-guard.sh <env>` | 部署后健康验证 | G3 部署完成 |
| `./skills/db-inspect.sh --gcp-instance <x> --db <name> --diagnose` | GCP PostgreSQL 诊断 | 怀疑数据库有问题 |
| `./skills/db-inspect.sh --list-keys` | 列出本地 GCP SA Key | 不确定用哪个 key |
| `./skills/jenkins-debug.sh --job <name> --build last` | Jenkins 构建日志分析 | 构建失败 |

### 环境变量

- `SONAR_TOKEN` — SonarQube API Token
- `GCP_KEY_DIR` — Service Account Key 存放目录 (默认 `~/.gcp-keys`)
- `DB_PASSWORD` — PostgreSQL 密码
- `JENKINS_URL` — Jenkins 服务器地址

### Skill 行为准则

1. **所有 Skill 都是只读优先** — 修改文件会先 dry-run 预览
2. **数据库操作只允许 SELECT** — 写操作会被自动拦截
3. **生产环境操作需二次确认** — `prod` 环境需要 `--confirm`
4. **执行前先说明即将做什么** — 让用户知道调用链

### 对话中的触发规则

当用户说以下内容时，建议对应的 Skill：

- "准备提 MR" / "帮我检查一下" / "能不能合了" → 建议 `pre-mr-gate.sh`
- "覆盖率不够" / "帮我补测试" / "这段代码没测" → 建议 `coverage-hunt.py`
- "Sonar 报了个问题" / "扫描又挂了" / "这个警告怎么修" → 建议 `scan-triage.py`
- "部署完了吗" / "帮我看看服务正常不" → 建议 `deploy-guard.sh`
- "数据库慢了" / "帮我看看 PG" / "订单表有多少数据" → 建议 `db-inspect.sh`
- "Jenkins 红了" / "流水线挂了" / "构建日志看不懂" → 建议 `jenkins-debug.sh`

### 审计

每次 Skill 执行后，建议用户查看审计日志：
```bash
tail -20 ~/.claude/skill-audit/audit.jsonl | jq .
```
