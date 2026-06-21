#!/bin/bash
# ============================================================
# PostToolUse Hook — 文件写入后自动格式化 + 通知
# ============================================================
# 放在 ~/.claude/hooks/ 或 .claude/hooks/
#
# 在 settings.json 中配置:
# {
#   "hooks": {
#     "PostToolUse": [{
#       "matcher": "Write",
#       "command": "~/.claude/hooks/post-tool-use-notify.sh"
#     }]
#   }
# }
# ============================================================

EVENT="${CLAUDE_HOOK_EVENT:-}"
TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# 只处理 Write 工具
if [ "$TOOL_NAME" != "Write" ]; then
    exit 0
fi

FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""' 2>/dev/null || echo "")

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
    exit 0
fi

notifications=()

# ===== 自动格式化 =====

# Java 文件 → 不自动格式化（尊重项目配置）
# 项目通常有自己的 checkstyle/formatter 配置
if [[ "$FILE_PATH" == *.java ]]; then
    # 可选: 用 checkstyle 验证
    if command -v mvn &>/dev/null && [ -f "pom.xml" ]; then
        if mvn checkstyle:check -q 2>/dev/null; then
            notifications+=("✅ Java 格式检查通过: $(basename "$FILE_PATH")")
        fi
    fi
fi

# Python 文件 → black
if [[ "$FILE_PATH" == *.py ]] && command -v black &>/dev/null; then
    black --quiet "$FILE_PATH" 2>/dev/null && \
        notifications+=("✅ Black 格式化: $(basename "$FILE_PATH")")
fi

# Shell 文件 → 检查语法
if [[ "$FILE_PATH" == *.sh ]]; then
    if bash -n "$FILE_PATH" 2>/dev/null; then
        notifications+=("✅ Shell 语法检查通过: $(basename "$FILE_PATH")")
    else
        notifications+=("⚠️  Shell 语法有误: $(basename "$FILE_PATH")")
    fi
fi

# YAML 文件 → 格式验证
if [[ "$FILE_PATH" == *.yml || "$FILE_PATH" == *.yaml ]]; then
    if command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('$FILE_PATH'))" 2>/dev/null; then
            notifications+=("✅ YAML 格式有效: $(basename "$FILE_PATH")")
        fi
    fi
fi

# 输出通知
if [ ${#notifications[@]} -gt 0 ]; then
    json_notifications=$(printf '%s\n' "${notifications[@]}" | jq -R . | jq -s .)
    echo "{\"notifications\": $json_notifications}"
fi

exit 0
