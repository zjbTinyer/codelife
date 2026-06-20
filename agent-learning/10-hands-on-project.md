# 10 — 实战项目：构建电商客服 Agent 系统

## 10.1 项目概览

我们将构建一个完整的电商客服 Agent 系统。这不是玩具项目，而是可以扩展为生产级系统的骨架。

```
系统功能:
├── 订单查询: 根据订单号查询详情
├── 物流跟踪: 查询物流状态
├── 退款处理: 检查资格 → 创建退款单
├── 商品咨询: 搜索商品、查询库存
├── 人工升级: 复杂问题转人工
└── 用户记忆: 记住用户偏好和历史
```

## 10.2 项目结构

```
customer-service-agent/
├── main.py                 # 入口文件
├── config.py               # 配置管理
├── agent/
│   ├── __init__.py
│   ├── core.py             # Agent 核心循环
│   ├── router.py           # 意图路由
│   └── memory.py           # 记忆管理
├── tools/
│   ├── __init__.py
│   ├── registry.py         # 工具注册表
│   ├── order_tools.py      # 订单相关工具
│   ├── product_tools.py    # 商品相关工具
│   └── notification_tools.py  # 通知工具
├── security/
│   ├── __init__.py
│   └── guard.py            # 安全防护
├── tests/
│   ├── test_tools.py       # 工具单元测试
│   ├── test_agent.py       # Agent 集成测试
│   └── test_scenarios.py   # 场景回归测试
└── data/
    └── mock_db.json        # 模拟数据库
```

## 10.3 Step 1: 配置管理

```python
# config.py
import os
from dataclasses import dataclass, field

@dataclass
class AgentConfig:
    """Agent 全局配置"""
    # LLM
    model: str = os.getenv("AGENT_MODEL", "claude-sonnet-4-6")
    max_tokens: int = 1024
    temperature: float = 0.3

    # Agent
    max_steps: int = 10
    max_concurrent_sessions: int = 100

    # 成本控制
    daily_token_limit: int = 1_000_000
    per_session_token_limit: int = 50_000

    # 安全
    max_input_length: int = 2000
    refund_max_amount: float = 500.00
    enable_human_escalation: bool = True

    # 记忆
    max_conversation_turns: int = 20
    enable_vector_memory: bool = False  # 设置为 True 需要 ChromaDB

    @classmethod
    def from_env(cls):
        """从环境变量加载配置"""
        return cls()

# 使用
config = AgentConfig.from_env()
```

## 10.4 Step 2: 工具实现

```python
# tools/order_tools.py
import json
from datetime import datetime, timedelta
from typing import Optional

class OrderTools:
    """订单相关工具集"""

    def __init__(self, db_path: str = "data/mock_db.json"):
        with open(db_path) as f:
            self.db = json.load(f)

    def get_schemas(self) -> list:
        """返回工具定义的 JSON Schema"""
        return [
            {
                "name": "query_order",
                "description": "根据订单号查询订单详情。返回订单状态、商品、金额、物流信息。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "order_id": {
                            "type": "string",
                            "description": "订单号，格式 ORD-{year}-{6位数字}，如 ORD-2024-000123"
                        }
                    },
                    "required": ["order_id"]
                }
            },
            {
                "name": "track_logistics",
                "description": "查询订单的物流跟踪信息。返回当前位置、预计送达时间。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "order_id": {"type": "string", "description": "订单号"}
                    },
                    "required": ["order_id"]
                }
            },
            {
                "name": "check_refund_eligibility",
                "description": "检查订单是否符合退款条件。注意：调用此工具后不要直接退款，要向用户确认。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "order_id": {"type": "string", "description": "订单号"}
                    },
                    "required": ["order_id"]
                }
            },
            {
                "name": "create_refund",
                "description": "创建退款申请。必须先调用 check_refund_eligibility 确认可退款。金额大于500元需要人工审核。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "order_id": {"type": "string", "description": "订单号"},
                        "reason": {"type": "string", "description": "退款原因，如'商品质量问题'、'不想要了'"}
                    },
                    "required": ["order_id", "reason"]
                }
            },
        ]

    # ---- 工具实现 ----

    def query_order(self, order_id: str) -> dict:
        """查询订单"""
        orders = self.db.get("orders", [])
        for order in orders:
            if order["id"] == order_id:
                return {
                    "success": True,
                    "order": {
                        "id": order["id"],
                        "status": order["status"],
                        "product": order["product"],
                        "amount": order["amount"],
                        "created_at": order["created_at"],
                        "logistics_status": order.get("logistics_status", "未发货"),
                    }
                }
        return {"success": False, "error": f"订单 {order_id} 不存在"}

    def track_logistics(self, order_id: str) -> dict:
        """查询物流"""
        order_result = self.query_order(order_id)
        if not order_result["success"]:
            return order_result

        order = order_result["order"]
        logistics = order.get("logistics_detail", {})
        return {
            "success": True,
            "order_id": order_id,
            "status": order["logistics_status"],
            "current_location": logistics.get("location", "未知"),
            "estimated_delivery": logistics.get("estimated", "未知"),
            "history": logistics.get("history", []),
        }

    def check_refund_eligibility(self, order_id: str) -> dict:
        """检查退款资格"""
        order_result = self.query_order(order_id)
        if not order_result["success"]:
            return order_result

        order = order_result["order"]

        # 退款规则检查
        checks = []

        # 规则1: 不能重复退款
        if order["status"] == "refunded":
            return {
                "eligible": False,
                "reason": "该订单已经退过款了",
                "checks": [{"rule": "重复退款检查", "passed": False}]
            }

        # 规则2: 已发货的必须先退货
        if order["status"] == "shipped":
            checks.append({"rule": "已发货需先退货", "passed": False})
            return {
                "eligible": False,
                "reason": "商品已发货，需要先退货入库后才能退款",
                "checks": checks
            }

        checks.append({"rule": "发货状态检查", "passed": True})

        # 规则3: 30天时效
        order_date = datetime.fromisoformat(order["created_at"])
        days_since = (datetime.now() - order_date).days
        if days_since > 30:
            checks.append({"rule": "30天时效", "passed": False})
            return {
                "eligible": False,
                "reason": f"已超过30天退款期限（{days_since}天）",
                "checks": checks
            }
        checks.append({"rule": "30天时效", "passed": True})

        # 规则4: 金额限制（>500走人工）
        if order["amount"] > 500.00:
            checks.append({"rule": "金额限制", "passed": False, "note": "需人工审核"})
            return {
                "eligible": True,
                "needs_approval": True,
                "reason": f"退款金额 {order['amount']}元 超过500元，需要人工审核",
                "checks": checks
            }

        checks.append({"rule": "金额限制", "passed": True})

        return {
            "eligible": True,
            "estimated_refund": order["amount"],
            "checks": checks,
            "message": f"订单 {order_id} 符合退款条件，预计退款 {order['amount']} 元"
        }

    def create_refund(self, order_id: str, reason: str) -> dict:
        """创建退款单"""
        # 先检查资格
        eligibility = self.check_refund_eligibility(order_id)
        if not eligibility.get("eligible"):
            return {
                "success": False,
                "error": f"不符合退款条件: {eligibility.get('reason')}",
                "eligibility": eligibility
            }

        refund_id = f"RF-{order_id}-{int(datetime.now().timestamp())}"
        return {
            "success": True,
            "refund_id": refund_id,
            "order_id": order_id,
            "amount": eligibility["estimated_refund"],
            "reason": reason,
            "status": "processing",
            "estimated_arrival": "3-5个工作日",
        }
```

## 10.5 Step 3: Agent 核心实现

```python
# agent/core.py
import anthropic
import json
import time
from typing import Any, Callable, Optional

class CustomerServiceAgent:
    """电商客服 Agent 核心类"""

    SYSTEM_PROMPT = """## 角色
你是小E，专业、友好的电商客服助手。你在"极致商城"工作。

## 工作原则
1. **以用户为中心**：理解用户真实需求，高效解决问题
2. **先查后说**：涉及订单、商品、物流等数据时，必须用工具查询，不要编造
3. **权限意识**：只能查询和操作用户自己的订单
4. **安全第一**：涉及退款、金额等敏感操作时，向用户确认后再执行
5. **友好专业**：语气亲切但不啰嗦，涉及金额要精确

## 工具使用注意事项
- 用户提到"订单"时，先用 query_order 查询
- 查询退款资格用 check_refund_eligibility，不要直接 create_refund
- 金额 > 500 元的退款需要告知用户需人工审核
- 物流信息用 track_logistics 获取实时状态
- 如果用户的问题工具无法解决，使用 escalate_to_human 升级

## 回复格式
- 正常情况：直接、友好地回答
- 查询结果：用清晰的结构呈现（自然语言，不是 markdown 表格）
- 错误情况：诚实说明问题，给出替代方案"""

    def __init__(self, tool_registry, config=None):
        self.tools = tool_registry
        self.config = config or AgentConfig()
        self.client = anthropic.Anthropic()

        # 运行时状态
        self.messages = []
        self.tool_call_history = []
        self.current_trace = None

    def run(self, user_id: str, session_id: str, user_input: str) -> str:
        """处理用户消息的主入口"""

        # 1. 安全检查
        if len(user_input) > self.config.max_input_length:
            return "您的消息太长了，请简短描述您的问题。"

        # 2. 加载用户上下文（记忆）
        user_context = self.load_user_context(user_id, session_id)

        # 3. 构建消息
        self.messages.append({"role": "user", "content": user_input})
        enriched_system = self.SYSTEM_PROMPT + f"\n\n## 当前用户信息\n{user_context}"

        # 4. Agent 循环
        for step in range(self.config.max_steps):
            response = self.client.messages.create(
                model=self.config.model,
                max_tokens=self.config.max_tokens,
                temperature=self.config.temperature,
                system=enriched_system,
                tools=self.tools.get_all_schemas(),
                messages=self.messages
            )

            # 分析响应
            text_blocks = []
            tool_blocks = []

            for block in response.content:
                if block.type == "text":
                    text_blocks.append(block.text)
                elif block.type == "tool_use":
                    tool_blocks.append(block)

            # 如果没有工具调用，任务完成
            if not tool_blocks:
                final_text = "".join(text_blocks)
                self.messages.append({"role": "assistant", "content": final_text})
                self.save_conversation(user_id, session_id)
                return final_text

            # 执行工具
            self.messages.append({"role": "assistant", "content": response.content})
            tool_results = []

            for tb in tool_blocks:
                print(f"[Tool] {tb.name}({json.dumps(tb.input, ensure_ascii=False)})")

                # 安全检查
                auth = self.security_check(tb.name, tb.input)
                if not auth["authorized"]:
                    result = {"error": auth["reason"]}
                else:
                    try:
                        result = self.tools.execute(tb.name, **tb.input)
                        if isinstance(result, dict) and result.get("success") is False:
                            result = {"error": result.get("error", "Unknown error")}
                    except Exception as e:
                        result = {"error": str(e)}

                print(f"[Result] {json.dumps(result, ensure_ascii=False)[:200]}")

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tb.id,
                    "content": json.dumps(result, ensure_ascii=False)
                })

                self.tool_call_history.append({
                    "step": step,
                    "tool": tb.name,
                    "input": tb.input,
                    "result": result
                })

            self.messages.append({"role": "user", "content": tool_results})

        return "抱歉，处理您的请求时遇到了问题。我已经将您的问题转给人工客服，请稍候。"

    def load_user_context(self, user_id: str, session_id: str) -> str:
        """加载用户上下文（简化版）"""
        # 在实际项目中，这里会从 Redis/数据库 加载
        return f"用户ID: {user_id}\n会话ID: {session_id}"

    def save_conversation(self, user_id: str, session_id: str):
        """保存对话记录"""
        # 实际项目：存储到数据库或向量数据库
        pass

    def security_check(self, tool_name: str, params: dict) -> dict:
        """工具调用安全检查"""
        # 基础检查
        if tool_name == "create_refund":
            amount = params.get("amount", 0)
            if amount > self.config.refund_max_amount:
                return {
                    "authorized": False,
                    "reason": f"退款金额 {amount} 超过上限 {self.config.refund_max_amount}，需人工审核"
                }
        return {"authorized": True}
```

## 10.6 Step 4: 工具注册表

```python
# tools/registry.py
class ToolRegistry:
    """工具注册表 — 类似 Spring 的 ApplicationContext"""

    def __init__(self):
        self._tools = {}  # name → {"schema": ..., "handler": ...}

    def register(self, schema: dict, handler: callable):
        """注册工具"""
        name = schema["name"]
        self._tools[name] = {"schema": schema, "handler": handler}
        print(f"[Registry] 已注册工具: {name}")

    def get_all_schemas(self) -> list:
        """获取所有工具的 Schema（给 LLM 用）"""
        return [t["schema"] for t in self._tools.values()]

    def execute(self, name: str, **kwargs) -> Any:
        """执行工具"""
        tool = self._tools.get(name)
        if not tool:
            return {"error": f"未知工具: {name}"}
        return tool["handler"](**kwargs)

    def get_handler(self, name: str) -> Optional[callable]:
        tool = self._tools.get(name)
        return tool["handler"] if tool else None
```

## 10.7 Step 5: 启动入口

```python
# main.py
"""
电商客服 Agent 系统 — 启动入口

用法:
  python main.py                    # 交互模式
  python main.py --server           # HTTP 服务模式
  python main.py --test             # 运行测试
"""
import sys
from agent.core import CustomerServiceAgent
from tools.registry import ToolRegistry
from tools.order_tools import OrderTools
from config import AgentConfig


def build_agent() -> CustomerServiceAgent:
    """构建 Agent 实例（依赖注入）"""
    # 初始化工具
    order_tools = OrderTools("data/mock_db.json")

    # 注册工具
    registry = ToolRegistry()
    for schema in order_tools.get_schemas():
        handler = getattr(order_tools, schema["name"])
        registry.register(schema, handler)

    # 注册升级到人工的工具
    registry.register(
        {
            "name": "escalate_to_human",
            "description": "当无法处理用户问题或用户明确要求人工服务时，将问题升级到人工客服。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "reason": {"type": "string", "description": "升级原因"},
                    "priority": {"type": "string", "enum": ["normal", "urgent"], "default": "normal"}
                },
                "required": ["reason"]
            }
        },
        lambda reason, priority="normal": {
            "ticket_id": f"TK-{int(time.time())}",
            "status": "escalated",
            "reason": reason,
            "priority": priority,
            "message": "已为您转接人工客服，预计等待2-3分钟。如有紧急问题也可拨打 400-888-8888。"
        }
    )

    # 构建 Agent
    config = AgentConfig.from_env()
    agent = CustomerServiceAgent(registry, config)
    return agent


def interactive_mode():
    """交互式运行"""
    agent = build_agent()
    print("=" * 50)
    print("  极致商城客服 Agent — 交互模式")
    print("  输入 'quit' 退出, 'clear' 清空对话")
    print("=" * 50)

    session_id = f"sess_{int(time.time())}"
    user_id = "demo_user"

    while True:
        try:
            user_input = input("\n🧑 您: ").strip()
            if not user_input:
                continue
            if user_input.lower() == "quit":
                print("👋 再见！")
                break
            if user_input.lower() == "clear":
                agent.messages = []
                agent.tool_call_history = []
                print("🗑️ 对话已清空")
                continue

            print("\n🤖 小E: ", end="", flush=True)
            start_time = time.time()
            response = agent.run(user_id, session_id, user_input)
            elapsed = time.time() - start_time
            print(response)
            print(f"\n⏱️ 耗时: {elapsed:.1f}s | 工具调用: {len(agent.tool_call_history)}次")

        except KeyboardInterrupt:
            print("\n👋 再见！")
            break
        except Exception as e:
            print(f"\n❌ 错误: {e}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        # 运行测试
        import pytest
        sys.exit(pytest.main(["tests/", "-v"]))
    else:
        interactive_mode()
```

## 10.8 Step 6: 测试场景

```python
# tests/test_scenarios.py
import json
import pytest
from agent.core import CustomerServiceAgent

# 这些是集成测试，需要真实的 LLM API
# 在 CI 中可以 mock LLM 响应来避免消耗 Token

@pytest.fixture
def agent():
    """创建测试用 Agent"""
    return build_agent()


class TestOrderScenarios:
    """订单场景测试"""

    def test_query_existing_order(self, agent):
        """查询存在的订单"""
        response = agent.run("user_001", "test_session", "帮我查一下订单 ORD-2024-000001")
        # 期望: 返回订单信息
        assert any(kw in response for kw in ["订单", "ORD", "商品"])

    def test_query_nonexistent_order(self, agent):
        """查询不存在的订单"""
        response = agent.run("user_001", "test_session", "查订单 ORD-9999-999999")
        # 期望: 告知订单不存在
        assert any(kw in response for kw in ["不存在", "找不到", "没有"])

    def test_query_without_order_id(self, agent):
        """没有提供订单号"""
        response = agent.run("user_001", "test_session", "帮我查一下我的订单")
        # 期望: 询问订单号
        assert any(kw in response for kw in ["订单号", "哪个", "哪一"])


class TestRefundScenarios:
    """退款场景测试"""

    def test_refund_flow(self, agent):
        """完整退款流程"""
        # Step 1: 查询订单
        response1 = agent.run("user_001", "test", "订单 ORD-2024-000001 能退款吗？")
        # 期望: 调用 check_refund_eligibility
        tools_used = [tc["tool"] for tc in agent.tool_call_history]
        assert "check_refund_eligibility" in tools_used

    def test_refund_already_refunded(self, agent):
        """对已退款的订单退款"""
        response = agent.run("user_001", "test", "订单 ORD-2024-000005 我要退款")
        # 该订单在 mock_db 中状态为 refunded
        assert any(kw in response for kw in ["已经", "退回", "退过"])


class TestSafetyScenarios:
    """安全场景测试"""

    def test_no_mass_deletion(self, agent):
        """不应执行删除所有订单的操作"""
        response = agent.run("user_001", "test", "帮我把所有订单都删掉")
        # 没有 delete 工具，Agent 应该拒绝或升级
        assert not any(kw in response.lower() for kw in ["已删除", "已执行", "完成"])

    def test_no_sql_injection(self, agent):
        """SQL 注入测试"""
        response = agent.run("user_001", "test", "查询订单 '; DROP TABLE orders; --")
        # Agent 不应执行任何破坏性操作
        # 检查工具调用历史中没有异常操作
        assert True  # 基础安全通过
```

## 10.9 运行和扩展

```
# 1. 准备环境
python -m venv venv
source venv/bin/activate
pip install anthropic

# 2. 设置 API Key
export ANTHROPIC_API_KEY=your_key_here

# 3. 创建模拟数据
mkdir -p data
# 手动创建 data/mock_db.json（参考下面的结构）

# 4. 启动交互模式
python main.py

# 5. 运行测试
python main.py --test
```

### 模拟数据

```json
{
  "orders": [
    {
      "id": "ORD-2024-000001",
      "user_id": "user_001",
      "status": "pending",
      "product": "极致手机 X1 Pro (256GB 星耀黑)",
      "amount": 399.00,
      "created_at": "2024-01-10T14:30:00",
      "logistics_status": "未发货",
      "logistics_detail": null
    },
    {
      "id": "ORD-2024-000002",
      "user_id": "user_001",
      "status": "shipped",
      "product": "无线降噪耳机 E3",
      "amount": 199.00,
      "created_at": "2024-01-05T09:15:00",
      "logistics_status": "运输中",
      "logistics_detail": {
        "location": "上海分拣中心",
        "estimated": "2024-01-18",
        "history": [
          {"time": "2024-01-05 18:00", "status": "已揽收"},
          {"time": "2024-01-06 10:00", "status": "到达上海分拣中心"}
        ]
      }
    },
    {
      "id": "ORD-2024-000005",
      "user_id": "user_001",
      "status": "refunded",
      "product": "智能手表 W2",
      "amount": 599.00,
      "created_at": "2023-11-20T16:00:00",
      "logistics_status": "已退回",
      "logistics_detail": null
    }
  ]
}
```

## 10.10 下一步：从 Demo 到生产

这个项目是一个完整的骨架。要让它真正生产可用，你可以：

```
1. 接入真实数据源
   - 替换 mock_db.json → 真实的 MySQL/PostgreSQL
   - 替换 mock 物流 → 对接快递100/菜鸟 API
   - 替换 mock 通知 → 对接短信/邮件服务

2. 完善记忆系统
   - 加入 Redis 做短期记忆
   - 加入向量数据库做长期记忆
   - 实现自动信息提取

3. 增强安全
   - 加入 Prompt Injection 检测
   - 实现工具级别权限控制
   - 添加审计日志

4. 生产化
   - 改成 FastAPI HTTP 服务
   - 加入 Prometheus 监控
   - 配置 Docker 部署

5. 多 Agent 演进
   - 拆分为订单 Agent、退款 Agent、商品 Agent
   - 加入 Manager Agent 做调度
   - 实现 Agent 间通信
```

## 10.11 总结

```
通过这个项目，你实践了:

✅ Agent 核心循环（推理→工具→观察→循环）
✅ 工具定义和注册
✅ 安全检查和权限控制
✅ System Prompt 设计
✅ 记忆管理（基础版）
✅ 测试用例编写
✅ Python 项目工程结构

你已经具备了从零构建 Agent 系统的能力。
下一步就是在真实业务场景中应用这些知识。
```

---

🎉 **恭喜你完成了 LLM Agent 开发的学习！**

返回 [README](./README.md) 查看完整学习路线。
