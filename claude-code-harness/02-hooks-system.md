# 2.2 — Hooks 系统 (事件驱动拦截)

## 1. 什么是 Hooks？

Hooks 是 Claude Code 中的**事件驱动拦截机制**。它们允许你在 Agent 生命周期的关键节点注入自定义逻辑，就像 Spring AOP 的切面。

```
类比:
  Spring AOP @Before / @After / @Around
  Git Hooks: pre-commit, post-merge
  React Hooks: useEffect, useState
  Claude Code Hooks: 在工具调用、会话事件时介入
```

## 2. Hook 生命周期事件

```
Agent 生命周期中可以挂载 Hook 的节点:

┌──────────────────────────────────────────────────────┐
│                    Agent 生命周期                     │
│                                                       │
│  [PreToolUse]  →  工具调用前                          │
│       │                                               │
│  [ToolExecution]  →  工具执行中                       │
│       │                                               │
│  [PostToolUse]  →  工具执行后                         │
│       │                                               │
│  [PreMessage]  →  消息发送给LLM前                     │
│       │                                               │
│  [PostMessage]  →  LLM 回复后                         │
│       │                                               │
│  [SessionStart]  →  会话开始                          │
│       │                                               │
│  [SessionEnd]  →  会话结束                            │
│       │                                               │
│  [Notification]  →  系统通知/提醒                     │
│       │                                               │
│  [Stop]  →  Agent 停止                                │
└──────────────────────────────────────────────────────┘
```

## 3. Hooks 配置

### 3.1 基础配置

```json
// ~/.claude/settings.json 或 .claude/settings.json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "command": "python3 ~/.claude/hooks/session_start.py"
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "command": "python3 ~/.claude/hooks/validate_bash.py"
      },
      {
        "matcher": "Write",
        "command": "python3 ~/.claude/hooks/backup_before_write.py"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "command": "python3 ~/.claude/hooks/lint_after_write.py"
      },
      {
        "matcher": "Bash",
        "command": "python3 ~/.claude/hooks/log_command.py"
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "command": "python3 ~/.claude/hooks/cleanup.py"
      }
    ]
  }
}
```

### 3.2 Matcher 匹配规则

```
Matcher 模式:
  "*"          → 匹配所有工具/事件
  "Bash"       → 精确匹配 Bash 工具
  "Read,Write" → 匹配 Read 或 Write
  "!Edit"      → 排除 Edit（实验性）
```

## 4. Hook 脚本开发

### 4.1 环境变量接口

```python
# Claude Code 通过环境变量传递 Hook 上下文

"""
关键环境变量:
  CLAUDE_HOOK_EVENT       → 事件类型: "PreToolUse", "PostToolUse", ...
  CLAUDE_TOOL_NAME        → 工具名: "Bash", "Write", "Read", ...
  CLAUDE_TOOL_INPUT       → 工具输入 (JSON字符串)
  CLAUDE_TOOL_OUTPUT      → 工具输出 (JSON字符串，PostToolUse才有)
  CLAUDE_SESSION_ID       → 会话ID
  CLAUDE_WORKING_DIR      → 当前工作目录
"""
```

### 4.2 PreToolUse Hook 示例

```python
#!/usr/bin/env python3
"""
PreToolUse Hook — 在工具调用前进行安全检查
路径: ~/.claude/hooks/validate_bash.py
"""
import os
import json
import sys
import re

def main():
    event = os.environ.get("CLAUDE_HOOK_EVENT")
    tool = os.environ.get("CLAUDE_TOOL_NAME")
    tool_input = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))

    if tool != "Bash":
        sys.exit(0)  # 不干预其他工具

    command = tool_input.get("command", "")

    # === 自定义安全规则 ===

    # 1. 禁止的目录
    forbidden_dirs = ["/etc", "/boot", "/System"]
    for d in forbidden_dirs:
        if d in command:
            print(json.dumps({
                "decision": "block",
                "reason": f"禁止访问目录: {d}"
            }))
            sys.exit(0)

    # 2. 危险的管道操作
    dangerous_pipes = [
        r"curl.*\|.*sh",
        r"wget.*\|.*sh",
        r"curl.*\|.*bash",
    ]
    for pattern in dangerous_pipes:
        if re.search(pattern, command):
            print(json.dumps({
                "decision": "block",
                "reason": "禁止远程代码注入"
            }))
            sys.exit(0)

    # 3. 环境变量保护
    if "ANTHROPIC_API_KEY" in command:
        print(json.dumps({
            "decision": "block",
            "reason": "禁止读取 API Key"
        }))
        sys.exit(0)

    # 4. 允许执行，但添加 warning
    if "npm install -g" in command or "pip install" in command:
        print(json.dumps({
            "decision": "allow",
            "warning": "全局安装可能影响系统环境"
        }))
        sys.exit(0)

    # 5. 默认允许
    sys.exit(0)


if __name__ == "__main__":
    main()
```

### 4.3 PostToolUse Hook 示例

```python
#!/usr/bin/env python3
"""
PostToolUse Hook — 工具执行后的自动操作
路径: ~/.claude/hooks/lint_after_write.py
"""
import os
import json
import subprocess
import sys


def main():
    event = os.environ.get("CLAUDE_HOOK_EVENT")
    tool = os.environ.get("CLAUDE_TOOL_NAME")
    tool_input = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))
    tool_output = os.environ.get("CLAUDE_TOOL_OUTPUT", "")

    if tool != "Write":
        sys.exit(0)

    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    # === 自动操作 ===

    results = []

    # 1. Python 文件 → 自动格式化
    if file_path.endswith(".py"):
        try:
            subprocess.run(
                ["black", "--quiet", file_path],
                timeout=10
            )
            results.append("✅ Black 格式化完成")
        except Exception as e:
            results.append(f"⚠️ Black 格式化失败: {e}")

    # 2. JavaScript/TypeScript 文件 → ESLint
    if file_path.endswith((".js", ".ts", ".jsx", ".tsx")):
        try:
            subprocess.run(
                ["npx", "eslint", "--fix", file_path],
                timeout=30
            )
            results.append("✅ ESLint 修复完成")
        except Exception as e:
            results.append(f"⚠️ ESLint 修复失败: {e}")

    # 3. 输出结果给 Claude Code
    if results:
        print(json.dumps({
            "notifications": results
        }))

    sys.exit(0)


if __name__ == "__main__":
    main()
```

### 4.4 SessionStart Hook 示例

```python
#!/usr/bin/env python3
"""
SessionStart Hook — 会话初始化
路径: ~/.claude/hooks/session_start.py
"""
import os
import json
import subprocess
import sys
from datetime import datetime


def main():
    working_dir = os.environ.get("CLAUDE_WORKING_DIR", os.getcwd())
    session_id = os.environ.get("CLAUDE_SESSION_ID", "unknown")

    context_info = {}

    # 1. 获取 Git 信息
    try:
        branch = subprocess.run(
            ["git", "branch", "--show-current"],
            capture_output=True, text=True, cwd=working_dir, timeout=5
        ).stdout.strip()

        if branch:
            context_info["git_branch"] = branch

        last_commit = subprocess.run(
            ["git", "log", "-1", "--format=%h %s"],
            capture_output=True, text=True, cwd=working_dir, timeout=5
        ).stdout.strip()

        if last_commit:
            context_info["last_commit"] = last_commit
    except:
        pass

    # 2. 获取项目信息
    if os.path.exists(f"{working_dir}/package.json"):
        with open(f"{working_dir}/package.json") as f:
            pkg = json.load(f)
            context_info["project"] = pkg.get("name", "unknown")
            context_info["framework"] = self._detect_framework(pkg)

    # 3. 输出上下文（注入到 System Prompt）
    context_str = "\n".join(f"{k}: {v}" for k, v in context_info.items())
    print(json.dumps({
        "context": context_str,
        "variables": context_info
    }))

    sys.exit(0)


def _detect_framework(package_json: dict) -> str:
    deps = {**package_json.get("dependencies", {}),
            **package_json.get("devDependencies", {})}
    if "react" in deps: return "React"
    if "vue" in deps: return "Vue"
    if "next" in deps: return "Next.js"
    return "Node.js"


if __name__ == "__main__":
    main()
```

## 5. Hook 输出契约

```python
"""
Hook 通过 stdout 输出 JSON 与 Claude Code Harness 通信

预处理 Hook (PreToolUse) 返回:
{
  "decision": "allow" | "block" | "warn",
  "reason": "决策原因",
  "modifiedParams": {}  // 可选的修改后参数
}

后处理 Hook (PostToolUse) 返回:
{
  "notifications": ["消息1", "消息2"],
  "additionalContext": "附加的上下文信息"
}

事件 Hook (SessionStart/SessionEnd/Stop) 返回:
{
  "context": "注入的上下文",
  "notifications": []
}
"""
```

## 6. 总结

```
Hooks 系统核心价值:

1. 自动化: 格式化、Lint、安全检查 全自动
2. 可扩展: 不修改 Claude Code 源码，用 Hook 扩展功能
3. 上下文注入: SessionStart 自动注入项目信息
4. 安全兜底: PreToolUse 做最后一道安全检查

设计模式类比:
  Hook 系统 = Chain of Responsibility + Observer

Java 类比:
  PreToolUse   = Filter / Interceptor / @Before
  PostToolUse  = @After / HandlerInterceptor.postHandle
  SessionStart = InitializingBean.afterPropertiesSet
  SessionEnd   = DisposableBean.destroy / @PreDestroy
```
