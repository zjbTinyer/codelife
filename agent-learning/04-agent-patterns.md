# 04 — Agent 设计模式

## 4.1 核心设计模式总览

```
┌─────────────────────────────────────────────────────────┐
│                  Agent 设计模式                          │
├───────────────┬──────────────┬──────────────────────────┤
│    ReAct       │ Plan-Execute │    Reflection           │
│  (边想边做)     │ (先规划后执行) │    (自我反思)             │
├───────────────┼──────────────┼──────────────────────────┤
│ Multi-Agent   │  Router      │    Orchestrator          │
│ (多智能体)     │ (路由分发)    │    (编排调度)             │
└───────────────┴──────────────┴──────────────────────────┘
```

### 选择指南

| 场景 | 推荐模式 | 理由 |
|------|---------|------|
| 简单查询 + 单工具 | ReAct | 最轻量 |
| 复杂多步任务 | Plan-Execute | 先规划减少偏差 |
| 需要高质量输出 | Reflection | 自我纠错 |
| 任务类型多样 | Router | 专业分工 |
| 多角色协作 | Multi-Agent | 各司其职 |

## 4.2 ReAct 模式（Reasoning + Acting）

ReAct 是最基础、最常用的 Agent 模式。LLM 交替进行推理（Thought）和行动（Action），直到任务完成。

### 执行流程

```
用户: "北京明天天气如何？适合户外运动吗？"

Step 1 — Thought: 我需要查明天的天气
         Action: get_weather(city="北京", date="tomorrow")
         Observation: {"weather": "晴转多云", "temp": "15-22°C", "wind": "3级"}

Step 2 — Thought: 晴转多云，温度适宜，风力不大，适合户外
         Action: 无需更多工具 → 直接回复用户
         Final: "北京明天晴转多云，15-22°C，风力3级，非常适合户外运动！"
```

### 完整实现

```python
import anthropic
import json
from typing import Any

class ReActAgent:
    """ReAct 模式 Agent 实现"""

    def __init__(self, system_prompt: str, tools: dict, max_steps: int = 10):
        self.client = anthropic.Anthropic()
        self.system_prompt = system_prompt
        self.tools = tools
        self.max_steps = max_steps
        self.tool_schemas = [t["schema"] for t in tools.values()]

    def run(self, user_input: str) -> str:
        messages = [{"role": "user", "content": user_input}]

        for step in range(self.max_steps):
            # 1. 调用 LLM（带推理提示）
            response = self.client.messages.create(
                model="claude-sonnet-4-6",
                max_tokens=1024,
                system=self._build_system_prompt(),
                tools=self.tool_schemas,
                messages=messages
            )

            # 2. 解析响应
            text, tool_calls = self._parse_response(response)

            # 3. 如果没有工具调用 → 任务完成
            if not tool_calls:
                return text

            # 4. 将助手响应加入历史
            messages.append({"role": "assistant", "content": response.content})

            # 5. 执行工具
            tool_results = []
            for tc in tool_calls:
                result = self._execute_tool(tc.name, tc.input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tc.id,
                    "content": json.dumps(result, ensure_ascii=False)
                })

            # 6. 将工具结果加入历史
            messages.append({"role": "user", "content": tool_results})

        return "无法在限定步骤内完成任务。"

    def _build_system_prompt(self) -> str:
        """构建 ReAct 风格的 System Prompt"""
        return f"""{self.system_prompt}

## 工作方式（ReAct 模式）
对于每个用户请求，请按以下步骤处理：

1. **Think**: 分析当前状况，决定需要什么信息
2. **Act**: 调用合适的工具获取信息
3. **Observe**: 观察工具返回的结果
4. **Repeat**: 如果信息不足，回到步骤1
5. **Answer**: 信息充足时，直接回答用户

## 规则
- 每次优先使用工具获取实时、准确的信息
- 如果工具调用失败，尝试其他方式获取信息
- 不确定时，可以向用户确认而不是猜测"""

    def _parse_response(self, response) -> tuple[str, list]:
        text_parts = []
        tool_calls = []
        for block in response.content:
            if block.type == "text":
                text_parts.append(block.text)
            elif block.type == "tool_use":
                tool_calls.append(block)
        return "".join(text_parts), tool_calls

    def _execute_tool(self, name: str, params: dict) -> Any:
        tool = self.tools.get(name)
        if not tool:
            return {"error": f"未知工具: {name}"}
        try:
            return tool["handler"](**params)
        except Exception as e:
            return {"error": str(e)}
```

## 4.3 Plan-Execute 模式（先规划后执行）

ReAct 的问题是"走一步看一步"，容易在复杂任务中迷失。Plan-Execute 先制定完整计划，再逐步执行。

### 对比

```
ReAct (边想边做):
  想→做→看→想→做→看→...        (易发散)

Plan-Execute (先规划后执行):
  想(全局)→写计划→做1→做2→做3→检查 (更聚焦)
```

### 实现

```python
class PlanExecuteAgent:
    """Plan-Execute 模式 Agent"""

    def run(self, user_input: str) -> str:
        # ===== 阶段1: 制定计划 =====
        plan = self._create_plan(user_input)
        print(f"[Plan] {plan}")

        # ===== 阶段2: 逐步执行 =====
        results = []
        for i, step in enumerate(plan["steps"]):
            print(f"[Execute {i+1}/{len(plan['steps'])}] {step}")

            step_result = self._execute_step(step)

            # ===== 阶段3: 检查是否需要调整计划 =====
            if step_result.get("need_replan"):
                print("[Replan] 需要调整计划...")
                new_steps = self._replan(plan, results, step_result)
                plan["steps"][i+1:] = new_steps

            results.append(step_result)

        # ===== 阶段4: 生成最终报告 =====
        return self._summarize(user_input, plan, results)

    def _create_plan(self, user_input: str) -> dict:
        """让 LLM 制定执行计划"""
        response = self.client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            system="""你是一个任务规划器。将用户请求分解为执行步骤。

返回 JSON 格式:
{
  "goal": "任务目标（一句话）",
  "steps": [
    {
      "id": 1,
      "action": "具体动作描述",
      "tool": "需要的工具名或 null",
      "expected_output": "预期产出"
    }
  ],
  "success_criteria": "完成标准"
}""",
            messages=[{"role": "user", "content": f"制定计划：{user_input}"}]
        )
        return json.loads(self._extract_json(response))

    def _execute_step(self, step: dict) -> dict:
        """执行单个步骤（可以调用工具）"""
        # 在这个子循环中可以使用 ReAct 模式
        return self.react_agent.run(step["action"])

    def _replan(self, plan: dict, completed: list, issue: dict) -> list:
        """根据执行结果调整剩余计划"""
        response = self.client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=512,
            system="""根据已完成的步骤和遇到的问题，调整剩余计划，返回新的步骤列表。""",
            messages=[{"role": "user", "content": json.dumps({
                "plan": plan,
                "completed": completed,
                "issue": issue
            })}]
        )
        return json.loads(self._extract_json(response))
```

### 适用场景

```
✅ Plan-Execute 擅长:
  - 多步骤复杂任务（"部署一个新微服务"）
  - 需要全局视角的任务（"审查整个项目的安全问题"）
  - 步骤之间有依赖关系（"设计数据库 → 建表 → 写代码 → 测试"）

✅ ReAct 擅长:
  - 信息不确定的任务（"帮我找一下XX公司的联系方式"）
  - 交互式任务（"帮我填这个表单"）
  - 简单任务（"查一下天气"）
```

## 4.4 Reflection 模式（自我反思）

让 Agent 反思自己的输出质量，发现问题后自动修正。

```python
class ReflectionAgent:
    """带自我反思的 Agent"""

    ACTOR_SYSTEM = """你是执行者。根据任务要求生成内容。"""

    REFLECTOR_SYSTEM = """你是评审者。检查以下内容是否存在问题：
1. 事实错误：数据、日期、数字是否准确
2. 逻辑错误：推理是否有漏洞
3. 完整性问题：是否遗漏了关键信息
4. 表述问题：表达是否清晰、准确

如果发现问题，明确指出并要求修正。
如果内容无问题，回复 "APPROVED"。"""

    def run_with_reflection(self, task: str, max_reflections: int = 3) -> str:
        """生成 → 反思 → 修正 → 循环"""

        # 1. 初始生成
        content = self._actor(task)
        print(f"[Initial] {content[:100]}...")

        for i in range(max_reflections):
            # 2. 反思
            feedback = self._reflector(content)
            print(f"[Reflection {i+1}] {feedback[:100]}...")

            # 3. 如果通过，结束
            if "APPROVED" in feedback.upper():
                print("[Reflection] ✅ 已通过")
                return content

            # 4. 根据反馈修正
            content = self._actor(
                f"{task}\n\n[上次内容的反馈]\n{feedback}\n\n请根据反馈修正内容。"
            )
            print(f"[Revised {i+1}] {content[:100]}...")

        return content

    def _actor(self, prompt: str) -> str:
        response = self.client.messages.create(
            model="claude-sonnet-4-6",
            system=self.ACTOR_SYSTEM,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=1024,
        )
        return response.content[0].text

    def _reflector(self, content: str) -> str:
        response = self.client.messages.create(
            model="claude-sonnet-4-6",
            system=self.REFLECTOR_SYSTEM,
            messages=[{"role": "user", "content": f"请评审以下内容:\n\n{content}"}],
            max_tokens=512,
        )
        return response.content[0].text
```

## 4.5 Router 模式（路由分发）

根据用户意图，将请求路由到不同的"专家"处理。

```python
class RouterAgent:
    """路由 Agent — 根据意图分发任务"""

    def __init__(self):
        # 注册子处理器
        self.handlers = {
            "order": OrderHandler(),
            "refund": RefundHandler(),
            "product": ProductHandler(),
            "complaint": ComplaintHandler(),
        }

    def run(self, user_input: str) -> str:
        # 1. 识别意图
        intent = self._classify_intent(user_input)
        print(f"[Router] 意图: {intent['category']}, 置信度: {intent['confidence']}")

        # 2. 低置信度 → 通用回复或询问
        if intent["confidence"] < 0.7:
            return self._ask_clarification(intent)

        # 3. 路由到对应的 Handler
        handler = self.handlers.get(intent["category"])
        if handler:
            return handler.handle(user_input, intent)
        else:
            return self._fallback(user_input)

    def _classify_intent(self, text: str) -> dict:
        """用 LLM 分类意图"""
        response = self.client.messages.create(
            model="claude-haiku-4-5",  # 简单分类用快模型
            max_tokens=128,
            system="""分析用户意图，返回JSON:
{
  "category": "order|refund|product|complaint|other",
  "confidence": 0.0-1.0,
  "keywords": ["提取的关键词"],
  "clarify_question": "如果不确定意图，追问什么问题"
}""",
            messages=[{"role": "user", "content": text}]
        )
        return json.loads(response.content[0].text)
```

## 4.6 模式组合：生产级 Agent 架构

实际项目中，往往是多种模式的组合：

```python
class ProductionAgent:
    """
    生产级 Agent 架构 — 组合多种模式

    意图路由(Router) → 计划生成(Plan) → ReAct执行 → 反思修正(Reflection) → 输出
    """

    def run(self, user_input: str) -> str:
        # 第一阶段: 路由
        intent = self.router.classify(user_input)

        # 第二阶段: 规划
        plan = self.planner.create_plan(user_input, intent)

        # 第三阶段: 执行（ReAct + 工具调用）
        results = []
        for step in plan["steps"]:
            result = self.react_agent.execute(step)
            results.append(result)

        # 第四阶段: 反思
        final = self.reflector.review_and_refine(
            task=user_input,
            plan=plan,
            results=results
        )

        return final
```

## 4.7 总结

```
模式选择决策树:

任务复杂度?
├── 简单（1-2步） → ReAct
│
├── 中等（3-5步，有依赖） → Plan-Execute
│   └── 需要高质量? → + Reflection
│
├── 多种类型任务 → Router + ReAct
│
└── 多角色/多领域 → Multi-Agent（见第7章）

黄金法则:
  先用最简单的模式，不够用了再加复杂度。
  不要在"查天气"这种任务上搭一个 Multi-Agent 系统。
```

---

**下一篇**：[05-记忆与状态管理](./05-memory-and-state.md)
