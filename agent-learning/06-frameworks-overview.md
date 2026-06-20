# 06 — 主流 Agent 框架对比

## 6.1 框架全景图

```
┌─────────────────────────────────────────────────────────────────┐
│                    Agent 框架生态 (2025)                         │
├──────────────┬──────────────┬──────────────┬───────────────────┤
│   原生 SDK    │   编排框架    │  多Agent框架  │   低代码平台       │
├──────────────┼──────────────┼──────────────┼───────────────────┤
│ Anthropic    │ LangChain    │ CrewAI       │ Dify             │
│ OpenAI       │ LangGraph    │ AutoGen      │ Coze             │
│              │ LlamaIndex   │              │ FastGPT          │
└──────────────┴──────────────┴──────────────┴───────────────────┘

选择建议:
  学习原理 → 原生 SDK (Anthropic/OpenAI)
  快速开发 → LangChain + LangGraph
  多Agent  → CrewAI
  低代码   → Dify / Coze
```

## 6.2 原生 SDK 对比

### Anthropic Claude

```python
# 优势: 最好的 Tool Use 实现、完善的文档、Prompt Cache
# 劣势: 仅 Claude 系列

import anthropic

client = anthropic.Anthropic()
response = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=1024,
    system="You are a helpful assistant.",
    tools=[{
        "name": "get_weather",
        "description": "Get the current weather for a location",
        "input_schema": {
            "type": "object",
            "properties": {
                "location": {"type": "string", "description": "City name"}
            },
            "required": ["location"]
        }
    }],
    messages=[{"role": "user", "content": "What's the weather in Beijing?"}]
)

# 遍历响应块
for block in response.content:
    if block.type == "text":
        print(block.text)
    elif block.type == "tool_use":
        print(f"Tool call: {block.name}({block.input})")
```

### OpenAI

```python
# 优势: 生态最大、模型选择多、Function Calling 成熟
# 劣势: API 设计较 Claude 稍复杂

from openai import OpenAI

client = OpenAI()
response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "What's the weather in Beijing?"}],
    tools=[{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {"type": "string", "description": "City name"}
                },
                "required": ["location"]
            }
        }
    }]
)

msg = response.choices[0].message
if msg.tool_calls:
    for tc in msg.tool_calls:
        print(f"Tool call: {tc.function.name}({tc.function.arguments})")
```

## 6.3 LangChain

### 定位

LangChain 是 Agent 开发的事实标准框架，提供了统一的抽象层。

```python
# LangChain 的核心价值: 统一接口 + 丰富组件
"""
优点:
✅ 统一的 LLM 接口 (支持 Claude, GPT, Llama...)
✅ 丰富的工具集 (搜索、计算器、数据库...)
✅ 对话记忆组件 (ConversationBufferMemory, VectorStoreMemory)
✅ 预建的 Agent 类型

缺点:
❌ 抽象层太厚，调试困难
❌ 版本迭代快，API 不稳定
❌ 简单任务过度工程
"""
```

### 示例

```python
from langchain_anthropic import ChatAnthropic
from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain.tools import tool
from langchain_core.prompts import ChatPromptTemplate

# 1. 定义工具
@tool
def get_weather(city: str) -> str:
    """获取指定城市的天气"""
    weather_db = {"北京": "晴天 25°C", "上海": "多云 28°C"}
    return weather_db.get(city, "未知")

@tool
def calculator(expression: str) -> str:
    """执行数学计算"""
    return str(eval(expression))

# 2. 创建 LLM
llm = ChatAnthropic(model="claude-sonnet-4-6", temperature=0)

# 3. 创建 Prompt
prompt = ChatPromptTemplate.from_messages([
    ("system", "你是有用的助手。可以使用工具获取信息。"),
    ("human", "{input}"),
    ("placeholder", "{agent_scratchpad}"),  # Agent 内部使用
])

# 4. 创建 Agent
agent = create_tool_calling_agent(llm, [get_weather, calculator], prompt)
agent_executor = AgentExecutor(agent=agent, tools=[get_weather, calculator])

# 5. 运行
result = agent_executor.invoke({"input": "北京天气如何？25+37等于多少？"})
print(result["output"])
```

## 6.4 LangGraph

### 定位

LangGraph 是 LangChain 生态中用于构建**有状态、多步骤 Agent** 的框架。它把 Agent 建模为状态图。

```
LangChain vs LangGraph:

LangChain:  线性的 Chain (A → B → C)
LangGraph:  有向图 Graph (A → B → C, B → D, C → D, ...)
             支持循环、条件分支、并行
```

### 核心概念

```python
"""
LangGraph 核心概念:

State (状态):     Agent 的完整状态（消息历史 + 自定义数据）
Node (节点):      处理函数，接收状态，返回新状态
Edge (边):        连接节点的路径
Conditional Edge: 根据状态决定走哪条边
Graph (图):       节点 + 边的集合
"""

from typing import TypedDict, Annotated
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_core.messages import HumanMessage, AIMessage

# 1. 定义状态
class AgentState(TypedDict):
    messages: Annotated[list, add_messages]  # 消息列表（自动追加）
    next: str                                 # 下一步
    final_output: str                         # 最终输出

# 2. 定义节点函数
def chatbot(state: AgentState) -> AgentState:
    """LLM 处理节点"""
    response = llm.invoke(state["messages"])
    return {"messages": [response]}

def tool_executor(state: AgentState) -> AgentState:
    """工具执行节点"""
    last_message = state["messages"][-1]
    # 执行工具...
    result = execute_tools(last_message.tool_calls)
    return {"messages": [result]}

# 3. 定义路由函数
def should_continue(state: AgentState) -> str:
    """决定下一步"""
    last_message = state["messages"][-1]
    if hasattr(last_message, "tool_calls") and last_message.tool_calls:
        return "tools"
    return "end"

# 4. 构建图
graph = StateGraph(AgentState)

# 添加节点
graph.add_node("chatbot", chatbot)
graph.add_node("tools", tool_executor)

# 添加边
graph.set_entry_point("chatbot")
graph.add_conditional_edges("chatbot", should_continue, {
    "tools": "tools",
    "end": END
})
graph.add_edge("tools", "chatbot")  # 工具结果回到 chatbot

# 5. 编译并运行
app = graph.compile()
result = app.invoke({"messages": [HumanMessage(content="北京天气？")]})
```

### 适用场景

```
✅ LangGraph 擅长:
  - 复杂多步骤 Agent（审批流程、数据分析）
  - 需要循环和条件分支的场景
  - 多 Agent 协作（把每个 Agent 作为一个节点）

❌ LangGraph 不适合:
  - 简单的单轮问答
  - 纯线性处理
  - 学习阶段（概念多，上手较陡）
```

## 6.5 CrewAI — 多 Agent 框架

```python
"""
CrewAI 定位: 让多个 Agent 像团队一样协作
核心理念: Role-playing — 每个 Agent 有明确的角色、目标和背景故事
"""

from crewai import Agent, Task, Crew, Process

# 定义 Agent
researcher = Agent(
    role="市场研究员",
    goal="收集并分析最新市场数据",
    backstory="你是一个经验丰富的市场分析师，擅长数据挖掘和趋势预测",
    llm=llm,
    tools=[search_tool, data_analysis_tool]
)

writer = Agent(
    role="报告撰写人",
    goal="将研究结果转化为清晰专业的报告",
    backstory="你是一个技术写作者，擅长用简洁的语言解释复杂概念",
    llm=llm
)

# 定义任务
research_task = Task(
    description="研究2025年AI Agent市场的发展趋势",
    agent=researcher,
    expected_output="一份详细的市场研究报告"
)

writing_task = Task(
    description="基于研究报告，撰写一篇面向技术管理者的分析文章",
    agent=writer,
    expected_output="一篇1000字的分析文章"
)

# 组建团队
crew = Crew(
    agents=[researcher, writer],
    tasks=[research_task, writing_task],
    process=Process.sequential  # 顺序执行（也可以 hierarchical）
)

# 执行
result = crew.kickoff()
```

## 6.6 框架选择决策树

```
开始 →

是刚接触 Agent 开发？
├── 是 → 用原生 SDK (Anthropic/OpenAI)
│        搞清楚底层原理后再用框架
│
已经理解了原理？
├── 是 → 
│   ├── 单 Agent + 简单工具 → LangChain AgentExecutor
│   ├── 复杂状态机 Agent   → LangGraph
│   ├── 多 Agent 角色扮演   → CrewAI
│   └── 需要写代码的         → 原生 SDK + 自己封装
│
需要低代码/可视化？
└── Dify / Coze / FastGPT
```

## 6.7 框架关键对比表

```
┌──────────┬──────────┬──────────┬──────────┬──────────────┐
│   维度    │ LangChain│ LangGraph│  CrewAI  │  原生 SDK     │
├──────────┼──────────┼──────────┼──────────┼──────────────┤
│ 学习曲线  │ 中等      │ 较陡      │ 平缓      │ 平缓          │
│ 灵活性    │ 中        │ 高        │ 中        │ 最高          │
│ 抽象程度  │ 高(过度)  │ 适中      │ 高(精简)  │ 无            │
│ Agent支持 │ 基础      │ 完整      │ 多Agent   │ 自己实现      │
│ 工具生态  │ 最丰富    │ 继承LC    │ 中等      │ 自己构建      │
│ 调试难度  │ 难        │ 中等      │ 容易      │ 容易          │
│ 生产就绪  │ 中等      │ 高        │ 中等      │ 高            │
│ 推荐用户  │ 快速验证  │ 复杂项目  │ 多Agent   │ 深入掌握      │
└──────────┴──────────┴──────────┴──────────┴──────────────┘
```

## 6.8 我的推荐

作为一名 Java 全栈工程师，我建议你按这个顺序接触：

```
1. 先用原生 SDK (Anthropic Claude) 手写一个 Agent 循环
   → 完全理解底层机制（1-2天）

2. 再用 LangGraph 复刻同样的功能
   → 感受框架带来的便利和约束（1天）

3. 对比两版代码，形成自己的判断
   → "什么时候该用框架，什么时候不该用"

4. 如果有多 Agent 需求，试试 CrewAI
   → 角色扮演模式在业务中很实用
```

## 6.9 总结

```
关键认知:

1. 框架是工具，不是目的
   理解原理 > 熟练使用框架

2. 原生 SDK 永远不过时
   无论框架怎么变，底层都是 LLM API 调用

3. LangChain 适合快速验证，LangGraph 适合复杂项目
   两者互补，可以混用

4. 不要陷入"框架选择困难"
   用你最熟悉的工具先跑起来，再优化
```

---

**下一篇**：[07-多 Agent 协作系统](./07-multi-agent-systems.md)
