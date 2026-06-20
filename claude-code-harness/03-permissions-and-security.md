# 2.3 — 权限系统设计

## 1. Claude Code 权限模型

Claude Code 的权限系统采用**分层 + 缓存 + 用户审批**的设计，在安全性和可用性之间取得平衡。

```
权限系统的核心矛盾:
  太严格 → 每个操作都要确认 → 用户烦 → 关闭权限检查
  太宽松 → 危险操作直接执行 → 安全风险 → 不敢用

Claude Code 的解法:
  分层权限 + 智能缓存 + 一键永久授权
```

## 2. 三层权限架构

```
┌─────────────────────────────────────────────────┐
│              权限来源 (优先级从高到低)            │
├─────────────────────────────────────────────────┤
│  Layer 1: 会话级权限 (Session)                   │
│  ├─ 生命周期: 当前会话                           │
│  ├─ 来源: 运行时用户批准                         │
│  └─ 优先级: 最高                                 │
├─────────────────────────────────────────────────┤
│  Layer 2: 项目级权限 (Project)                   │
│  ├─ 生命周期: 项目持续                           │
│  ├─ 来源: .claude/settings.json                  │
│  └─ 优先级: 中                                   │
├─────────────────────────────────────────────────┤
│  Layer 3: 用户全局权限 (User)                    │
│  ├─ 生命周期: 永久                               │
│  ├─ 来源: ~/.claude/settings.json                │
│  └─ 优先级: 低（项目可覆盖）                     │
└─────────────────────────────────────────────────┘
```

## 3. 权限配置规范

### 3.1 settings.json 中的权限块

```json
{
  "permissions": {
    "allow": [
      "Bash(npm:*)",
      "Bash(git:*)",
      "Bash(python:*)",
      "Bash(node:*)",
      "Read",
      "WebFetch"
    ],
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(sudo *)",
      "Bash(curl * | sh)"
    ],
    "ask": [
      "Bash(docker:*)",
      "Bash(kubectl:*)",
      "Write",
      "Edit"
    ],
    "defaultMode": "ask"
  }
}
```

### 3.2 权限匹配语法

```
权限条目的模式匹配:

精确匹配:
  "Read"              → 匹配 Read 工具的所有调用
  "Write"             → 匹配 Write 工具的所有调用

命令前缀匹配:
  "Bash(npm:*)"       → 匹配所有以 "npm" 开头的 Bash 命令
  "Bash(git:*)"       → 匹配所有以 "git" 开头的 Bash 命令
  "Bash(ls:*)"        → 匹配 ls, "ls -la", "ls /path" 等

否定匹配:
  "deny": ["Bash(rm:*)"]
  → 禁止所有以 rm 开头的命令（覆盖 allow）

通配符:
  "*"                 → 匹配所有
  "Bash(*)"           → 匹配所有 Bash 命令
```

### 3.3 实际配置示例

```json
// 适用于 Java 项目的权限配置
{
  "permissions": {
    "allow": [
      // 构建工具
      "Bash(mvn:*)",
      "Bash(gradle:*)",
      "Bash(npm:*)",
      "Bash(pnpm:*)",

      // 版本控制
      "Bash(git:*)",

      // 基础命令
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(cd:*)",
      "Bash(echo:*)",

      // Java 工具
      "Bash(java:*)",
      "Bash(javac:*)",

      // 包管理
      "Bash(pip:*)",
      "Bash(pip3:*):",

      // 只读工具
      "Read",
      "WebFetch",
      "WebSearch"
    ],
    "deny": [
      // 危险操作
      "Bash(rm -rf /*)",
      "Bash(sudo *)",
      "Bash(curl * | *)",
      "Bash(wget * | *)"
    ],
    "ask": [
      // 文件修改
      "Write",
      "Edit",

      // 容器和编排
      "Bash(docker:*)",
      "Bash(kubectl:*):",

      // 网络工具
      "Bash(curl:*)",
      "Bash(wget:*)"
    ],
    "defaultMode": "ask"
  }
}
```

## 4. 权限管理器实现（概念）

```python
import re
import fnmatch
from typing import Literal

PermissionMode = Literal["allow", "deny", "ask"]


class PermissionEngine:
    """权限引擎 — 多层权限合并与匹配"""

    def __init__(self):
        self.rules = {
            "session": {"allow": [], "deny": [], "ask": []},
            "project": {"allow": [], "deny": [], "ask": []},
            "user": {"allow": [], "deny": [], "ask": []},
        }
        self.default_mode = "ask"

    def load_user_config(self, config: dict):
        """加载用户全局配置 ~/.claude/settings.json"""
        self._load_layer("user", config)

    def load_project_config(self, config: dict):
        """加载项目配置 .claude/settings.json"""
        self._load_layer("project", config)

    def grant_session(self, tool: str, mode: PermissionMode):
        """会话级临时授权"""
        self.rules["session"][mode].append(tool)

    def check(self, tool_name: str, tool_input: dict = None) -> PermissionMode:
        """检查权限 — 按优先级查询"""

        # 构建匹配用的字符串
        match_strings = [tool_name]
        if tool_name == "Bash" and tool_input:
            command = tool_input.get("command", "")
            first_word = command.split()[0] if command.strip() else command
            match_strings.append(f"Bash({command})")      # 完整命令
            match_strings.append(f"Bash({first_word}:*)") # 命令前缀

        # 按优先级检查: session → project → user
        for layer in ["session", "project", "user"]:
            for mode in ["deny", "allow", "ask"]:
                for rule in self.rules[layer][mode]:
                    for ms in match_strings:
                        if self._match(ms, rule):
                            print(f"[Permission] {layer}/{mode}: {ms} 匹配 {rule}")
                            return mode

        return self.default_mode

    def _match(self, target: str, pattern: str) -> bool:
        """检查 target 是否匹配 pattern"""
        # 精确匹配
        if target == pattern:
            return True

        # 通配符匹配
        if fnmatch.fnmatch(target, pattern):
            return True

        # Bash 命令前缀匹配: Bash(npm:*) → 匹配 Bash(npm install express)
        if "Bash(" in pattern and "Bash(" in target:
            pattern_cmd = pattern[5:-1]  # 提取命令部分
            target_cmd = target[5:-1]    # 提取命令部分

            # 前缀匹配 (npm:*, git:*, etc.)
            if pattern_cmd.endswith(":*"):
                prefix = pattern_cmd[:-2]
                return target_cmd == prefix or target_cmd.startswith(prefix + " ")

            # 通配符
            if fnmatch.fnmatch(target_cmd, pattern_cmd):
                return True

        return False

    def _load_layer(self, layer: str, config: dict):
        """加载权限层"""
        permissions = config.get("permissions", {})
        for mode in ["allow", "deny", "ask"]:
            rules = permissions.get(mode, [])
            if isinstance(rules, list):
                self.rules[layer][mode] = rules

        if "defaultMode" in permissions:
            self.default_mode = permissions["defaultMode"]


# ===== 使用示例 =====

engine = PermissionEngine()

# 加载配置
engine.load_user_config({
    "permissions": {
        "allow": ["Bash(npm:*)", "Bash(git:*)" , "Read"],
        "deny": ["Bash(rm:*)"],
        "defaultMode": "ask"
    }
})

# 检查
result = engine.check("Bash", {"command": "npm install express"})
print(f"npm install → {result}")  # "allow"

result = engine.check("Bash", {"command": "rm -rf /tmp"})
print(f"rm -rf → {result}")       # "deny"

result = engine.check("Bash", {"command": "curl https://api.example.com"})
print(f"curl → {result}")         # "ask"

result = engine.check("Write", {"file_path": "/tmp/test.py"})
print(f"Write → {result}")        # "ask"
```

## 5. 权限升级与审批流程

```python
class ApprovalFlow:
    """权限审批流程"""

    def __init__(self, permission_engine: PermissionEngine):
        self.engine = permission_engine
        self.approved_in_session = set()

    def request_approval(self, tool_name: str, params: dict) -> dict:
        """请求用户审批"""

        # 检查是否已在本次会话中批准
        approval_key = self._approval_key(tool_name, params)
        if approval_key in self.approved_in_session:
            return {"approved": True, "source": "session_cache"}

        # 构建审批展示信息
        display_info = self._build_display(tool_name, params)

        # 返回审批请求（在实际 CLI 中会展示给用户）
        return {
            "approved": False,
            "needs_approval": True,
            "display": display_info,
            "options": [
                {"id": "yes_once", "label": "允许本次", "scope": "once"},
                {"id": "yes_always", "label": "总是允许此命令", "scope": "session"},
                {"id": "yes_always_permanent", "label": "永久允许", "scope": "user"},
                {"id": "no", "label": "拒绝", "scope": None},
            ]
        }

    def handle_approval(self, tool_name: str, params: dict,
                        option_id: str) -> bool:
        """处理用户的审批选择"""
        if option_id == "no":
            return False

        if option_id == "yes_once":
            return True

        if option_id == "yes_always":
            approval_key = self._approval_key(tool_name, params)
            self.approved_in_session.add(approval_key)
            return True

        if option_id == "yes_always_permanent":
            self.engine.grant_session(tool_name, "allow")
            return True

        return False

    def _approval_key(self, tool_name: str, params: dict) -> str:
        """生成审批缓存键"""
        if tool_name == "Bash":
            # 用命令的第一个词做 key
            command = params.get("command", "")
            first_word = command.split()[0] if command.strip() else command
            return f"Bash:{first_word}"
        return tool_name

    def _build_display(self, tool_name: str, params: dict) -> str:
        """构建给用户展示的信息"""
        if tool_name == "Bash":
            return f"执行命令: {params.get('command', '')}"
        elif tool_name == "Write":
            return f"写入文件: {params.get('file_path', '')}"
        elif tool_name == "Edit":
            return f"编辑文件: {params.get('file_path', '')}"
        return f"调用工具: {tool_name}"
```

## 6. 安全最佳实践

```json
// 推荐的权限配置文件结构
{
  "permissions": {
    // 1. 明确 allow — 只放你完全信任的操作
    "allow": [
      "Read",              // 读文件无害
      "WebSearch",         // 只读的搜索
      "Bash(ls:*)",        // ls 是安全的
      "Bash(cat:*)",       // cat 是只读的
      "Bash(git:status)",  // git status 是只读的
      "Bash(git:diff)",    // git diff 是只读的
      "Bash(git:log)"      // git log 是只读的
    ],

    // 2. 明确的 deny — 危险操作
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(sudo *)",
      "Bash(curl * | *)",
      "Bash(> /dev/*)"
    ],

    // 3. 其余的靠 ask 兜底
    "defaultMode": "ask"
  }
}
```

```
权限原则:

1. 最小权限: 只授权必要的最小范围
   ✅ "Bash(npm:test)"  — 只允许 npm test
   ❌ "Bash(npm:*)"     — 允许所有 npm 命令（虽然方便但不安全）

2. 分层管理:
   用户级: 个人偏好（如 "总是允许 git"）
   项目级: 项目特定的工具（如项目的构建命令）
   会话级: 临时授权

3. deny 优先: deny 规则在任何层级都能覆盖 allow

4. 定期审查: 定期检查权限配置，回收不再需要的授权
```

## 7. 总结

```
Claude Code 权限系统设计要点:

1. 分层架构: Session > Project > User，灵活且可控
2. 模式匹配: 支持精确匹配、前缀匹配、通配符
3. 审批缓存: 同一次会话内记住用户的审批决定
4. deny 优先: 安全规则在任何层级都不可被覆盖
5. 默认安全: defaultMode=ask，未知操作必须审批

Java 类比:
  权限分层    = Spring Security Filter Chain
  模式匹配    = AntPathMatcher / @RequestMapping
  审批流程    = OAuth2 Authorization Code Flow
  会话缓存    = SecurityContextHolder
  deny 优先   = @PreAuthorize("denyAll()")
```
