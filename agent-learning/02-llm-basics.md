# 02 — LLM 基础

## 2.1 LLM API 调用本质

不管用哪个厂商的 LLM，API 调用的本质都一样：

```python
# 伪代码：所有 LLM API 的通用模式
response = llm.chat(
    model="模型名称",           # 选哪个模型
    system="系统提示词",        # 设定角色/规则
    messages=[...],             # 对话历史
    max_tokens=4096,            # 最大输出长度
    temperature=0.7,            # 随机性控制
    tools=[...],                # 可用工具定义(Agent关键)
    stop=["<END>"]              # 停止符
)
```

### Java 开发者类比

```java
// LLM API 像是一个极度灵活的 REST 接口
@PostMapping("/v1/messages")
public ChatResponse chat(@RequestBody ChatRequest request) {
    // request.model       → 选择模型
    // request.system      → 相当于 @ConditionalOnProperty
    // request.messages    → 相当于 HTTP Session 中的对话
    // request.tools       → 相当于注入的 @Service Bean 列表
    // request.max_tokens  → 相当于 limit/offset
    // request.temperature → 相当于随机种子
}
```

## 2.2 核心参数详解

### Model（模型选择）

| 维度 | Sonnet/Haiku 类 | Opus/GPT-4 类 | 选择建议 |
|------|----------------|--------------|---------|
| 推理深度 | 中等 | 深 | 复杂 Agent 用强模型 |
| 速度 | 快 (~50 tok/s) | 慢 (~20 tok/s) | 简单任务用快模型 |
| 成本 | 低 ($3/1M tok) | 高 ($15/1M tok) | 批量用便宜模型 |
| 工具调用 | 良好 | 优秀 | 多工具场景用强模型 |
| 典型场景 | 分类、摘要、翻译 | 代码生成、复杂推理 | 路由任务分级处理 |

```python
# 模型路由策略：根据任务复杂度选模型
def choose_model(task_complexity: str) -> str:
    routes = {
        "simple": "claude-haiku-4-5",      # 分类、简单问答
        "medium": "claude-sonnet-4-6",     # 工具调用、中等推理
        "complex": "claude-opus-4-8",      # 复杂推理、代码生成
    }
    return routes.get(task_complexity, "claude-sonnet-4-6")
```

### Messages（对话结构）

```python
# Messages 是对话的完整上下文
messages = [
    # 第一条：用户输入
    {"role": "user", "content": "帮我查北京天气"},

    # 第二条：模型回复（可能包含工具调用）
    {"role": "assistant", "content": [
        {"type": "text", "text": "我来帮你查询。"},
        {"type": "tool_use", "id": "tool_001", "name": "weather", "input": {"city": "北京"}}
    ]},

    # 第三条：工具执行结果（role 仍然是 user）
    {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "tool_001", "content": '{"temp": 25}'}
    ]},

    # 第四条：模型最终回答
    {"role": "assistant", "content": "北京今天25°C，晴天。"}
]
```

**关键点**：Messages 数组越长，成本越高、延迟越大。这就是为什么需要记忆管理（第 05 章）。

### Temperature（随机性）

```
temperature = 0.0  →  确定性输出，适合分类/提取
temperature = 0.7  →  创意输出，适合写作/头脑风暴
temperature = 1.0+ →  随机输出，几乎不可用
```

Agent 场景建议：**工具选择用低 temperature (0~0.3)，最终回复可以稍高 (0.5~0.7)**。

### Max Tokens（输出长度限制）

```
token ≠ 字符 ≠ 中文汉字

粗略估算:
- 1 个英文单词 ≈ 1.3 tokens
- 1 个中文汉字 ≈ 2 tokens
- 1 行代码 ≈ 5-10 tokens
```

Agent 场景特别要注意：`max_tokens` 不够时，模型的工具调用可能被截断，导致 Agent "卡死"。

## 2.3 System Prompt — Agent 的"宪法"

System Prompt 是 Agent 行为的根本约束。它相当于微服务的 bootstrap.yml + 代码规范。

### System Prompt 四要素

```markdown
## 1. 角色定义（你是谁）
你是一个专业的客服 Agent，负责处理电商平台的售后问题。

## 2. 行为约束（什么能做、什么不能做）
- 只能查询自己负责的订单，不能查询其他客服的订单
- 退款金额超过 500 元时必须请求人工审核
- 不能承诺法律没有规定的赔偿

## 3. 工具使用规则（何时用什么工具）
- 用户提到"查订单"时，使用 query_order 工具
- 用户要求退款时，先用 check_refund_policy 核实规则
- 用户投诉时，记录到工单系统后再回复

## 4. 输出格式规范
- 回复用口语化的中文
- 涉及金额时精确到分
- 每次回复末尾附上工单编号
```

### 完整示例

```python
SYSTEM_PROMPT = """## 角色
你是一个电商售后客服 Agent，工号 CS-2024。

## 可用工具
- query_order(order_id): 查询订单详情
- check_refund(order_id): 检查是否可退款
- create_refund(order_id, amount, reason): 创建退款单
- escalate_to_human(reason): 升级到人工客服

## 工作流程
1. 收到用户请求后，先确认订单号
2. 如果用户没有提供订单号，礼貌地请用户提供
3. 查询订单后，用表格展示关键信息
4. 退款金额 >500 元：调用 escalate_to_human
5. 退款金额 ≤500 元：调用 create_refund 执行退款

## 禁止行为
- 不要编造订单信息
- 不要承诺"一定会退款"（需系统核实）
- 不要透露其他客户的订单信息
"""

# 使用
response = client.messages.create(
    model="claude-sonnet-4-6",
    system=SYSTEM_PROMPT,
    messages=[{"role": "user", "content": "我的订单 ORD-1234 想退款"}]
)
```

## 2.4 Token 管理与成本控制

### Token 计数器（tiktoken）

```python
import tiktoken

# Anthropic 用 cl100k_base 编码
encoding = tiktoken.get_encoding("cl100k_base")

def count_tokens(text: str) -> int:
    return len(encoding.encode(text))

# 估算一次调用的成本
system_tokens = count_tokens(SYSTEM_PROMPT)     # ~200 tokens
history_tokens = count_tokens(str(messages))     # ~500 tokens
output_tokens = 200                              # 预估输出

total_cost = (system_tokens + history_tokens) * 0.003 / 1000 \
           + output_tokens * 0.015 / 1000

print(f"估算成本: ${total_cost:.4f}")
```

### 成本优化策略

```
1. 【缩短 System Prompt】
   ❌ 写 2000 字的角色设定
   ✅ 只写关键规则，用 <50 字

2. 【裁剪对话历史】
   ❌ 保留全部 50 轮对话
   ✅ 只保留最近 5-10 轮 + 摘要

3. 【分级用模型】
   ❌ 所有请求都用最强模型
   ✅ 简单的分类用 Haiku，复杂推理才用 Opus

4. 【缓存复用】
   ❌ 每次传完整的 System Prompt
   ✅ 利用 Prompt Caching（Anthropic 5分钟缓存）
```

## 2.5 Prompt 工程基础

### Chain of Thought（思维链）

```python
# ❌ 直接让模型输出答案
prompt = "这段代码有什么bug？"

# ✅ 让模型先分析再回答
prompt = """请按以下步骤分析这段代码：
1. 先逐行阅读，标注每行的作用
2. 检查潜在的逻辑错误
3. 检查潜在的边界条件问题
4. 最后总结所有发现的bug

代码：
{code}"""
```

### Few-Shot Prompting（少样本提示）

```python
FEW_SHOT_PROMPT = """将用户查询转换为结构化数据。

示例1:
输入: "查一下今年3月到5月的销售额"
输出: {"metric": "sales", "start": "2024-03", "end": "2024-05"}

示例2:
输入: "上周新增了多少用户"
输出: {"metric": "new_users", "start": "2024-w25", "end": "2024-w25"}

示例3:
输入: "北京地区的退款率是多少"
输出: {"metric": "refund_rate", "filters": {"region": "北京"}}

现在请处理:
输入: "{user_input}"
输出:"""
```

### Structured Output（结构化输出）

Agent 中大量使用结构化输出，让模型返回 JSON 而不是自然语言：

```python
# 定义输出格式
import json

prompt = """分析用户意图并返回JSON:

{
  "intent": "refund | inquiry | complaint",
  "confidence": 0.0-1.0,
  "entities": {
    "order_id": "订单号或null",
    "product": "商品名或null"
  },
  "sentiment": "positive | neutral | negative"
}

用户输入: {user_input}
只返回JSON，不要其他文字。"""

# 解析时防御性处理
try:
    intent_data = json.loads(response_text)
except json.JSONDecodeError:
    # 模型可能返回了额外文字，尝试提取JSON
    import re
    match = re.search(r'\{.*\}', response_text, re.DOTALL)
    intent_data = json.loads(match.group()) if match else None
```

## 2.6 API 调用最佳实践

```python
import time
from typing import Optional

class LLMClient:
    """带重试和错误处理的 LLM 客户端"""

    def __init__(self, max_retries: int = 3):
        self.client = anthropic.Anthropic()
        self.max_retries = max_retries

    def call(self, system: str, messages: list,
             model: str = "claude-sonnet-4-6",
             max_tokens: int = 1024,
             tools: Optional[list] = None) -> dict:
        """统一调用封装"""

        for attempt in range(self.max_retries):
            try:
                kwargs = {
                    "model": model,
                    "system": system,
                    "messages": messages,
                    "max_tokens": max_tokens,
                }
                if tools:
                    kwargs["tools"] = tools

                response = self.client.messages.create(**kwargs)
                return {"success": True, "response": response}

            except anthropic.APIError as e:
                if "rate_limit" in str(e).lower():
                    wait = 2 ** attempt  # 指数退避
                    print(f"[Rate Limited] 等待 {wait}s 后重试...")
                    time.sleep(wait)
                elif attempt == self.max_retries - 1:
                    return {"success": False, "error": str(e)}
                else:
                    time.sleep(1)

        return {"success": False, "error": "max_retries exceeded"}

    def extract_text(self, response) -> str:
        """从响应中提取文本内容"""
        texts = []
        for block in response.content:
            if block.type == "text":
                texts.append(block.text)
        return "".join(texts)

    def extract_tool_calls(self, response) -> list:
        """从响应中提取工具调用"""
        return [b for b in response.content if b.type == "tool_use"]
```

## 2.7 总结

```
核心要点:
1. LLM API = 模型 + System Prompt + Messages + 参数
2. System Prompt 是 Agent 的"宪法"，决定行为边界
3. Token 管理 = 成本管理，每次调用都要算账
4. 结构化输出比自然语言更可靠，Agent 中用 JSON Schema 约束
5. 调用封装：重试 + 指数退避 + 错误处理
```

---

**下一篇**：[03-Tool Use & Function Calling](./03-tool-use-function-calling.md)
