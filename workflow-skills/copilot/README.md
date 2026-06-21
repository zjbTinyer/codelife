# Copilot 集成 — 文字建议模式

> 把 `.github/copilot-instructions.md` 复制到项目根目录，Copilot Chat 就能在对应场景主动建议这些命令

---

## 接入步骤

```bash
# 复制到你的项目（如果已有此文件，合并进去）
cp copilot/copilot-instructions.md ../你的项目/.github/copilot-instructions.md
```

不需要装任何东西。Copilot 读取这个文件后，在对话中自动关联。

---

## 效果

```
你说:                                    Copilot 会建议:
"准备提 MR 了"                        → 建议运行 ./skills/pre-mr-gate.sh
"覆盖率不够"                          → 建议运行 ./skills/coverage-hunt.py 80
"Sonar 扫出一堆问题"                   → 建议运行 ./skills/scan-triage.py --sonar-url ...
"看看这个能不能自动修"                 → 建议 ./skills/scan-triage.py --auto-fix --dry-run
"部署完帮我验证一下"                   → 建议运行 ./skills/deploy-guard.sh staging
"查一下订单库有没有慢查询"             → 建议运行 ./skills/db-inspect.sh --gcp-instance ... --diagnose
"Jenkins 挂了帮我看看"                 → 建议运行 ./skills/jenkins-debug.sh --job ... --build last
```

## 其他辅助文件

| 文件 | 用途 |
|------|------|
| `tasks.json` | VS Code 内 `Ctrl+Shift+P → Tasks: Run Task` 一键执行 |
| `Makefile` | 终端 `make gate` / `make scan-fix` 快捷方式 |
