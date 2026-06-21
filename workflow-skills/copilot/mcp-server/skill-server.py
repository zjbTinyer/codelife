#!/usr/bin/env python3
"""
Workflow Skills MCP Server
===========================
把 6 个 Skill 注册为 MCP 工具，VS Code Copilot Chat 直接看到和调用。

配置方法 (VS Code settings.json):
{
  "github.copilot.advanced": {
    "mcpServers": {
      "workflow-skills": {
        "command": "python3",
        "args": ["/path/to/copilot/mcp-server/skill-server.py"],
        "cwd": "/path/to/copilot/mcp-server"
      }
    }
  }
}

依赖: pip install mcp
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# === 找到 skills 目录 ===
SCRIPT_DIR = Path(__file__).parent.resolve()
WORKFLOW_ROOT = SCRIPT_DIR.parent.parent  # copilot → workflow-skills
SKILLS_DIR = WORKFLOW_ROOT / "skills"


def run_skill(tool_name: str, args: list[str], timeout: int = 300) -> dict:
    """执行一个 Skill 并返回结构化结果"""
    skill_path = SKILLS_DIR / tool_name
    if not skill_path.exists():
        return {"error": f"Skill not found: {tool_name}", "path": str(skill_path)}

    try:
        result = subprocess.run(
            [str(skill_path)] + args,
            capture_output=True, text=True, timeout=timeout,
            cwd=os.getcwd()
        )
        return {
            "success": result.returncode == 0,
            "exit_code": result.returncode,
            "stdout": result.stdout[-3000:],  # 截断
            "stderr": result.stderr[-1000:]
        }
    except subprocess.TimeoutExpired:
        return {"error": f"Skill timed out after {timeout}s", "tool": tool_name}
    except Exception as e:
        return {"error": str(e), "tool": tool_name}


# === 工具定义 (暴露给 Copilot 的) ===
TOOLS = [
    {
        "name": "pre_mr_gate",
        "description": "提 MR 前自动门禁检查。检查 Maven 编译、单元测试、代码覆盖率(行/分支)、BDD 测试。在用户准备提 MR 时使用。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "module": {
                    "type": "string",
                    "description": "Maven 模块名，留空表示全部模块"
                },
                "coverage_line": {
                    "type": "integer",
                    "description": "行覆盖率阈值(%), 默认 80",
                    "default": 80
                },
                "coverage_branch": {
                    "type": "integer",
                    "description": "分支覆盖率阈值(%), 默认 70",
                    "default": 70
                },
                "skip_bdd": {
                    "type": "boolean",
                    "description": "是否跳过 BDD 测试",
                    "default": True
                }
            }
        }
    },
    {
        "name": "scan_triage",
        "description": "分析 SonarQube/NexusIQ/Cyberflow 扫描报告，智能分类问题并给出修复建议。可以自动修复 Sonar 代码规范问题(删未用 import、System.out→logger 等)。NexusIQ 依赖漏洞和 Cyberflow 安全问题需人工审查。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sonar_url": {
                    "type": "string",
                    "description": "SonarQube 服务器 URL，如 https://sonarqube.company.com"
                },
                "sonar_project_key": {
                    "type": "string",
                    "description": "SonarQube Project Key，如 com.company:order-service"
                },
                "auto_fix": {
                    "type": "boolean",
                    "description": "是否自动修复低风险问题(仅 Sonar 代码规范)",
                    "default": False
                },
                "dry_run": {
                    "type": "boolean",
                    "description": "预览模式，不实际修改文件",
                    "default": True
                }
            }
        }
    },
    {
        "name": "coverage_hunt",
        "description": "分析代码覆盖率缺口，找出未覆盖的方法，按高/中/低优先级排序。可以生成 JUnit 5 测试骨架(含 Mockito + @Nested 三级分类)。在覆盖率不够需要补测试时使用。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "integer",
                    "description": "目标覆盖率(%)，默认 80",
                    "default": 80
                },
                "generate_tests": {
                    "type": "boolean",
                    "description": "是否生成 JUnit 5 测试骨架",
                    "default": False
                },
                "top": {
                    "type": "integer",
                    "description": "显示 Top N 个未覆盖类",
                    "default": 10
                }
            }
        }
    },
    {
        "name": "deploy_guard",
        "description": "部署后自动健康验证。检查 /actuator/health、数据库连接、API 冒烟测试、5xx 错误指标。生产环境需确认。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "env": {
                    "type": "string",
                    "enum": ["dev", "staging", "prod"],
                    "description": "目标环境"
                },
                "skip_db": {
                    "type": "boolean",
                    "description": "是否跳过数据库检查",
                    "default": False
                },
                "confirm_prod": {
                    "type": "boolean",
                    "description": "生产环境确认(必须为 true 才能检查 prod)",
                    "default": False
                }
            },
            "required": ["env"]
        }
    },
    {
        "name": "db_inspect",
        "description": "GCP PostgreSQL 诊断工具。自动启动 Cloud SQL Proxy + SA Key 认证。支持: 全面诊断(连接数/慢查询/锁等待/缓存命中率/死元组)、列出表、查看表结构、实时监控、自定义只读查询。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "gcp_instance": {
                    "type": "string",
                    "description": "GCP Cloud SQL 实例全名: project:region:instance"
                },
                "db_name": {
                    "type": "string",
                    "description": "数据库名"
                },
                "mode": {
                    "type": "string",
                    "enum": ["diagnose", "tables", "schema", "query"],
                    "description": "模式: diagnose(全面诊断), tables(列表), schema(表结构), query(自定义查询)"
                },
                "schema_table": {
                    "type": "string",
                    "description": "表名(mode=schema 时需要)"
                },
                "custom_query": {
                    "type": "string",
                    "description": "自定义 SQL(仅允许 SELECT, mode=query 时需要)"
                }
            },
            "required": ["db_name", "mode"]
        }
    },
    {
        "name": "jenkins_debug",
        "description": "分析 Jenkins Pipeline 构建日志，定位失败 Stage，匹配 14 种错误模式，提取异常堆栈，给出修复建议。构建失败时使用。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_name": {
                    "type": "string",
                    "description": "Jenkins Job 名称"
                },
                "build_num": {
                    "type": "string",
                    "description": "Build 号，默认 lastBuild",
                    "default": "lastBuild"
                }
            },
            "required": ["job_name"]
        }
    }
]


# === MCP Server 主逻辑 ===
def main():
    # 使用 stdio 传输
    import asyncio
    try:
        from mcp.server import Server
        from mcp.server.stdio import stdio_server
        from mcp.types import Tool, TextContent
    except ImportError:
        print("请安装 MCP SDK: pip install mcp", file=sys.stderr)
        sys.exit(1)

    server = Server("workflow-skills")

    @server.list_tools()
    async def list_tools():
        return [Tool(**t) for t in TOOLS]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict):
        # 构建参数列表
        args = []

        if name == "pre_mr_gate":
            if arguments.get("module"):
                os.environ["MODULE"] = arguments["module"]
            if arguments.get("coverage_line"):
                os.environ["COVERAGE_LINE"] = str(arguments["coverage_line"])
            if arguments.get("coverage_branch"):
                os.environ["COVERAGE_BRANCH"] = str(arguments["coverage_branch"])
            if arguments.get("skip_bdd", True):
                os.environ["SKIP_BDD"] = "true"
            tool_name = "pre-mr-gate.sh"

        elif name == "scan_triage":
            args.append("--json")  # MCP 用 JSON 输出
            if arguments.get("sonar_url"):
                args.extend(["--sonar-url", arguments["sonar_url"]])
            if arguments.get("sonar_project_key"):
                args.extend(["--sonar-project-key", arguments["sonar_project_key"]])
            if arguments.get("auto_fix"):
                args.append("--auto-fix")
            if arguments.get("dry_run", True):
                args.append("--dry-run")
            tool_name = "scan-triage.py"

        elif name == "coverage_hunt":
            args.append(str(arguments.get("target", 80)))
            args.append("--json")
            if arguments.get("generate_tests"):
                args.append("--generate-tests")
                args.append("--dry-run")
            if arguments.get("top"):
                args.extend(["--top", str(arguments["top"])])
            tool_name = "coverage-hunt.py"

        elif name == "deploy_guard":
            env = arguments["env"]
            args.append(env)
            if env == "prod" and arguments.get("confirm_prod"):
                args.append("--confirm")
            if arguments.get("skip_db"):
                os.environ["SKIP_DB"] = "true"
            tool_name = "deploy-guard.sh"

        elif name == "db_inspect":
            args.extend(["--db", arguments["db_name"]])
            mode = arguments["mode"]
            args.append(f"--{mode}")
            if arguments.get("gcp_instance"):
                args.extend(["--gcp-instance", arguments["gcp_instance"]])
            if mode == "schema" and arguments.get("schema_table"):
                args.append(arguments["schema_table"])
            if mode == "query":
                args.extend(["--query", arguments["custom_query"]])
                os.environ["ALLOW_WRITE"] = "false"
            tool_name = "db-inspect.sh"

        elif name == "jenkins_debug":
            args.extend(["--job", arguments["job_name"]])
            args.extend(["--build", arguments.get("build_num", "lastBuild")])
            tool_name = "jenkins-debug.sh"

        else:
            return [TextContent(type="text", text=json.dumps(
                {"error": f"Unknown tool: {name}"}, ensure_ascii=False
            ))]

        # 执行
        result = run_skill(tool_name, args)

        return [TextContent(type="text", text=json.dumps(
            {
                "skill": name,
                "tool": tool_name,
                **result
            },
            ensure_ascii=False, indent=2
        ))]

    # 启动
    async def run():
        async with stdio_server() as (read, write):
            await server.run(read, write,
                server.create_initialization_options())

    asyncio.run(run())


if __name__ == "__main__":
    main()
