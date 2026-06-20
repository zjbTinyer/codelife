# 2.1 — 工具调用运行时机制

## 1. Claude Code 工具运行时概览

Claude Code 的 Harness 层是一个**工具调用运行时**，负责在安全可控的环境下管理 Agent 与外部世界的交互。

```
┌─────────────────────────────────────────────────────┐
│                  Claude Code Harness                 │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │  工具注册中心  │  │  权限管理器   │  │  沙箱执行器 │ │
│  │  Tool Registry│  │  Permission   │  │  Sandbox   │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                 │         │
│  ┌──────┴─────────────────┴─────────────────┴──────┐ │
│  │              工具执行流水线                      │ │
│  │  校验 → 鉴权 → 审批 → 沙箱 → 执行 → 审计        │ │
│  └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

## 2. 工具生命周期

```
工具调用的完整生命周期:

1. LLM 请求工具
   model.tool_use → {name: "Bash", input: {command: "ls"}}

2. Harness 拦截
   → 工具注册表查找
   → 权限检查
   → 沙箱策略检查

3. 用户审批 (如果需要)
   → 显示工具调用信息
   → 等待用户确认/拒绝

4. 执行
   → 设置执行上下文
   → 运行工具（可能在沙箱中）
   → 捕获输出/错误

5. 返回结果
   → tool_result 返回给 LLM
   → 审计记录写入
```

### 2.1 工具注册

Claude Code 中的工具通过注册表管理。每种工具都有明确的定义：

```json
// 工具注册表示例（概念模型）
{
  "tools": {
    "Bash": {
      "type": "shell",
      "description": "在用户环境中执行 Shell 命令",
      "requires_approval": true,
      "sandbox": "optional",
      "capabilities": ["shell", "filesystem"],
      "permissions": {
        "allowlist": ["ls", "cat", "grep", "find", "git", "npm", "python"],
        "blocklist": ["rm -rf /", "curl | sh", "sudo"],
        "dangerous_patterns": [
          "rm\\s+-rf\\s+/",
          "curl.*\\|\\s*(ba)?sh",
          "sudo\\s+",
          ">\\s*/dev/"
        ]
      }
    },
    "Read": {
      "type": "filesystem",
      "description": "读取文件内容",
      "requires_approval": false,
      "sandbox": "no",
      "capabilities": ["filesystem:read"],
      "permissions": {
        "max_file_size": "10MB",
        "allowed_paths": ["workspace", "home"]
      }
    },
    "Write": {
      "type": "filesystem",
      "description": "写入/创建文件",
      "requires_approval": true,
      "sandbox": "no",
      "capabilities": ["filesystem:write"],
      "dangerous": true
    },
    "WebFetch": {
      "type": "network",
      "description": "发送 HTTP 请求获取网页内容",
      "requires_approval": false,
      "capabilities": ["network:outbound"],
      "permissions": {
        "allowed_protocols": ["https"],
        "blocked_hosts": ["localhost", "127.0.0.1", "internal"],
        "timeout_ms": 30000
      }
    }
  }
}
```

### 2.2 工具执行引擎（概念实现）

```python
"""
Claude Code 工具运行时 — 概念实现
展示了核心的拦截、鉴权、执行机制
"""
import subprocess
import os
import re
from typing import Optional

class ToolRuntime:
    """工具调用运行时"""

    def __init__(self, settings: dict):
        self.settings = settings
        self.tool_registry = self._build_registry()
        self.audit_log = []
        self.permission_cache = {}  # session-level

    def execute(self, tool_name: str, params: dict,
                session_id: str, context: dict) -> dict:
        """执行工具调用 — 完整的拦截流程"""

        # Step 1: 查找工具
        tool_def = self.tool_registry.get(tool_name)
        if not tool_def:
            return {"error": f"Unknown tool: {tool_name}"}

        # Step 2: 参数校验
        validation = self._validate_params(tool_def, params)
        if not validation["valid"]:
            return {"error": f"参数校验失败: {validation['reason']}"}

        # Step 3: 安全扫描
        security = self._security_scan(tool_def, params)
        if security["blocked"]:
            self._audit(session_id, tool_name, params, "blocked", security["reason"])
            return {"error": f"安全策略阻止: {security['reason']}"}

        # Step 4: 权限检查
        permission = self._check_permission(tool_def, params, session_id)
        if permission == "denied":
            self._audit(session_id, tool_name, params, "denied")
            return {"error": "Permission denied"}

        if permission == "ask_user":
            # 需要用户确认（交互模式）
            if not context.get("user_approved"):
                return {
                    "needs_approval": True,
                    "tool": tool_name,
                    "params": self._redact(params)
                }

        # Step 5: 沙箱检查
        sandbox = self._setup_sandbox(tool_def, params)

        # Step 6: 执行
        try:
            result = self._do_execute(tool_def, params, sandbox)
            self._audit(session_id, tool_name, params, "success", result)
            return result
        except Exception as e:
            self._audit(session_id, tool_name, params, "error", str(e))
            return {"error": str(e)}

    def _build_registry(self):
        """构建工具注册表"""
        return {
            "Bash": {
                "type": "shell",
                "requires_approval": True,
                "dangerous_patterns": [
                    r"rm\s+-rf\s+/",
                    r"curl.*\|\s*(ba)?sh",
                    r"sudo\s+",
                    r">\s*/dev/sd",
                ],
                "allowed_commands": None,  # null = allowlist模式
                "timeout_ms": 120000,
            },
            "Read": {
                "type": "filesystem",
                "requires_approval": False,
                "timeout_ms": 5000,
            },
            "Write": {
                "type": "filesystem",
                "requires_approval": True,
                "dangerous": True,
            },
            "WebFetch": {
                "type": "network",
                "requires_approval": False,
                "allowed_protocols": ["https"],
                "timeout_ms": 30000,
            }
        }

    def _validate_params(self, tool_def: dict, params: dict) -> dict:
        """参数校验"""
        required = tool_def.get("required_params", [])
        for param in required:
            if param not in params:
                return {"valid": False, "reason": f"缺少必需参数: {param}"}

        # 长度检查
        if "command" in params and len(params["command"]) > 10000:
            return {"valid": False, "reason": "命令过长"}

        return {"valid": True}

    def _security_scan(self, tool_def: dict, params: dict) -> dict:
        """安全检查"""
        if tool_def["type"] == "shell":
            command = params.get("command", "")

            # 检查危险模式
            for pattern in tool_def.get("dangerous_patterns", []):
                if re.search(pattern, command):
                    return {"blocked": True, "reason": f"匹配危险模式: {pattern}"}

            # 检查文件描述符重定向到设备
            if re.search(r'>\s*/dev/', command):
                return {"blocked": True, "reason": "禁止直接写入设备文件"}

        return {"blocked": False}

    def _check_permission(self, tool_def: dict, params: dict,
                         session_id: str) -> str:
        """权限检查"""
        # 缓存检查
        cache_key = (session_id, tool_def.get("type", ""))
        if cache_key in self.permission_cache:
            return "allowed"

        # 需要审批
        if tool_def.get("requires_approval", False):
            return "ask_user"

        # 危险工具
        if tool_def.get("dangerous", False):
            return "denied"

        return "allowed"

    def _setup_sandbox(self, tool_def: dict, params: dict) -> dict:
        """设置沙箱"""
        sandbox = {"enabled": False}

        if tool_def["type"] == "shell":
            # 可选沙箱
            sandbox = {
                "enabled": self.settings.get("sandbox", {}).get("enabled", False),
                "allowed_paths": self.settings.get("sandbox", {}).get("paths", []),
                "network": self.settings.get("sandbox", {}).get("network", "none"),
            }

        return sandbox

    def _do_execute(self, tool_def: dict, params: dict, sandbox: dict):
        """实际执行"""
        if tool_def["type"] == "shell":
            timeout = tool_def.get("timeout_ms", 120000) / 1000
            result = subprocess.run(
                params["command"],
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=self._build_env(sandbox)
            )
            return {
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exit_code": result.returncode
            }

        # 其他工具类型...

    def _build_env(self, sandbox: dict) -> dict:
        env = os.environ.copy()
        if sandbox.get("enabled"):
            # 限制环境变量
            safe_vars = ["HOME", "PATH", "USER", "LANG"]
            env = {k: v for k, v in env.items() if k in safe_vars}
        return env

    def _audit(self, session_id: str, tool: str, params: dict,
               outcome: str, detail: any = None):
        """审计记录"""
        self.audit_log.append({
            "timestamp": time.time(),
            "session": session_id,
            "tool": tool,
            "params_summary": str(params)[:200],
            "outcome": outcome,
            "detail": str(detail)[:500] if detail else None
        })

    def _redact(self, params: dict) -> dict:
        """脱敏参数（用于显示给用户审批时）"""
        import copy
        safe = copy.deepcopy(params)
        sensitive = ["password", "token", "secret", "key"]
        for k in safe:
            if any(s in k.lower() for s in sensitive):
                safe[k] = "***"
        return safe
```

## 3. 工具执行的安全分层

```
Layer 1: 参数校验     → 格式对不对？
Layer 2: 安全扫描     → 有没有危险操作？
Layer 3: 权限检查     → 用户允不允许？
Layer 4: 用户审批     → 用户同不同意？
Layer 5: 沙箱隔离     → 执行环境安不安全？
Layer 6: 执行 & 审计  → 过程可追溯？
```

### 3.1 危险操作检测

```python
DANGEROUS_PATTERNS = [
    # 文件系统破坏
    (r"rm\s+-rf\s+/", "critical", "递归删除根目录"),
    (r"rm\s+-rf\s+~", "critical", "删除用户主目录"),
    (r">\s*/dev/sd[a-z]", "critical", "写入原始磁盘设备"),
    (r"mkfs\.", "critical", "格式化文件系统"),
    (r"dd\s+if=", "high", "磁盘低级操作"),

    # 远程代码执行
    (r"curl.*\|\s*(ba)?sh", "critical", "远程脚本直接执行"),
    (r"wget.*\|\s*(ba)?sh", "critical", "远程脚本直接执行"),
    (r"eval\s+", "high", "动态代码执行"),

    # 权限提升
    (r"sudo\s+", "high", "提权操作"),
    (r"chmod\s+777", "medium", "过度权限"),
    (r"chown\s+root", "high", "修改文件所有者为root"),

    # 系统篡改
    (r"iptables\s", "high", "修改防火墙规则"),
    (r"systemctl\s+(stop|disable)", "medium", "停止系统服务"),
]
```

## 4. 权限缓存与会话管理

```python
class PermissionManager:
    """权限管理器"""

    def __init__(self):
        # 三层权限来源
        self.session_permissions = {}  # 会话级（临时）
        self.project_permissions = {}  # 项目级 (.claude/settings.json)
        self.user_permissions = {}     # 用户级 (~/.claude/settings.json)

    def check(self, tool_name: str, action: str, session_id: str) -> str:
        """检查权限"""

        # 1. 先查会话级（最高优先级）
        session_key = f"{session_id}:{tool_name}:{action}"
        if session_key in self.session_permissions:
            return self.session_permissions[session_key]

        # 2. 再查项目级
        project_key = f"{tool_name}:{action}"
        if project_key in self.project_permissions:
            return self.project_permissions[project_key]

        # 3. 最后查用户级
        user_key = f"{tool_name}:{action}"
        if user_key in self.user_permissions:
            return self.user_permissions[user_key]

        # 4. 默认：需要审批
        return "ask"

    def grant(self, session_id: str, tool_name: str,
              action: str, permission: str, scope: str = "session"):
        """授权"""
        if scope == "session":
            self.session_permissions[f"{session_id}:{tool_name}:{action}"] = permission
        elif scope == "project":
            self.project_permissions[f"{tool_name}:{action}"] = permission
        elif scope == "user":
            self.user_permissions[f"{tool_name}:{action}"] = permission
```

## 5. 总结

```
Claude Code 工具运行时关键设计:

1. 默认不信任: 工具调用必须经过显式的权限检查
2. 纵深防御: 多层安全检查，每层互为补充
3. 可审计: 每一步操作都有记录
4. 用户可控: 关键操作需要用户审批
5. 沙箱可选: 高风险操作可在隔离环境执行

Java 类比:
  Tool Registry    = Spring BeanFactory / ApplicationContext
  Permission Check = Spring Security Filter Chain
  Audit Log        = AOP @Around advice
  Sandbox          = JVM SecurityManager
```
