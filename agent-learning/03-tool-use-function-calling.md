# 03 — 工具调用 (Tool Use / Function Calling)

## 3.1 为什么 Agent 需要工具？

LLM 本身是一个"纯大脑"：能思考、能理解，但没有手脚。它的知识截止于训练日期，不能实时查询，不能操作外部系统。

```
LLM 本身能做到的:
✅ "Python 的 list 和 tuple 有什么区别？"
✅ "帮我写一段快速排序的代码"
✅ "把这段英文翻译成中文"

LLM 本身做不到的:
❌ "今天北京天气怎么样？"           → 需要调用天气 API
❌ "帮我查一下订单 ORD-1234 的状态"  → 需要查询数据库
❌ "把这个 Excel 转成 CSV"           → 需要文件系统操作
❌ "现在几点？"                      → 需要获取当前时间
```

**工具 = Agent 的感官和四肢。**有了工具，Agent 才能从"聊天机器人"进化成"能办事的助手"。

## 3.2 工具的定义

### Anthropic (Claude) 格式

```python
# 工具定义的 JSON Schema 格式
TOOL_SCHEMA = {
    "name": "query_database",         # 工具名（模型用它来选择和调用）
    "description": "查询MySQL数据库，执行SELECT语句。只读操作，不支持INSERT/UPDATE/DELETE。",  # 何时调用
    "input_schema": {                  # 输入参数格式
        "type": "object",
        "properties": {
            "sql": {
                "type": "string",
                "description": "要执行的SELECT查询语句"
            },
            "limit": {
                "type": "integer",
                "description": "最大返回行数，默认100",
                "default": 100
            }
        },
        "required": ["sql"]            # 必填参数
    }
}
```

### OpenAI 格式（对比）

```python
# OpenAI 的函数定义格式
OPENAI_TOOL = {
    "type": "function",
    "function": {
        "name": "query_database",
        "description": "查询MySQL数据库，执行SELECT语句。",
        "parameters": {
            "type": "object",
            "properties": {
                "sql": {"type": "string", "description": "SELECT语句"},
                "limit": {"type": "integer", "description": "最大行数", "default": 100}
            },
            "required": ["sql"]
        }
    }
}
```

### 工具定义的黄金法则

```
1. name: 动词_名词，清晰表达动作
   ✅ "search_customer", "create_order"
   ❌ "tool1", "do_something"

2. description: 写清楚"何时用、做什么、有什么限制"
   ✅ "查询指定订单ID的详情。仅限当前登录客服负责的订单。"
   ❌ "查询订单"

3. input_schema: 参数描述要具体
   ✅ {"order_id": "订单号，格式如 ORD-2024-XXXX"}
   ❌ {"id": "ID"}
```

## 3.3 工具调用的完整流程

```python
"""
工具调用执行引擎 — Agent 的核心循环
"""
import anthropic
import json

client = anthropic.Anthropic()

# ============================================
# 步骤1: 定义工具注册表
# ============================================
TOOL_REGISTRY = {
    "get_time": {
        "schema": {
            "name": "get_time",
            "description": "获取当前系统时间",
            "input_schema": {
                "type": "object",
                "properties": {
                    "timezone": {
                        "type": "string",
                        "description": "时区，如 Asia/Shanghai，默认 Asia/Shanghai"
                    }
                }
            }
        },
        "handler": lambda **kwargs: {"time": "2024-01-15 14:30:00 CST"}
    },

    "query_db": {
        "schema": {
            "name": "query_db",
            "description": "查询数据库。仅支持SELECT语句。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "sql": {"type": "string", "description": "SELECT 查询语句"}
                },
                "required": ["sql"]
            }
        },
        "handler": lambda sql, **kwargs: {
            "rows": [{"id": 1, "name": "张三", "balance": 150.00}],
            "count": 1
        }
    },

    "send_email": {
        "schema": {
            "name": "send_email",
            "description": "发送邮件。收件人必须是已验证的内部邮箱。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": "收件人邮箱"},
                    "subject": {"type": "string", "description": "邮件主题"},
                    "body": {"type": "string", "description": "邮件正文"}
                },
                "required": ["to", "subject", "body"]
            }
        },
        "handler": lambda **kwargs: {"status": "sent", "message_id": "msg_001"}
    }
}

# ============================================
# 步骤2: Agent 执行循环
# ============================================
def run_agent(user_input: str, max_steps: int = 10) -> str:
    """Agent 核心循环：推理 → 行动 → 观察 → 重复"""

    messages = [{"role": "user", "content": user_input}]
    tool_schemas = [t["schema"] for t in TOOL_REGISTRY.values()]

    for step in range(max_steps):
        # 调用 LLM
        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            system="""你是一个有用的助手。遵循以下原则：
1. 如果需要实时信息（时间、数据），使用工具获取
2. 每次调用一个工具，观察结果后再决定下一步
3. 当信息足够时，直接回答用户
4. 如果工具调用失败，尝试其他方式或告知用户""",
            tools=tool_schemas,
            messages=messages
        )

        # 解析响应
        text_block = None
        tool_blocks = []

        for block in response.content:
            if block.type == "text":
                text_block = block.text
            elif block.type == "tool_use":
                tool_blocks.append(block)

        # 情况A: 纯文本回复 → 任务完成
        if not tool_blocks:
            print(f"[Step {step+1}] LLM 回复: {text_block[:100]}...")
            return text_block

        # 情况B: 有工具调用 → 执行并反馈
        print(f"[Step {step+1}] 调用了 {len(tool_blocks)} 个工具")

        # 步骤3: 将模型响应加入对话
        messages.append({"role": "assistant", "content": response.content})

        # 步骤4: 执行每个工具
        tool_results = []
        for tb in tool_blocks:
            tool_name = tb.name
            tool_input = tb.input

            print(f"  → {tool_name}({json.dumps(tool_input, ensure_ascii=False)})")

            # 执行工具
            tool_def = TOOL_REGISTRY.get(tool_name)
            if tool_def:
                try:
                    result = tool_def["handler"](**tool_input)
                except Exception as e:
                    result = {"error": str(e)}
            else:
                result = {"error": f"Unknown tool: {tool_name}"}

            print(f"  ← 结果: {json.dumps(result, ensure_ascii=False)[:100]}")

            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tb.id,
                "content": json.dumps(result, ensure_ascii=False)
            })

        # 步骤5: 将工具结果加入对话
        messages.append({"role": "user", "content": tool_results})

    return "任务步骤过多，已终止。请简化需求。"


# ============================================
# 步骤3: 测试
# ============================================
if __name__ == "__main__":
    result = run_agent("现在几点了？顺便查一下数据库里有多少用户。")
    print(f"\n{'='*50}")
    print(f"最终回复:\n{result}")
```

## 3.4 工具调用的高级模式

### 3.4.1 并行工具调用

```python
# 当 LLM 在一次响应中返回多个 tool_use block：
# 这些工具没有依赖关系 → 可以并行执行
import concurrent.futures

def execute_tools_parallel(tool_blocks: list) -> list:
    """并行执行独立的工具调用"""
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        futures = {}
        for tb in tool_blocks:
            tool_def = TOOL_REGISTRY.get(tb.name)
            if tool_def:
                future = executor.submit(tool_def["handler"], **tb.input)
                futures[future] = tb

        results = []
        for future in concurrent.futures.as_completed(futures):
            tb = futures[future]
            try:
                result = future.result()
            except Exception as e:
                result = {"error": str(e)}
            results.append({
                "type": "tool_result",
                "tool_use_id": tb.id,
                "content": json.dumps(result)
            })
        return results


# ⚠️ 注意：只有独立工具才能并行
# ✅ 可以并行: 同时查天气A和天气B
# ❌ 不能并行: 先查询订单 → 根据结果决定退款 → 发邮件通知
```

### 3.4.2 工具调用链（串行依赖）

```python
# 有些工具之间有依赖，必须串行执行
# 例如：查订单 → 核实退款资格 → 创建退款单

ORDER_WORKFLOW = {
    "query_order": {
        "schema": {...},
        "handler": query_order_handler
    },
    "check_refund_eligibility": {
        "schema": {
            "name": "check_refund_eligibility",
            "description": "检查订单是否满足退款条件。必须先调用 query_order。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "order_id": {"type": "string"},
                    "order_status": {"type": "string", "description": "来自 query_order 的结果"}
                },
                "required": ["order_id", "order_status"]
            }
        },
        "handler": check_refund_handler
    },
    "create_refund": {
        "schema": {...},
        "handler": create_refund_handler
    }
}
```

### 3.4.3 工具错误处理策略

```python
def execute_tool_with_retry(tool_name: str, tool_input: dict,
                            max_retries: int = 2) -> dict:
    """带智能错误处理的工具执行"""

    tool_def = TOOL_REGISTRY.get(tool_name)

    for attempt in range(max_retries + 1):
        try:
            result = tool_def["handler"](**tool_input)

            # 业务层面的错误也要处理
            if isinstance(result, dict) and result.get("error"):
                error_msg = result["error"]

                # 如果是参数错误，不要重试
                if "invalid" in error_msg.lower():
                    return {
                        "success": False,
                        "error": error_msg,
                        "retryable": False,
                        "suggestion": "请检查参数后重新调用"
                    }

                # 如果是超时或网络错误，可以重试
                if "timeout" in error_msg.lower() or "network" in error_msg.lower():
                    if attempt < max_retries:
                        continue
                    return {
                        "success": False,
                        "error": error_msg,
                        "retryable": False,
                        "suggestion": "该服务暂时不可用，请稍后重试或告知用户"
                    }

            return {"success": True, "data": result}

        except Exception as e:
            if attempt < max_retries:
                continue
            return {
                "success": False,
                "error": str(e),
                "retryable": False,
                "suggestion": "工具执行失败，请告知用户当前无法完成此操作"
            }
```

## 3.5 工具设计的反模式 🚫

### 反模式1: 万能工具

```python
# ❌ 一个工具做所有事
{
    "name": "do_everything",
    "description": "查询、修改、删除、发送、创建...",
    "input_schema": {
        "properties": {
            "action": {"type": "string"},  # 什么都能传
            "params": {"type": "object"}   # 参数不明确
        }
    }
}
# 问题：LLM 不知道该何时用，参数容易传错

# ✅ 每个工具职责单一
{
    "name": "query_order",
    "description": "根据订单号查询订单详情",
    "input_schema": {
        "properties": {
            "order_id": {"type": "string", "description": "订单号 ORD-XXXX"}
        },
        "required": ["order_id"]
    }
}
```

### 反模式2: 参数过多

```python
# ❌ 15 个参数，LLM 容易遗漏或填错
{
    "name": "search_products",
    "input_schema": {
        "properties": {
            "keyword": ..., "category": ..., "min_price": ...,
            "max_price": ..., "brand": ..., "color": ...,
            "size": ..., "rating": ..., "sort_by": ...,
            "page": ..., "page_size": ..., "in_stock": ...,
            "free_shipping": ..., "discount_only": ...,
            "warehouse_id": ..., "seller_id": ...
        }
    }
}

# ✅ 核心参数必填 + 可选过滤器
{
    "name": "search_products",
    "input_schema": {
        "properties": {
            "keyword": {"type": "string", "description": "搜索关键词"},
            "filters": {
                "type": "object",
                "description": "可选的过滤条件",
                "properties": {
                    "price_range": {"type": "string", "description": "如 '100-500'"},
                    "in_stock_only": {"type": "boolean"}
                }
            }
        },
        "required": ["keyword"]
    }
}
```

### 反模式3: 描述与实现不一致

```python
# ❌ 描述说"只查已完成的订单"，但实现查了所有订单
{
    "name": "query_completed_orders",
    "description": "查询已完成的订单",
    "handler": lambda: db.query("SELECT * FROM orders")  # 没有 WHERE status='completed'
}

# ✅ 描述和实现对齐，或者在 handler 里校验
{
    "handler": lambda status=None: db.query(
        "SELECT * FROM orders WHERE status = ?", status or "completed"
    )
}
```

## 3.6 工具安全

```python
# 安全是 Agent 工具的第一要务
# 类比：Agent 的工具 = 对外暴露的 API，需要鉴权 + 限流 + 审计

def safe_db_query(sql: str, allowed_tables: set = None) -> dict:
    """安全的数据库查询工具"""

    # 1. 白名单校验：只允许 SELECT
    sql_upper = sql.strip().upper()
    if not sql_upper.startswith("SELECT"):
        return {"error": "仅允许 SELECT 查询"}

    # 2. 禁止危险关键字
    dangerous_keywords = ["DROP", "DELETE", "INSERT", "UPDATE", "ALTER", "EXEC", "--"]
    for kw in dangerous_keywords:
        if kw in sql_upper:
            return {"error": f"禁止使用 {kw}"}

    # 3. 表级白名单
    if allowed_tables:
        for table in allowed_tables:
            if table.lower() not in sql.lower():
                return {"error": f"仅允许查询表: {allowed_tables}"}

    # 4. 超时控制
    import signal
    def handler(signum, frame):
        raise TimeoutError("查询超时")
    signal.signal(signal.SIGALRM, handler)
    signal.alarm(5)  # 5秒超时

    try:
        result = execute_query(sql)
        return {"rows": result, "count": len(result)}
    except TimeoutError:
        return {"error": "查询超时，请缩小查询范围"}
    finally:
        signal.alarm(0)
```

## 3.7 实战：构建一个完整的工具集

```python
"""
完整的 Agent 工具集 — 电商客服场景
包含：查询、操作、通知 三类工具
"""

class CustomerServiceTools:
    """客服 Agent 工具集"""

    def __init__(self, db_connection):
        self.db = db_connection
        self.schemas = [
            self._query_order_schema(),
            self._query_user_schema(),
            self._check_refund_schema(),
            self._create_refund_schema(),
            self._send_notification_schema(),
        ]

    # ——— 工具定义 ———

    def _query_order_schema(self):
        return {
            "name": "query_order",
            "description": "查询订单详情。输入订单号返回订单完整信息。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "order_id": {
                        "type": "string",
                        "description": "订单号，格式 ORD-{year}-{6位数字}"
                    }
                },
                "required": ["order_id"]
            }
        }

    def query_order(self, order_id: str) -> dict:
        """查询订单实现"""
        order = self.db.query_one(
            "SELECT * FROM orders WHERE order_id = ?", order_id
        )
        if not order:
            return {"error": f"订单 {order_id} 不存在", "code": "NOT_FOUND"}
        return {"order": order, "status": "success"}

    def _query_user_schema(self):
        return {
            "name": "query_user",
            "description": "查询用户信息，包括会员等级、积分、历史订单数",
            "input_schema": {
                "type": "object",
                "properties": {
                    "user_id": {"type": "string", "description": "用户ID"}
                },
                "required": ["user_id"]
            }
        }

    def query_user(self, user_id: str) -> dict:
        user = self.db.query_one("SELECT * FROM users WHERE id = ?", user_id)
        if not user:
            return {"error": f"用户 {user_id} 不存在"}
        # 脱敏处理
        user["phone"] = user["phone"][:3] + "****" + user["phone"][-4:]
        return {"user": user}

    def _check_refund_schema(self):
        return {
            "name": "check_refund_eligibility",
            "description": "检查订单是否符合退款条件。返回是否符合 + 具体原因。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "order_id": {"type": "string", "description": "订单号"}
                },
                "required": ["order_id"]
            }
        }

    def check_refund_eligibility(self, order_id: str) -> dict:
        order = self.query_order(order_id)
        if "error" in order:
            return order

        o = order["order"]
        # 退款规则
        if o["status"] == "refunded":
            return {"eligible": False, "reason": "该订单已退款"}
        if o["status"] == "shipped":
            return {"eligible": False, "reason": "已发货，需先退货才能退款"}
        if o["amount"] > 500:
            return {"eligible": False, "reason": "金额>500元，需人工审核"}

        # 时效检查（30天内）
        from datetime import datetime, timedelta
        order_date = datetime.fromisoformat(o["created_at"])
        if datetime.now() - order_date > timedelta(days=30):
            return {"eligible": False, "reason": "超过30天退款期"}

        return {"eligible": True, "estimated_refund": o["amount"]}

    def _create_refund_schema(self):
        return {
            "name": "create_refund",
            "description": "创建退款单。必须先用 check_refund_eligibility 确认可退款。",
            "input_schema": {
                "type": "object",
                "properties": {
                    "order_id": {"type": "string"},
                    "reason": {"type": "string", "description": "退款原因"}
                },
                "required": ["order_id", "reason"]
            }
        }

    def create_refund(self, order_id: str, reason: str) -> dict:
        # 先检查
        check = self.check_refund_eligibility(order_id)
        if not check.get("eligible"):
            return {"error": f"不符合退款条件: {check.get('reason')}"}

        refund_id = f"RF-{order_id}-{int(time.time())}"
        return {
            "refund_id": refund_id,
            "amount": check["estimated_refund"],
            "status": "processing"
        }

    def _send_notification_schema(self):
        return {
            "name": "send_notification",
            "description": "给用户发送通知（短信或App推送）",
            "input_schema": {
                "type": "object",
                "properties": {
                    "user_id": {"type": "string"},
                    "message": {"type": "string", "description": "通知内容，<200字"},
                    "channel": {
                        "type": "string",
                        "enum": ["sms", "app_push"],
                        "default": "app_push"
                    }
                },
                "required": ["user_id", "message"]
            }
        }

    def send_notification(self, user_id: str, message: str, channel: str = "app_push") -> dict:
        if len(message) > 200:
            return {"error": "消息超过200字限制"}
        # 实际调用短信/推送服务
        return {"status": "sent", "channel": channel}
```

## 3.8 总结

```
工具调用的核心要点:

1. 工具定义 = name + description + input_schema
   description 最重要，它告诉 LLM 什么时候用这个工具

2. Agent 核心循环：
   LLM推理 → 选择工具 → 执行工具 → 观察结果 → 继续推理

3. 安全是第一位:
   - 权限控制（Agent 能做什么）
   - 参数校验（工具收到什么）
   - 超时控制（工具执行多久）
   - 审计记录（Agent 做了什么）

4. 工具设计原则:
   - 单一职责：一个工具只做一件事
   - 描述准确：description 要和实现一致
   - 错误友好：返回结构化的错误信息，让 LLM 能理解并做出调整
```

---

**下一篇**：[04-Agent 设计模式](./04-agent-patterns.md)
