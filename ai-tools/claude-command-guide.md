# Claude Code 命令参考手册

> 当前系统版本: **2.1.183** | 安装路径: `~/.nvm/versions/node/v24.16.0/bin/claude`

---

## 一、概述

`claude` 是 Anthropic 推出的 **AI 编程助手 CLI 工具**（Claude Code），可以直接在终端中与 Claude 交互，执行代码编写、文件操作、代码审查、调试等软件开发任务。

运行模式：
- **交互模式**（默认）：直接运行 `claude` 进入对话
- **非交互模式**（`-p`/`--print`）：一次问答即退出，适合管道和 CI

---

## 二、启动方式

```bash
claude                          # 启动交互式会话
claude "请帮我重构这个函数"      # 直接传 prompt 进入会话
claude -p "列出当前目录文件"     # 单次问答，适合管道
claude -c                        # 继续当前目录最近的会话
claude -r                        # 恢复指定会话（交互式选择器）
claude -r <session-id>           # 恢复指定 session ID
claude -w                        # 创建 git worktree 隔离环境
claude --model opus              # 指定模型启动
```

---

## 三、核心选项分类

### 3.1 模型与 AI 行为

| 选项 | 说明 |
|------|------|
| `--model <model>` | 指定模型，支持别名 `opus`/`sonnet`/`haiku`/`fable` 或完整名 `claude-fable-5` |
| `--effort <level>` | 推理努力级别：`low` / `medium` / `high` / `xhigh` / `max` |
| `--agent <agent>` | 使用预设 agent（自定义助手角色） |
| `--agents <json>` | 定义自定义 agent，如 `{"reviewer": {"description": "...", "prompt": "..."}}` |
| `--system-prompt <prompt>` | 自定义系统提示词 |
| `--append-system-prompt <prompt>` | 在默认系统提示词后追加内容 |
| `--fallback-model <model>` | 主模型过载时自动降级，可指定多个用逗号分隔（仅 `--print` 模式） |
| `--max-budget-usd <amount>` | API 调用最大花费上限（仅 `--print` 模式） |

### 3.2 会话管理

| 选项 | 说明 |
|------|------|
| `-c, --continue` | 继续当前目录最近一次会话 |
| `-r, --resume [value]` | 按 session ID 恢复，或打开交互式选择器 |
| `--fork-session` | 恢复时创建新 session ID（不覆盖原会话） |
| `-n, --name <name>` | 为会话设置显示名称 |
| `--session-id <uuid>` | 使用指定 UUID 作为会话 ID |
| `--from-pr [value]` | 从 PR 号码/URL 恢复关联的会话 |
| `--no-session-persistence` | 不持久化会话到磁盘（仅 `--print`） |

### 3.3 输出与管道

| 选项 | 说明 |
|------|------|
| `-p, --print` | 单次问答，输出后退出，适合管道 |
| `--output-format <format>` | 输出格式：`text`（默认）/ `json` / `stream-json` |
| `--json-schema <schema>` | 结构化输出 JSON Schema 校验 |
| `--input-format <format>` | 输入格式：`text`（默认）/ `stream-json` |
| `--include-partial-messages` | 输出流式增量消息 |
| `--include-hook-events` | 输出包含 hook 生命周期事件 |
| `--replay-user-messages` | 将用户消息回显到 stdout（用于确认） |
| `--prompt-suggestions [value]` | 启用/关闭 prompt 建议（默认开启） |
| `--ax-screen-reader` | 屏幕阅读器友好输出（纯文本，无装饰） |

### 3.4 工具与权限

| 选项 | 说明 |
|------|------|
| `--tools <tools...>` | 限制可用工具列表，如 `"Bash,Edit,Read"`；`""` 禁用所有工具 |
| `--allowed-tools <tools...>` | 允许的工具白名单 |
| `--disallowed-tools <tools...>` | 禁止的工具黑名单 |
| `--add-dir <directories...>` | 额外允许 Claude 访问的目录 |
| `--permission-mode <mode>` | 权限模式：`default` / `auto` / `bypassPermissions` / `acceptEdits` / `dontAsk` / `plan` |
| `--dangerously-skip-permissions` | 跳过所有权限检查（仅沙箱环境） |
| `--allow-dangerously-skip-permissions` | 允许在会话中临时跳过权限（不默认启用） |

### 3.5 调试与诊断

| 选项 | 说明 |
|------|------|
| `-d, --debug [filter]` | 启用调试模式，可按类别过滤（如 `api,hooks`） |
| `--debug-file <path>` | 将调试日志写入指定文件 |
| `--verbose` | 覆盖 config 中的 verbose 设置 |
| `--safe-mode` | 安全模式：禁用所有自定义配置（CLAUDE.md、skills、hooks、MCP 等），用于故障排查 |

### 3.6 集成与插件

| 选项 | 说明 |
|------|------|
| `--ide` | 启动时自动连接 IDE |
| `--chrome` | 启用 Claude in Chrome 集成 |
| `--plugin-dir <path>` | 从本地目录加载插件 |
| `--plugin-url <url>` | 从 URL 加载插件 zip |
| `--mcp-config <configs...>` | 加载 MCP 服务器配置（JSON 文件或字符串） |
| `--strict-mcp-config` | 仅使用 `--mcp-config` 指定的 MCP，忽略所有其他配置 |
| `--disable-slash-commands` | 禁用所有 slash 命令（skills） |
| `--bare` | 极简模式：跳过 hooks、LSP、插件、自动记忆等 |

### 3.7 Worktree 隔离

| 选项 | 说明 |
|------|------|
| `-w, --worktree [name]` | 创建 git worktree 隔离会话环境 |
| `--tmux` | 在 worktree 中创建 tmux 会话（iTerm2 原生窗格优先） |

### 3.8 远程控制

| 选项 | 说明 |
|------|------|
| `--remote-control [name]` | 启动远程控制会话 |
| `--remote-control-session-name-prefix <prefix>` | 远程控制会话名前缀（默认：hostname） |

---

## 四、子命令

| 命令 | 说明 |
|------|------|
| `claude auth` | 管理认证（OAuth / API Key） |
| `claude mcp` | 配置和管理 MCP 服务器 |
| `claude plugin` / `claude plugins` | 管理插件（install / enable / disable / list / init） |
| `claude agents` | 管理后台运行的 agent |
| `claude install [target]` | 安装 Claude Code（可指定版本：stable / latest / 具体版本） |
| `claude update` / `claude upgrade` | 检查并安装更新 |
| `claude doctor` | 健康检查（自动更新等） |
| `claude project` | 管理项目状态 |
| `claude auto-mode` | 检查自动模式分类器配置 |
| `claude ultrareview [target]` | 云端多 agent 代码审查（当前分支 / PR 号） |
| `claude setup-token` | 设置长期认证令牌 |

---

## 五、MCP 服务器管理

`claude mcp` 子命令用于管理 MCP（Model Context Protocol）服务器：

```bash
# 添加 HTTP 协议的 MCP 服务器
claude mcp add --transport http sentry https://mcp.sentry.dev/mcp

# 添加带认证头的 HTTP MCP
claude mcp add --transport http corridor https://app.corridor.dev/api/mcp \
  --header "Authorization: Bearer ..."

# 添加 stdio 本地 MCP 服务器（含环境变量）
claude mcp add my-server -e API_KEY=xxx -- npx my-mcp-server

# 从 Claude Desktop 导入 MCP 配置
claude mcp add-from-claude-desktop

# 查看 MCP 服务器详情
claude mcp get <name>

# 用 JSON 字符串添加 MCP
claude mcp add-json <name> '{"transport":"stdio","command":"npx","args":["..."]}'
```

---

## 六、插件管理

`claude plugin` 子命令管理 Claude Code 插件：

```bash
claude plugin list                    # 列出已安装插件
claude plugin install <name>          # 安装插件
claude plugin enable <name>           # 启用插件
claude plugin disable <name>          # 禁用插件
claude plugin details <name>          # 查看插件详情和 token 预估
claude plugin init <name>             # 脚手架创建新插件
```

### 当前系统已安装的插件

| 插件 | 来源 | 用途 |
|------|------|------|
| `chogos@chogos-skills` | Chogos/claude-skills | 各语言/框架最佳实践（Go、Python、Rust、SQL 等） |
| `jdtls-lsp@claude-plugins-official` | 官方 | Java LSP 支持 |
| `typescript-lsp@claude-plugins-official` | 官方 | TypeScript LSP 支持 |
| `pyright-lsp@claude-plugins-official` | 官方 | Python LSP 支持 |
| `frontend-design@claude-plugins-official` | 官方 | 前端设计指导 |

已注册的插件市场源：

| 名称 | 仓库 |
|------|------|
| `claude-plugins-community` | anthropics/claude-plugins-community |
| `cc-plugins` | kossakovsky/cc-plugins |
| `claudest` | gupsammy/Claudest |
| `cc-pocket-marketplace` | cbingb666/cc-pocket-marketplace |
| `chogos-skills` | Chogos/claude-skills |

---

## 七、配置文件结构

### 全局配置: `~/.claude/settings.json`

当前系统配置摘要：

```jsonc
{
  "model": "haiku",                    // 默认模型
  "permissions": {
    "allow": [                         // 已放行命令（共36条）
      "Bash(npm:*)", "Bash(pnpm:*)", "Bash(yarn:*)", "Bash(npx:*)",
      "Bash(node:*)", "Bash(pip3:*)", "Bash(python3:*)",
      "Bash(java:*)", "Bash(mvn:*)", "Bash(gradle:*)",
      "Bash(flutter:*)", "Bash(dart:*)",
      "Bash(git:*)", "Bash(ls:*)", "Bash(mkdir:*)", "Bash(cp:*)",
      "Bash(mv:*)", "Bash(rm:*)", "Bash(curl:*)", "Bash(wget:*)",
      "Bash(which:*)", "Bash(echo:*)", "Bash(cd:*)", "Bash(pwd:*)",
      "Bash(find:*)", "Bash(grep:*)", "Bash(wc:*)", "Bash(head:*)",
      "Bash(tail:*)", "Bash(source:*)", "Bash(export:*)",
      "Bash(scrapy:*)", "Bash(playwright:*)",
      "Bash(docker:*)", "Bash(docker-compose:*)"
    ]
  },
  "enabledPlugins": { ... },           // 已启用插件
  "extraKnownMarketplaces": { ... }    // 额外插件市场源
}
```

### 本地配置优先级

```
settings.local.json  >  settings.json  >  默认值
（项目级）              （全局）
```

### `~/.claude/` 目录结构

```
~/.claude/
├── CLAUDE.md                  # 全局 CLAUDE.md（用户指令）
├── settings.json              # 全局配置
├── settings.local.json        # 本地覆盖配置
├── plugins/                   # 插件
├── skills/                    # Skills / slash 命令
├── sessions/                  # 会话持久化存储
├── projects/                  # 项目级数据
├── tasks/                     # 后台任务
├── jobs/                      # 定时任务
├── cache/                     # 缓存
├── plans/                     # 计划文件
├── file-history/              # 文件编辑历史
├── shell-snapshots/           # Shell 快照
├── keys/                      # 密钥
├── telemetry/                 # 遥测数据
├── usage-data/                # 用量数据
├── daemon.*                   # 后台守护进程
└── history.jsonl              # 历史记录
```

### 项目级配置

项目目录下可以创建 `.claude/` 目录，包含：

- `.claude/settings.json` — 项目级设置
- `.claude/settings.local.json` — 项目级本地覆盖（不提交）
- `.claude/memory/` — 持久记忆目录
- `.claude/scheduled_tasks.json` — 定时任务

---

## 八、CLAUDE.md 系统

CLAUDE.md 是 Claude Code 的核心指令文件，用于定义项目的上下文和行为规范。

### 查找顺序

1. `~/.claude/CLAUDE.md` — 全局指令（当前系统存在）
2. `{project}/CLAUDE.md` — 项目根目录
3. `{project}/.claude/CLAUDE.md` — 项目 .claude 目录

### 用途

- 项目结构说明
- 编码规范与命名约定
- 技术栈说明
- API 设计规范
- 测试要求
- 部署流程

---

## 九、内存（Memory）系统

Claude Code 支持持久化的文件记忆系统，存储在 `{project}/.claude/memory/`。

- 每条记忆是一个 markdown 文件，包含 frontmatter（`name`、`description`、`type`）
- 支持 `[[link]]` 交叉引用
- `MEMORY.md` 作为索引文件，每次启动时加载到上下文
- 类型：`user`（用户画像）、`feedback`（行为指导）、`project`（项目知识）、`reference`（外部资源）

当前项目已有 4 条记忆：
- Agent 设计七大原则
- Claude Code 轻量配置
- 微信公众号自动发布系统
- 前端设计 Skill 策略

---

## 十、Skills / Slash 命令

Claude Code 支持通过 `/<name>` 调用预设技能（Skills）。当前可用的技能包括：

| 命令 | 用途 |
|------|------|
| `/context7` | 库文档查询（React、Vue、Django 等） |
| `/deploy-to-vercel` | 部署到 Vercel |
| `/deep-research` | 深度研究（多源搜索 + 交叉验证） |
| `/code-review` | 代码审查 |
| `/security-review` | 安全审查 |
| `/review` | PR 审查 |
| `/verify` | 验证代码修改效果 |
| `/simplify` | 代码简化与重构 |
| `/frontend-design` | 前端设计指导 |
| `/ui-ux-pro-max` | UI/UX 优化 |
| `/loop` | 定时循环任务 |
| `/init` | 初始化 CLAUDE.md |
| `/run` | 启动并预览应用 |
| `/chogos:*` | Chogos 最佳实践（golang、python、rust、sqlite、docker 等） |
| `/model` | 切换模型 |
| `/update-config` | 更新设置 |
| `/keybindings-help` | 快捷键自定义 |

---

## 十一、常用工作流

### 日常开发

```bash
claude                           # 启动会话
claude -c                        # 继续上次会话
claude -p "重构 src/utils.ts"    # 一次性任务
```

### 代码审查

```bash
claude ultrareview               # 多 agent 云端审查（PR）
claude ultrareview main          # 对比 main 分支审查
# 或在会话内使用 /code-review 或 /security-review
```

### 调试

```bash
claude -d                         # 开启调试模式
claude -d api,hooks               # 过滤特定调试类别
claude -d --debug-file ./debug.log  # 输出到文件
```

### 隔离环境

```bash
claude -w                        # 创建 git worktree 隔离
claude -w risky-refactor         # 指定 worktree 名称
claude --safe-mode                # 安全模式排查问题
```

### 模型选择

```bash
claude --model sonnet            # Sonnet（平衡）
claude --model opus              # Opus（最强推理）
claude --model haiku             # Haiku（快速轻量）
claude --model fable             # Fable 5（最新）
claude --effort high             # 高推理深度
```

### 管道使用

```bash
cat input.txt | claude -p --output-format json --json-schema '{
  "type":"object",
  "properties":{"summary":{"type":"string"}},
  "required":["summary"]
}' "总结这段文本"
```

---

## 十二、模型选择指南

| 模型 | 场景 | 特点 |
|------|------|------|
| **Fable 5** (`fable`) | 最新旗舰模型 | 最强能力，适合复杂任务 |
| **Opus 4.8** (`opus`) | 复杂推理、深度分析 | 推理最强，适合架构设计、复杂 bug 修复 |
| **Sonnet 4.6** (`sonnet`) | 日常开发、平衡选择 | 速度与质量的黄金平衡 |
| **Haiku 4.5** (`haiku`) | 简单问答、快速任务 | 极快速度，适合简单查询和快速原型 |

> **当前默认模型**: `haiku`

---

## 十三、权限模式

| 模式 | 说明 |
|------|------|
| `default` | 每次操作询问（默认） |
| `auto` | 自动模式，低风险操作自动批准（需先配置 classifier） |
| `bypassPermissions` | 完全跳过所有权限检查 |
| `acceptEdits` | 自动接受文件编辑操作 |
| `dontAsk` | 从不询问，自动拒绝未授权的操作 |
| `plan` | 计划模式，仅调研不执行 |

---

## 十四、环境变量

常用环境变量：

| 变量 | 说明 |
|------|------|
| `ANTHROPIC_API_KEY` | Anthropic API 密钥 |
| `CLAUDE_CODE_SAFE_MODE=1` | 安全模式标记 |
| `CLAUDE_CODE_SIMPLE=1` | 极简模式标记（由 `--bare` 设置） |

---

## 十五、后台 Agent

Claude Code 支持后台运行 agent 执行异步任务：

```bash
claude agents --cwd /path/to/project   # 查看指定项目后台 agent
claude agents --all                    # 查看所有 agent（含已完成的）
```

**Agent 类型说明**（当前会话可用）：

| Agent | 用途 |
|-------|------|
| `claude` / `general-purpose` | 通用任务 |
| `Explore` | 只读搜索，适合代码探索 |
| `Plan` | 架构设计，制定实现计划 |
| `claude-code-guide` | Claude Code 使用答疑 |

---

## 十六、零散配置技巧

### 设置默认模型

```bash
claude config set model sonnet    # 通过 /model 命令
# 或直接编辑 ~/.claude/settings.json
```

### 放行更多命令

通过 `claude` 权限提示选择"始终允许"，或直接编辑 `settings.json` 的 `permissions.allow` 数组。

### 升级

```bash
claude upgrade   # 检查并更新到最新版本
```
