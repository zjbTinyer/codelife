#!/bin/bash
# ============================================================
# PreToolUse Hook — Bash 命令执行前安全检查
# ============================================================
# 放在 ~/.claude/hooks/ 或 .claude/hooks/
#
# 在 settings.json 中配置:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "command": "~/.claude/hooks/pre-tool-use-validate.sh"
#     }]
#   }
# }
# ============================================================

# 从环境变量读取工具调用信息
EVENT="${CLAUDE_HOOK_EVENT:-}"
TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# 只处理 Bash 工具
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# 解析命令
COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null || echo "")

if [ -z "$COMMAND" ]; then
    exit 0
fi

# ===== 安全检查规则 =====

# 1. 危险文件系统操作
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+/'; then
    echo '{"decision":"block","reason":"禁止递归删除根目录"}'
    exit 0
fi

if echo "$COMMAND" | grep -qE '>\s*/dev/sd[a-z]'; then
    echo '{"decision":"block","reason":"禁止写入原始磁盘设备"}'
    exit 0
fi

# 2. 远程代码执行
if echo "$COMMAND" | grep -qE 'curl.*\|\s*(ba)?sh'; then
    echo '{"decision":"block","reason":"禁止远程脚本直接执行 (curl | sh)"}'
    exit 0
fi

if echo "$COMMAND" | grep -qE 'wget.*\|\s*(ba)?sh'; then
    echo '{"decision":"block","reason":"禁止远程脚本直接执行 (wget | sh)"}'
    exit 0
fi

# 3. 提权操作
if echo "$COMMAND" | grep -qE 'sudo\s+'; then
    echo '{"decision":"block","reason":"禁止 sudo 操作，如需提权请手动执行"}'
    exit 0
fi

# 4. 敏感环境变量泄露
if echo "$COMMAND" | grep -qE '(ANTHROPIC_API_KEY|OPENAI_API_KEY|DB_PASSWORD)'; then
    echo '{"decision":"block","reason":"禁止读取敏感环境变量"}'
    exit 0
fi

# 5. 批量危险操作 — 需要额外确认
if echo "$COMMAND" | grep -qE 'git\s+push\s+--force'; then
    echo "{\"decision\":\"warn\",\"reason\":\"强制推送 (git push --force) 可能覆盖远程历史\"}"
    exit 0
fi

if echo "$COMMAND" | grep -qE 'docker\s+(rm|prune|system\s+prune)'; then
    echo "{\"decision\":\"warn\",\"reason\":\"删除 Docker 资源，请确认\"}"
    exit 0
fi

# 默认允许
exit 0
