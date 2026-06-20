# 2.4 — 配置体系与最佳实践

## 1. Claude Code 配置体系概览

Claude Code 采用**多层配置合并**策略，类似 Spring Boot 的 `application.yml` 优先级覆盖。

```
配置加载优先级 (从高到低):

┌─────────────────────────────────────────┐
│ 1. 命令行参数 (--model, --verbose)       │  ← 最高优先级
├─────────────────────────────────────────┤
│ 2. 环境变量 (ANTHROPIC_API_KEY, etc.)   │
├─────────────────────────────────────────┤
│ 3. 项目本地配置                          │
│    .claude/settings.local.json          │  ← 不提交到 Git
├─────────────────────────────────────────┤
│ 4. 项目共享配置                          │
│    .claude/settings.json                │  ← 提交到 Git（团队共享）
├─────────────────────────────────────────┤
│ 5. 用户全局配置                          │
│    ~/.claude/settings.json              │  ← 个人偏好
├─────────────────────────────────────────┤
│ 6. 默认值                               │  ← 最低优先级
└─────────────────────────────────────────┘
```

## 2. 配置文件详解

### 2.1 用户全局配置 (~/.claude/settings.json)

```json
{
  // === 模型与行为 ===
  "model": "claude-sonnet-4-6",
  "temperature": 0.7,
  "maxTokens": 4096,

  // === 权限 ===
  "permissions": {
    "allow": [
      "Bash(npm:*)",
      "Bash(git:*)",
      "Bash(python:*)",
      "Read",
      "WebFetch",
      "WebSearch"
    ],
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(sudo *)",
      "Bash(curl * | *)"
    ],
    "ask": [
      "Bash(docker:*)",
      "Write",
      "Edit"
    ],
    "defaultMode": "ask"
  },

  // === Hooks ===
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "command": "python3 ~/.claude/hooks/lint_after_write.py"
      }
    ]
  },

  // === 自定义命令 / Skills ===
  "slashCommands": [
    {
      "name": "/deploy",
      "description": "部署到生产环境",
      "prompt": "执行部署流程，确认后进行"
    }
  ],

  // === 环境变量 ===
  "env": {
    "NODE_ENV": "development",
    "PYTHONPATH": "${workspaceFolder}/src"
  },

  // === 文件忽略 ===
  "ignorePatterns": [
    "node_modules/**",
    "**/*.min.js",
    "dist/**",
    ".next/**"
  ],

  // === UI/UX ===
  "theme": "dark",
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  },

  // === MCP 服务器 ===
  "mcpServers": {
    "context7": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  },

  // === 实验性功能 ===
  "enableExperimental": ["worktree_isolation"]
}
```

### 2.2 项目配置 (.claude/settings.json)

```json
{
  // 项目配置 — 提交到 Git，团队共享
  "model": "claude-sonnet-4-6",

  "permissions": {
    "allow": [
      "Bash(npm:*)",
      "Bash(pnpm:*)",
      "Bash(git:*)",
      "Bash(python:*)",
      "Bash(java:*)",
      "Bash(mvn:*)",
      "Bash(pip3:*)",
      "Read",
      "WebFetch"
    ],
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(sudo *)",
      "Bash(ssh *)"
    ],
    "ask": [
      "Bash(docker:*)",
      "Bash(kubectl:*)",
      "Write",
      "Edit"
    ],
    "defaultMode": "ask"
  },

  // 项目级环境变量
  "env": {
    "JAVA_HOME": "/usr/lib/jvm/java-8",
    "PYTHONPATH": "${workspaceFolder}:${workspaceFolder}/src"
  },

  // 项目级忽略
  "ignorePatterns": [
    "node_modules/**",
    ".gradle/**",
    "build/**",
    "target/**",
    "*.class",
    "*.jar"
  ],

  // 项目级 Hooks
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "command": "python3 .claude/hooks/format_check.py"
      }
    ]
  }
}
```

### 2.3 本地覆盖 (.claude/settings.local.json)

```json
{
  // 不提交到 Git — 个人开发环境差异
  "model": "claude-opus-4-8",  // 我喜欢用更强的模型

  "env": {
    "DEBUG": "true",
    "LOG_LEVEL": "debug",
    "MY_API_KEY": "sk-xxxx"    // 本地密钥，不提交
  }
}
```

## 3. 配置合并逻辑

```python
"""
多层配置合并 — 概念实现
"""
import json
import os
from copy import deepcopy


class ConfigLoader:
    """配置加载器 — 多层合并"""

    def __init__(self, workspace_path: str):
        self.workspace = workspace_path
        self.home = os.path.expanduser("~")

    def load(self) -> dict:
        """加载并合并所有层级的配置"""
        config = self._defaults()

        # Layer 5: 用户全局配置
        user_config = self._load_file(f"{self.home}/.claude/settings.json")
        config = self._deep_merge(config, user_config)

        # Layer 4: 项目共享配置
        project_config = self._load_file(f"{self.workspace}/.claude/settings.json")
        config = self._deep_merge(config, project_config)

        # Layer 3: 项目本地配置（不提交 Git）
        local_config = self._load_file(f"{self.workspace}/.claude/settings.local.json")
        config = self._deep_merge(config, local_config)

        # Layer 2: 环境变量
        env_config = self._from_env()
        config = self._deep_merge(config, env_config)

        return config

    def _defaults(self) -> dict:
        return {
            "model": "claude-sonnet-4-6",
            "temperature": 0.7,
            "maxTokens": 4096,
            "permissions": {
                "allow": [],
                "deny": [],
                "defaultMode": "ask"
            },
            "hooks": {},
            "env": {},
            "ignorePatterns": [],
        }

    def _load_file(self, path: str) -> dict:
        """安全加载配置文件"""
        if not os.path.exists(path):
            return {}
        try:
            with open(path) as f:
                return json.load(f)
        except (json.JSONDecodeError, PermissionError) as e:
            print(f"[Config] 加载 {path} 失败: {e}")
            return {}

    def _deep_merge(self, base: dict, override: dict) -> dict:
        """深度合并 — override 覆盖 base"""
        result = deepcopy(base)

        for key, value in override.items():
            if key in result and isinstance(result[key], dict) and isinstance(value, dict):
                result[key] = self._deep_merge(result[key], value)
            elif key in result and isinstance(result[key], list) and isinstance(value, list):
                # 列表：追加（而不是覆盖）
                result[key] = result[key] + value
            else:
                result[key] = deepcopy(value)

        return result

    def _from_env(self) -> dict:
        """从环境变量提取配置"""
        config = {}

        env_mappings = {
            "ANTHROPIC_API_KEY": "apiKey",
            "ANTHROPIC_MODEL": "model",
            "CLAUDE_MAX_TOKENS": "maxTokens",
        }

        for env_var, config_key in env_mappings.items():
            if env_var in os.environ:
                config[config_key] = os.environ[env_var]

        return config
```

## 4. 配置最佳实践

### 4.1 分层策略

```
.gitignore 建议:
  .claude/settings.local.json   ← 加入 .gitignore
  .claude/settings.json         ← 提交到 Git（团队共享）
```

```json
// settings.json — 团队共享的基线
{
  "model": "claude-sonnet-4-6",
  "permissions": {
    "allow": ["Bash(npm:*)", "Bash(python:*)"],
    "defaultMode": "ask"
  }
}

// settings.local.json — 个人覆盖（不提交）
{
  "model": "claude-opus-4-8"  // 你个人升级了模型
}
```

### 4.2 环境管理

```json
// 开发环境 (settings.local.json)
{
  "env": {
    "API_BASE_URL": "http://localhost:8080",
    "DEBUG": "true"
  }
}

// CI 环境 (通过环境变量)
// 不创建 settings.local.json，通过 CI pipeline 注入:
// CLAUDE_API_BASE_URL=https://api.staging.example.com
```

### 4.3 权限的渐进式收紧

```
项目初期（快速开发）:
  "permissions": {"defaultMode": "ask"}  // 都确认一次，慢慢积累 allowlist

项目稳定后:
  "permissions": {
    "allow": ["Bash(npm:*)", "Bash(git:*)", "Bash(pytest:*)"],
    "deny": ["Bash(rm -rf *)"],
    "defaultMode": "ask"
  }

生产维护期（锁定）:
  "permissions": {
    "allow": ["Read", "Bash(git:status,log,diff)"],  // 最严格
    "deny": ["Bash(*)"],
    "defaultMode": "deny"  // 默认禁止
  }
```

## 5. 配置验证

```python
class ConfigValidator:
    """配置验证器"""

    def validate(self, config: dict) -> list[str]:
        """验证配置的正确性，返回问题列表"""
        issues = []

        # 1. 模型名检查
        valid_models = [
            "claude-haiku-4-5", "claude-sonnet-4-6",
            "claude-opus-4-8", "claude-fable-5"
        ]
        if config.get("model") not in valid_models:
            issues.append(f"无效的模型: {config.get('model')}")

        # 2. Temperature 范围
        temp = config.get("temperature", 1.0)
        if not (0.0 <= temp <= 1.0):
            issues.append(f"Temperature 超出范围 [0,1]: {temp}")

        # 3. 权限配置检查
        permissions = config.get("permissions", {})
        if "defaultMode" not in permissions:
            issues.append("缺少 permissions.defaultMode")

        valid_modes = ["allow", "deny", "ask"]
        if permissions.get("defaultMode") not in valid_modes:
            issues.append(f"无效的 defaultMode: {permissions.get('defaultMode')}")

        # 4. Hooks 配置检查
        for hook_event, hook_configs in config.get("hooks", {}).items():
            for hc in hook_configs:
                if "matcher" not in hc:
                    issues.append(f"Hook [{hook_event}] 缺少 matcher")
                if "command" not in hc:
                    issues.append(f"Hook [{hook_event}] 缺少 command")

        return issues
```

## 6. 总结

```
配置管理核心原则:

1. 分层 — 全局 < 项目 < 本地 < 环境变量
2. 共享 — settings.json 提交到 Git，团队统一基线
3. 隔离 — settings.local.json 不提交，个人环境差异
4. 渐进 — 权限从宽松逐步收紧
5. 验证 — 加载时检查配置有效性

Java 类比:
  配置分层    = Spring Boot 配置优先级
  settings.json  = application.yml
  settings.local.json = application-local.yml
  环境变量注入 = $SPRING_APPLICATION_JSON
  配置合并    = PropertySource 合并逻辑
```
