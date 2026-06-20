# 01 — Agent 核心概念

## 1.1 什么是 Agent？

> **Agent（智能体）** = LLM（大脑） + 工具（手脚） + 记忆（经验） + 规划（策略）

传统 LLM 调用是"一问一答"：你给 prompt，它返回文本。Agent 则是一个**自主决策的循环**：

```
传统 LLM:
  用户输入 → LLM 推理 → 文本输出（结束）

Agent:
  用户输入 → LLM 推理 → 决定行动 → 调用工具 → 观察结果 → 再次推理 → ... → 最终输出
              ↑______________________________________________________________↓
                                  (循环直到任务完成)
```

### 类比：Java 开发者视角

| Agent 概念 | Java 类比 |
|-----------|----------|
| Agent | 一个 **while 循环**中的 `DispatcherServlet` |
| LLM 推理 | `Service` 层的业务判断逻辑 |
| Tool | `@Service` Bean 的方法（访问 DB/RPC/文件） |
| Memory | Session + Redis 缓存 + 数据库持久化 |
| Planning | 工作流引擎（如 Activiti/Flowable）的流程定义 |

## 1.2 Agent 的四大核心组件

```
┌──────────────────────────────────────────────┐
│                  Agent                        │
│  ┌─────────┐  ┌─────────┐                   │
│  │   LLM   │  │  Tools  │                   │
│  │  (大脑)  │  │ (手脚)  │                   │
│  └────┬─────┘  └────┬─────┘                  │
│       │              │                        │
│  ┌────┴──────────────┴─────┐                  │
│  │       Memory (记忆)      │                  │
│  └─────────────────────────┘                  │
│  ┌─────────────────────────┐                  │
│  │    Planning (规划能力)    │                  │
│  └─────────────────────────┘                  │
└──────────────────────────────────────────────┘
```

### 2.1 LLM — 大脑

负责理解任务、推理决策、生成响应。选择 LLM 考虑三个维度：

- **推理能力**：能否理解复杂任务、多步推理
- **工具调用能力**：能否正确选择和调用工具
- **成本与延迟**：每秒生成 token 数、每 1K token 价格

```python
# 最简 Agent 调用示例
import anthropic

client = anthropic.Anthropic()
response = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=1024,
    system="你是一个有用的助手，可以用工具完成任务。",
    messages=[{"role": "user", "content": "帮我查一下北京今天的天气"}]
)
# 此时模型只能"说"天气，不能"查"天气 — 因为没有工具
```

### 2.2 Tools — 手脚

工具是 Agent 与外部世界交互的能力。常见工具类型：

| 工具类型 | 示例 | Java 类比 |
|---------|------|----------|
| API 调用 | 查询天气、发送邮件 | `RestTemplate` / Feign |
| 数据库 | 查询订单、写入日志 | MyBatis Mapper |
| 文件系统 | 读写文件、创建目录 | `java.io.File` |
| 代码执行 | 运行 Python、SQL | `Runtime.exec()` |
| 搜索 | Google/Bing/内部知识库 | Elasticsearch |

### 2.3 Memory — 记忆

Agent 的记忆分为三个层次，类比计算机存储：

| 记忆层 | 作用 | 技术实现 | 类比 |
|--------|------|---------|------|
| **对话上下文** | 当前会话的历史 | LLM 的 messages 数组 | 内存 RAM |
| **短期记忆** | 跨会话但近期的信息 | Redis / 会话存储 | Redis 缓存 |
| **长期记忆** | 持久化知识 | 向量数据库 / RAG | MySQL/磁盘 |

### 2.4 Planning — 规划

规划决定 Agent 的"智商上限"。两种主要范式：

- **ReAct（边想边做）**：每步推理 → 行动 → 观察 → 继续推理
- **Plan-Execute（先规划后执行）**：先制定完整计划 → 逐步执行 → 根据反馈调整

## 1.3 Agent 的完整执行流程

用一个具体例子说明——让 Agent "帮我查北京天气，如果下雨就发邮件提醒我"：

```
Step 1 (LLM推理): 用户想知道北京天气并条件性发邮件
                  → 我需要先查天气

Step 2 (工具调用): weather_api.get("北京")
                  → 返回: {"weather": "中雨", "temp": 18}

Step 3 (LLM推理): 是下雨天，需要发送邮件提醒
                  → 需要知道收件人邮箱

Step 4 (LLM输出): "检测到北京今天有中雨。请问发送到哪个邮箱？"
                  (如果记忆中已有邮箱，则直接调用邮件工具)

Step 5 (工具调用): email_api.send(to="user@example.com", body="...")
                  → 返回: {"status": "sent"}

Step 6 (最终输出): "已帮您查询：北京今天中雨，18°C。
                   邮件已发送至 user@example.com"
```

## 1.4 Agent vs 传统程序 vs 工作流

这是很多 Java 工程师最容易困惑的地方：

| 维度 | 传统程序 | 工作流引擎 | Agent |
|------|---------|-----------|-------|
| 流程定义 | 硬编码 if/else | XML/BPMN 预定义 | **LLM 动态决定** |
| 异常处理 | try-catch 固定 | 预定义补偿流程 | **LLM 自主判断重试/绕过** |
| 适用场景 | 确定性逻辑 | 半确定性流程 | **高度不确定性任务** |
| 可预测性 | 100% 确定 | 分支可穷举 | 非确定性 |
| 开发方式 | 编写代码 | 画流程图 | **写 Prompt + 定义工具** |

**核心洞察**：Agent 不是要替代传统程序，而是在**不确定性高、规则难以穷举**的场景中发挥作用。你的系统中：
- 核心交易逻辑 → 传统代码
- 审批流程 → 工作流引擎
- 智能客服、数据分析 → Agent

## 1.5 Agent 的能力边界

```
确定性低 ←————————————————————————→ 不确定性高

  if/else      工作流       规则引擎      Agent
  (计算折扣)   (审批流)     (风控规则)   (客服对话)
```

**Agent 不擅长的：**
- 精确数学计算（让 LLM 用代码解释器工具）
- 需要事务保证的操作（用传统代码）
- 对延迟极度敏感的场景（>2s 响应）
- 需要 100% 确定性的场景

**Agent 擅长的：**
- 开放式任务（"帮我分析这份报告"）
- 需要多步推理的问题
- 工具组合使用
- 自然语言交互场景

## 1.6 第一个最小 Agent

```python
"""
最小可运行 Agent — 只有 LLM + 1个工具
需要先安装: pip install anthropic
需要设置: export ANTHROPIC_API_KEY=your_key
"""
import anthropic
import json

# 1. 定义工具
TOOLS = [
    {
        "name": "get_weather",
        "description": "获取指定城市的天气",
        "input_schema": {
            "type": "object",
            "properties": {
                "city": {
                    "type": "string",
                    "description": "城市名称，如 '北京'"
                }
            },
            "required": ["city"]
        }
    }
]

# 2. 工具实现（实际项目中会调用真实API）
def get_weather(city: str) -> dict:
    # 模拟天气数据
    weather_db = {
        "北京": {"weather": "晴", "temp": 25},
        "上海": {"weather": "多云", "temp": 28},
    }
    return weather_db.get(city, {"weather": "未知", "temp": 0})


# 3. Agent 核心循环
def run_agent(user_query: str, max_steps: int = 5):
    client = anthropic.Anthropic()
    messages = [{"role": "user", "content": user_query}]

    for step in range(max_steps):
        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            system="你是助手，可以调用工具获取信息。如果信息足够就回答用户。",
            tools=TOOLS,
            messages=messages
        )

        # 检查是否需要调用工具
        tool_use = None
        text_response = ""

        for block in response.content:
            if block.type == "tool_use":
                tool_use = block
            elif block.type == "text":
                text_response += block.text

        # 如果没有工具调用，说明任务完成
        if tool_use is None:
            return text_response

        # 4. 执行工具并反馈结果
        print(f"[Step {step+1}] 调用工具: {tool_use.name}({tool_use.input})")

        if tool_use.name == "get_weather":
            result = get_weather(**tool_use.input)
        else:
            result = {"error": f"未知工具: {tool_use.name}"}

        # 将工具结果加入对话
        messages.append({"role": "assistant", "content": response.content})
        messages.append({
            "role": "user",
            "content": [{
                "type": "tool_result",
                "tool_use_id": tool_use.id,
                "content": json.dumps(result, ensure_ascii=False)
            }]
        })

    return "任务步骤过多，已终止。"


# 5. 运行
if __name__ == "__main__":
    result = run_agent("北京今天天气怎么样？")
    print(f"\n最终回答: {result}")
```

### 运行结果示例

```
[Step 1] 调用工具: get_weather({'city': '北京'})

最终回答: 北京今天天气晴朗，气温25°C，适合户外活动。
```

## 1.7 总结

```
记住一个公式:
  Agent = LLM + Tools + Memory + Planning Loop

记住一个循环:
  推理 → 决策 → 行动 → 观察 → 推理 → ...

记住一个原则:
  Agent 擅长不确定性任务，确定性逻辑留给传统代码
```

---

**下一步**：[02-LLM 基础](./02-llm-basics.md) — 深入理解 LLM API 调用机制
