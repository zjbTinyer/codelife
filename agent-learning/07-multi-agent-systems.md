# 07 — 多 Agent 协作系统

## 7.1 为什么需要多 Agent？

单个 Agent 面临"全能悖论"：越想让一个 Agent 处理所有事情，它的表现就越差。

```
单 Agent 的问题:
┌─────────────────────────────────────┐
│          超级 Agent                  │
│  能做客服 + 能写代码 + 能分析数据     │
│  System Prompt: 5000 字（太长）       │
│  工具: 50 个（选择困难）              │
│  结果: 经常选错工具，输出质量下降      │
└─────────────────────────────────────┘

多 Agent 的优势:
┌─────────┐ ┌─────────┐ ┌─────────────┐
│ 客服Agent│ │ 技术Agent│ │ 数据分析Agent│
│ 10个工具 │ │ 15个工具 │ │ 12个工具    │
│ Prompt短 │ │ Prompt短 │ │ Prompt短    │
└─────────┘ └─────────┘ └─────────────┘
      ↕           ↕             ↕
┌─────────────────────────────────────┐
│          调度 Agent (Orchestrator)    │
│  根据用户意图，分发给最合适的 Agent   │
└─────────────────────────────────────┘
```

**类比**：就像你不会让一个 Java 后端去写 iOS 应用，每个 Agent 应该有自己的"专业领域"。

## 7.2 三种协作模式

### 模式1: 顺序接力（Sequential）

```
Input → Agent A → 输出A → Agent B → 输出B → Agent C → Final

适合: 流水线式任务
示例: 需求分析 → 方案设计 → 代码实现 → 代码审查
```

### 模式2: 层级调度（Hierarchical）

```
          ┌──────────────┐
          │  Manager Agent │ ← 分配任务、合并结果
          └──┬───┬───┬───┘
             │   │   │
      ┌──────┘   │   └──────┐
      ↓          ↓          ↓
   Agent A    Agent B    Agent C

适合: 复杂任务分解
示例: 项目经理把"建一个网站"拆解为前端、后端、设计任务
```

### 模式3: 辩论协作（Debate / Peer-to-Peer）

```
   Agent A ←→ Agent B ←→ Agent C
      ↕         ↕         ↕
      共享上下文 + 互相评价

适合: 需要高质量输出的场景
示例: 3个Agent分别评审代码，讨论后给出最终意见
```

## 7.3 顺序接力实现

```python
"""
顺序接力 — 最常见的多 Agent 模式
"""
class SequentialMultiAgent:
    """顺序执行多个 Agent"""

    def __init__(self):
        self.agents = {
            "planner": self._create_planner(),
            "executor": self._create_executor(),
            "reviewer": self._create_reviewer(),
        }

    def run(self, task: str) -> str:
        # Step 1: 规划
        plan = self.agents["planner"].run(task)
        print(f"[Planner] {plan[:200]}...")

        # Step 2: 执行
        result = self.agents["executor"].run(
            f"任务: {task}\n计划: {plan}"
        )
        print(f"[Executor] {result[:200]}...")

        # Step 3: 审查
        final = self.agents["reviewer"].run(
            f"任务: {task}\n计划: {plan}\n执行结果: {result}"
        )
        print(f"[Reviewer] {final[:200]}...")

        return final

    def _create_planner(self):
        return ReActAgent(
            system="""你是任务规划专家。
将用户需求分解为可执行的步骤，输出JSON格式:
{
  "steps": [{"id": 1, "action": "..."}, ...],
  "notes": "注意事项"
}""",
            tools={"query_knowledge_base": kb_tool}
        )

    def _create_executor(self):
        return ReActAgent(
            system="你是任务执行专家。严格按照计划执行每个步骤。",
            tools={"write_code": code_tool, "run_test": test_tool}
        )

    def _create_reviewer(self):
        return ReActAgent(
            system="你是代码审查专家。检查执行结果是否符合需求和计划。",
            tools={"check_quality": quality_tool}
        )
```

## 7.4 层级调度实现

```python
"""
层级调度 — Manager Agent 分配任务给 Worker Agent
"""
import asyncio

class ManagerWorkerSystem:
    """Manager-Worker 多 Agent 系统"""

    def __init__(self):
        self.manager = self._create_manager()
        self.workers = {
            "frontend": self._create_worker("frontend"),
            "backend": self._create_worker("backend"),
            "data": self._create_worker("data"),
        }
        self.worker_capabilities = {
            "frontend": "React/Vue, CSS, 前端性能优化",
            "backend": "Java/Spring, Python/FastAPI, 数据库设计",
            "data": "SQL查询, 数据分析, 报表生成",
        }

    def run(self, task: str) -> str:
        # 1. Manager 分析任务并分配
        assignments = self.manager.assign(task, self.worker_capabilities)

        # 2. 并行执行（独立的子任务）
        results = {}
        for worker_name, subtask in assignments.items():
            if worker_name in self.workers:
                results[worker_name] = self.workers[worker_name].run(subtask)
                print(f"[{worker_name}] 完成子任务")

        # 3. Manager 合并结果
        final = self.manager.synthesize(task, results)
        return final

    def _create_manager(self):
        return Agent(
            system="""你是项目经理。负责：
1. 分析用户需求，拆解为子任务
2. 根据各 Worker 的能力分配任务
3. 合并各 Worker 的结果，生成最终答案

返回 JSON:
{
  "assignments": {
    "frontend": "前端子任务描述",
    "backend": "后端子任务描述"
  }
}""",
            tools={}
        )

    def _create_worker(self, role: str):
        return Agent(
            system=f"你是 {role} 专家。完成 Manager 分配的子任务并返回结果。",
            tools=ROLE_TOOLS[role]
        )
```

## 7.5 辩论协作实现

```python
"""
辩论模式 — 多个 Agent 独立评审，讨论后达成共识
"""
class DebateSystem:
    """多 Agent 辩论系统"""

    def __init__(self, num_agents: int = 3):
        self.agents = [
            Agent(
                system=f"""你是评审员 #{i+1}。
你的专长角度是: {angles[i]}
评审时从你的角度出发，提出问题和建议。
当你认为内容已经足够好时，回复 "APPROVED"。 """,
                tools={"fact_check": fact_check_tool}
            )
            for i in range(num_agents)
        ]
        self.num_agents = num_agents

    def run(self, task: str, max_rounds: int = 3) -> str:
        # 1. 初始生成
        content = self._generate_initial(task)

        # 2. 辩论循环
        for round_num in range(max_rounds):
            print(f"\n=== 第 {round_num+1} 轮辩论 ===")

            # 2a. 所有 Agent 独立评审
            critiques = []
            for i, agent in enumerate(self.agents):
                critique = agent.run(
                    f"""请评审以下内容，从你的专业角度提出改进意见。

[原始任务]
{task}

[当前内容]
{content}

如果内容已经足够好，回复 "APPROVED"。
如果需要修改，给出具体的修改建议。"""
                )
                critiques.append(critique)
                print(f"  Agent {i+1}: {critique[:100]}...")

            # 2b. 统计通过情况
            approvals = sum(1 for c in critiques if "APPROVED" in c.upper())
            print(f"  {approvals}/{self.num_agents} 通过")

            # 2c. 如果多数通过，结束
            if approvals >= self.num_agents * 2 / 3:  # 2/3 多数
                print("  ✅ 达成共识")
                return content

            # 2d. 汇总批评意见，修正内容
            all_critiques = "\n---\n".join(critiques)
            content = self._revise(content, all_critiques)

        return content

    def _generate_initial(self, task: str) -> str:
        response = llm.create(
            system="你是内容生成专家。根据任务要求生成高质量内容。",
            messages=[{"role": "user", "content": task}],
            max_tokens=2048
        )
        return response.content[0].text

    def _revise(self, content: str, critiques: str) -> str:
        response = llm.create(
            system="根据评审意见修改内容。逐一回应每条意见。",
            messages=[{"role": "user", "content": f"""原内容:
{content}

评审意见:
{critiques}

请根据评审意见输出修改后的完整内容。"""}],
            max_tokens=2048
        )
        return response.content[0].text
```

## 7.6 Agent 间通信

多 Agent 系统中，Agent 之间的通信是核心问题。

### 方式1: 共享上下文

```python
class SharedContext:
    """所有 Agent 共享的消息总线"""

    def __init__(self):
        self.messages = []  # 所有 Agent 都能读写
        self.shared_data = {}  # 共享数据（类似 Redis）

    def post_message(self, sender: str, content: str):
        self.messages.append({
            "sender": sender,
            "content": content,
            "timestamp": time.time()
        })

    def get_context_for(self, agent_name: str) -> str:
        """为特定 Agent 构建上下文"""
        # 过滤: Agent 不需要看到所有消息
        relevant = [m for m in self.messages
                    if m["sender"] != agent_name]  # 至少过滤掉自己的
        return "\n".join(f"[{m['sender']}]: {m['content']}" for m in relevant)

    def set_shared(self, key: str, value: any):
        self.shared_data[key] = value

    def get_shared(self, key: str):
        return self.shared_data.get(key)
```

### 方式2: 显式消息传递

```python
class MessagePassing:
    """Agent 间直接消息传递"""

    def __init__(self):
        self.agents = {}

    def register(self, name: str, agent):
        self.agents[name] = agent

    def send(self, from_agent: str, to_agent: str,
             message: str, reply_expected: bool = True) -> str:
        """发送消息给指定 Agent"""
        target = self.agents.get(to_agent)
        if not target:
            return f"Error: Agent '{to_agent}' not found"

        enriched = f"[来自 {from_agent} 的消息]\n{message}"

        if reply_expected:
            return target.run(enriched)
        else:
            target.ingest(enriched)  # 异步接收
            return "Message delivered"
```

## 7.7 多 Agent 系统设计原则

```
1. 【单一职责】
   每个 Agent 只做一件事，做好一件事
   ❌ "通用助手" Agent
   ✅ "订单查询" Agent, "退款处理" Agent, "投诉升级" Agent

2. 【明确接口】
   Agent 之间的输入输出要结构化
   ❌ 自然语言传递所有信息
   ✅ {"order_id": "ORD-123", "status": "pending", "amount": 299.00}

3. 【松耦合】
   一个 Agent 挂了不应该让整个系统崩溃
   ❌ Agent A 直接调用 Agent B 的方法
   ✅ 通过消息总线通信，有超时和降级

4. 【可观测】
   每个 Agent 的决策和行动都要记录
   ❌ Agent 内部黑盒处理
   ✅ 每一步都打日志，方便排查

5. 【渐进式引入】
   不要一口吃成胖子，先从 2 个 Agent 开始
   ❌ 第一版就设计 10 个 Agent
   ✅ 先用 1 个 Agent 跑通，需要时再拆分
```

## 7.8 完整的客服多 Agent 系统示例

```python
"""
电商客服多 Agent 系统
"""
class CustomerServiceSystem:
    """完整的多 Agent 客服系统"""

    def __init__(self):
        # 路由 Agent
        self.router = Agent(
            system="分析用户意图，路由到合适的处理 Agent。",
            tools={}
        )

        # 专业 Agent
        self.order_agent = Agent(
            system="订单查询专家。处理订单查询、物流跟踪。",
            tools={"query_order": order_tool, "track_logistics": logistics_tool}
        )

        self.refund_agent = Agent(
            system="退款处理专家。检查退款条件、创建退款单。",
            tools={"check_refund": check_refund_tool, "create_refund": create_refund_tool}
        )

        self.product_agent = Agent(
            system="商品咨询专家。回答商品参数、库存、价格问题。",
            tools={"search_product": search_tool, "check_inventory": inventory_tool}
        )

        # 兜底
        self.human_escalation = Agent(
            system="升级到人工客服。当自动服务无法处理时使用。",
            tools={"create_ticket": ticket_tool}
        )

        self.specialists = {
            "order": self.order_agent,
            "refund": self.refund_agent,
            "product": self.product_agent,
        }

    def handle_message(self, user_id: str, message: str) -> str:
        # 1. 加载用户上下文（记忆）
        context = memory_system.build_context(user_id)

        # 2. 路由
        route_result = self.router.run(
            f"用户消息: {message}\n用户信息: {context}"
        )
        category = route_result["category"]
        confidence = route_result["confidence"]

        # 3. 低置信度 → 让用户确认
        if confidence < 0.7:
            return f"我理解您想咨询{category}相关问题，是这样吗？"

        # 4. 分发给专家 Agent
        specialist = self.specialists.get(category)
        if not specialist:
            return self.human_escalation.run(
                f"无法路由的消息: {message}\n用户: {user_id}"
            )

        try:
            response = specialist.run(
                f"用户ID: {user_id}\n上下文: {context}\n消息: {message}"
            )
            # 保存对话
            memory_system.save_dialog(user_id, message, response)
            return response
        except Exception as e:
            # 降级: 转人工
            return self.human_escalation.run(
                f"处理失败: {str(e)}\n用户: {user_id}\n消息: {message}"
            )
```

## 7.9 总结

```
多 Agent 核心原则:

1. 拆分的理由要清晰
   - 不同专业领域 → 拆分
   - 不同工具权限 → 拆分
   - 不同质量要求 → 拆分
   - 只是为了"看起来复杂" → 别拆

2. 通信成本 > 计算成本
   每次 Agent 间通信都是延迟 + Token 成本
   能在一个 Agent 内解决的就不要多 Agent

3. 先单后多
   先把单 Agent 做到极致，再考虑拆分
   过早的多 Agent 设计 ≈ 过早的微服务拆分

4. 失败模式要设计好
   某个 Agent 挂了怎么办？
   所有 Agent 意见不一致怎么办？
   无限循环怎么办？
```

---

**下一篇**：[08-评估与测试](./08-evaluation-and-testing.md)
