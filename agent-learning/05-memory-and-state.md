# 05 — 记忆与状态管理

## 5.1 为什么 Agent 需要记忆？

LLM 每次 API 调用都是**无状态**的。如果不传对话历史，它不知道上一轮说过什么。

```
无记忆的 Agent:
  用户: "我叫张三"
  Agent: "你好张三！"
  用户: "我刚才说我叫什么？"     ← 不传历史的话，模型不知道
  Agent: "你没有告诉过我。"      ← "失忆"了

有记忆的 Agent:
  用户: "我叫张三"
  Agent: "你好张三！我已经记住了。"
  用户: "我刚才说我叫什么？"
  Agent: "你刚才说你叫张三。"    ← 从对话历史/记忆中检索到的
```

## 5.2 记忆的四个层次

```
┌────────────────────────────────────────────────────────┐
│  层次1: 对话上下文 (Working Memory) — 当前会话的消息  │
│  ├─ 容量: ~200K tokens (约10万汉字)                   │
│  ├─ 生命周期: 单次会话                                │
│  └─ 类比: 计算机 RAM                                  │
├────────────────────────────────────────────────────────┤
│  层次2: 短期记忆 (Short-term) — 跨会话但临时的信息    │
│  ├─ 容量: MB级                                        │
│  ├─ 生命周期: 几分钟到几天                            │
│  └─ 技术: Redis/Session/文件                          │
├────────────────────────────────────────────────────────┤
│  层次3: 长期记忆 (Long-term) — 持久化的知识和经验     │
│  ├─ 容量: GB级                                        │
│  ├─ 生命周期: 永久                                    │
│  └─ 技术: 向量数据库 (Milvus/Chroma/Pinecone)         │
├────────────────────────────────────────────────────────┤
│  层次4: 工作记忆 (Scratchpad) — 任务执行中的中间状态  │
│  ├─ 容量: KB级                                        │
│  ├─ 生命周期: 单次任务                                │
│  └─ 类比: 草稿纸 / 便签                               │
└────────────────────────────────────────────────────────┘
```

## 5.3 对话上下文管理

### 5.3.1 基础：完整保留

```python
class SimpleMemory:
    """最简单的记忆：保留所有对话"""

    def __init__(self, system_prompt: str):
        self.system = system_prompt
        self.messages = []  # 对话历史

    def add_user_message(self, content: str):
        self.messages.append({"role": "user", "content": content})

    def add_assistant_message(self, content):
        self.messages.append({"role": "assistant", "content": content})

    def get_context(self) -> list:
        """获取完整上下文给 LLM"""
        return self.messages

# 问题：对话长了之后会爆 token 上限
```

### 5.3.2 进阶：滑动窗口

```python
class SlidingWindowMemory:
    """滑动窗口记忆：只保留最近 N 轮对话"""

    def __init__(self, max_turns: int = 10):
        self.max_turns = max_turns
        self.messages = []

    def add_user_message(self, content: str):
        self.messages.append({"role": "user", "content": content})
        self._trim()

    def add_assistant_message(self, content):
        self.messages.append({"role": "assistant", "content": content})

    def _trim(self):
        """保持消息数量在限制内，一轮 = user + assistant"""
        max_messages = self.max_turns * 2
        if len(self.messages) > max_messages:
            # 保留 system 类型的消息，裁剪最早的对话
            self.messages = self.messages[-max_messages:]


# ❌ 问题：会丢失早期的重要信息（如用户名字、偏好）
```

### 5.3.3 最佳实践：摘要 + 滑动窗口

```python
class SummaryMemory:
    """摘要记忆：自动压缩旧对话"""

    def __init__(self, max_turns: int = 10):
        self.max_turns = max_turns
        self.messages = []
        self.summary = ""  # 历史对话摘要

    def add_user_message(self, content: str):
        self.messages.append({"role": "user", "content": content})

    def add_assistant_message(self, content):
        self.messages.append({"role": "assistant", "content": content})

        # 检查是否需要压缩
        if len(self.messages) > self.max_turns * 2:
            self._compress()

    def _compress(self):
        """将最早的对话压缩成摘要"""
        # 取最早的 N 条消息
        old_messages = self.messages[:-self.max_turns * 2]
        self.messages = self.messages[-self.max_turns * 2:]

        # 生成摘要
        old_conversation = "\n".join(
            f"{m['role']}: {m['content'][:200]}" for m in old_messages
        )

        summary_response = self.llm.create(
            system="请将以下对话压缩为一段简洁的摘要，保留关键信息（人名、决定、数字）。",
            messages=[{"role": "user", "content": old_conversation}],
            max_tokens=200
        )

        # 更新摘要
        new_part = summary_response.content[0].text
        self.summary = self._merge_summaries(self.summary, new_part)

    def _merge_summaries(self, old: str, new: str) -> str:
        """合并新旧摘要，避免无限增长"""
        if not old:
            return new
        if len(old + new) < 500:
            return old + "\n" + new
        # 让 LLM 合并
        response = self.llm.create(
            system="将两段对话摘要合并为一段，保留所有关键信息。",
            messages=[{"role": "user", "content": f"摘要1:\n{old}\n\n摘要2:\n{new}"}],
            max_tokens=200
        )
        return response.content[0].text

    def get_context_for_llm(self) -> str:
        """构建给 LLM 的完整上下文"""
        context = ""
        if self.summary:
            context += f"[历史对话摘要]\n{self.summary}\n\n"
        context += "[最近对话]\n"
        context += "\n".join(
            f"{m['role']}: {m['content']}" for m in self.messages
        )
        return context
```

## 5.4 长期记忆：向量数据库 + RAG

### 5.4.1 概念

```
向量数据库 = 语义搜索引擎

传统搜索: "猫咪" 只匹配包含 "猫咪" 的文本
向量搜索: "猫咪" 能匹配到 "猫"、"小猫"、"宠物猫"、"feline" 等相关内容
```

### 5.4.2 实现

```python
"""
长期记忆系统：基于向量数据库
"""
import chromadb
from chromadb.utils import embedding_functions


class LongTermMemory:
    """长期记忆管理"""

    def __init__(self, persist_dir: str = "./agent_memory"):
        self.client = chromadb.PersistentClient(path=persist_dir)
        # 使用 OpenAI embedding（也可以用其他模型）
        self.embed_fn = embedding_functions.OpenAIEmbeddingFunction(
            api_key="...", model_name="text-embedding-3-small"
        )

        # 记忆分类：facts（事实）、preferences（偏好）、experiences（经验）
        self.collections = {
            "facts": self.client.get_or_create_collection(
                "agent_facts", embedding_function=self.embed_fn
            ),
            "preferences": self.client.get_or_create_collection(
                "agent_preferences", embedding_function=self.embed_fn
            ),
            "experiences": self.client.get_or_create_collection(
                "agent_experiences", embedding_function=self.embed_fn
            ),
        }

    def remember(self, category: str, content: str, metadata: dict = None):
        """存储一条记忆"""
        memory_id = f"mem_{hash(content)}_{int(time.time())}"
        self.collections[category].add(
            documents=[content],
            metadatas=[metadata or {}],
            ids=[memory_id]
        )
        return memory_id

    def recall(self, query: str, category: str = None, top_k: int = 3) -> list:
        """检索最相关的记忆"""
        if category:
            results = self.collections[category].query(
                query_texts=[query], n_results=top_k
            )
        else:
            # 搜索所有分类
            all_results = []
            for cat, col in self.collections.items():
                r = col.query(query_texts=[query], n_results=top_k)
                all_results.extend(r["documents"][0])
            results = all_results[:top_k]

        return results if isinstance(results, list) else results.get("documents", [[]])[0]

    def forget(self, memory_id: str, category: str):
        """删除一条记忆"""
        self.collections[category].delete(ids=[memory_id])


# ===== 使用示例 =====

memory = LongTermMemory()

# 记住用户信息
memory.remember("facts", "用户张三的会员等级是VIP3，手机号138****5678")
memory.remember("preferences", "张三偏好简洁的回复风格，不喜欢啰嗦")
memory.remember("experiences", "张三上次投诉了物流慢的问题，已补偿优惠券")

# 后续对话中检索
user_query = "帮我查一下我的订单"
relevant = memory.recall("张三 会员 偏好", top_k=3)

# 将检索到的记忆注入 System Prompt
augmented_prompt = f"""你是客服Agent。
## 用户历史信息:
{chr(10).join(f"- {m}" for m in relevant)}

## 当前对话:
{user_query}"""
```

## 5.5 工作记忆（Scratchpad）

Agent 在执行复杂任务时，需要"草稿纸"来记录中间结果。

```python
class ScratchpadMemory:
    """任务级别的临时工作区"""

    def __init__(self):
        self.data = {}  # key-value 存储

    def set(self, key: str, value: any):
        """记录中间结果"""
        self.data[key] = value

    def get(self, key: str, default=None):
        """获取之前的结果"""
        return self.data.get(key, default)

    def get_all(self) -> str:
        """获取所有记录（用于注入到 prompt）"""
        if not self.data:
            return "（暂无记录）"
        return "\n".join(f"- {k}: {str(v)[:200]}" for k, v in self.data.items())


# ===== 在 Agent 中使用 =====

class AgentWithScratchpad:
    def __init__(self):
        self.scratchpad = ScratchpadMemory()

    def run_step(self, step: str) -> dict:
        # 将草稿纸内容注入 prompt
        enriched_prompt = f"""当前任务: {step}
已记录的信息:
{self.scratchpad.get_all()}
"""
        result = self.llm.call(enriched_prompt)

        # 自动记录重要信息
        if result.get("customer_id"):
            self.scratchpad.set("customer_id", result["customer_id"])
        if result.get("order_total"):
            self.scratchpad.set("order_total", result["order_total"])

        return result
```

## 5.6 记忆管理策略对比

```
┌────────────────┬──────────┬──────────┬─────────────┐
│      策略       │  成本    │  准确性   │   适用场景   │
├────────────────┼──────────┼──────────┼─────────────┤
│ 完整保留        │ Token高  │  100%    │ 短对话      │
│ 滑动窗口        │ 中等     │  近期100%│ 中等会话    │
│ 摘要+窗口       │ 中等     │  高      │ 长对话      │
│ 向量检索(RAG)   │ 低       │  中      │ 海量知识    │
│ 混合(摘要+RAG)  │ 中等     │  最高    │ 生产环境    │
└────────────────┴──────────┴──────────┴─────────────┘
```

## 5.7 生产级记忆架构

```python
class ProductionMemory:
    """
    生产级记忆系统 = 对话上下文 + 摘要记忆 + 向量检索
    """

    def __init__(self, user_id: str):
        self.user_id = user_id
        self.window = SlidingWindowMemory(max_turns=10)
        self.long_term = LongTermMemory()
        self.scratchpad = ScratchpadMemory()

    def build_context(self, user_input: str) -> dict:
        """构建完整的 LLM 调用上下文"""

        # 1. 从长期记忆检索
        memories = self.long_term.recall(user_input, top_k=5)
        memory_text = "\n".join(f"- {m}" for m in memories)

        # 2. 获取当前对话
        recent = self.window.get_context_for_llm()

        # 3. 获取工作记忆
        working = self.scratchpad.get_all()

        return {
            "system": f"""## 用户历史
{memory_text}

## 当前任务进度
{working}

## 规则
- 基于以上信息回答用户问题
- 如果获取到新的用户信息，记录到长期记忆""",
            "messages": recent,
        }

    def after_response(self, user_input: str, response: str):
        """回调：每次回复后更新记忆"""
        # 自动提取并存储重要信息
        extracted = self._extract_info(user_input, response)
        for fact in extracted:
            self.long_term.remember("facts", fact)

        # 更新对话窗口
        self.window.add_user_message(user_input)
        self.window.add_assistant_message(response)

    def _extract_info(self, input: str, response: str) -> list:
        """从对话中提取值得记住的信息"""
        # 用轻量模型提取结构化信息
        result = self.llm.create(
            model="claude-haiku-4-5",
            system="从对话中提取值得长期记住的用户信息，每行一条。如：姓名、偏好、重要事件。如果无重要信息则返回空。",
            messages=[{"role": "user", "content": f"用户: {input}\n助手: {response}"}],
            max_tokens=200
        )
        text = result.content[0].text.strip()
        return [line.strip("- ") for line in text.split("\n") if line.strip()] if text else []
```

## 5.8 记忆相关的常见陷阱

```python
# ❌ 陷阱1: 无限累积记忆
# 每次对话都往向量数据库写，从不清理
# → 检索越来越慢，噪音越来越多

# ✅ 正确: 带 TTL 的记忆
class TTLMemory(LongTermMemory):
    def remember(self, category, content, metadata=None, ttl_days=30):
        metadata = metadata or {}
        metadata["expire_at"] = (datetime.now() + timedelta(days=ttl_days)).isoformat()
        super().remember(category, content, metadata)

    def recall(self, query, category=None, top_k=3):
        results = super().recall(query, category, top_k)
        # 过滤过期记忆
        now = datetime.now()
        valid = [r for r in results
                 if r.get("metadata", {}).get("expire_at", "9999") > now.isoformat()]
        return valid[:top_k]


# ❌ 陷阱2: 记忆注入过多
# 检索了 20 条记忆全塞进 prompt → 超 token 限制
# ✅ 正确: 限制记忆注入量
MAX_MEMORY_TOKENS = 2000  # 记忆最多占用 2000 tokens

def inject_memories(memories: list, max_tokens: int = MAX_MEMORY_TOKENS) -> str:
    result = []
    token_count = 0
    for m in memories[:5]:  # 最多5条
        tokens = count_tokens(m)
        if token_count + tokens > max_tokens:
            break
        result.append(m)
        token_count += tokens
    return "\n".join(f"- {m}" for m in result)


# ❌ 陷阱3: 敏感信息未脱敏
# 把用户手机号、身份证号直接存入向量数据库
# ✅ 正确: 存储前脱敏
def sanitize_before_store(text: str) -> str:
    import re
    text = re.sub(r'\d{11}', '***PHONE***', text)       # 手机号
    text = re.sub(r'\d{17}[\dXx]', '***ID***', text)    # 身份证
    return text
```

## 5.9 总结

```
记忆设计原则:

1. 分层设计 — 不同生命周期用不同存储
2. 按需检索 — 不要让 Agent "回忆"无关信息
3. 增量更新 — 每次对话后自动提取和存储
4. 过期机制 — 记忆要有 TTL，避免无限膨胀
5. 安全第一 — 敏感信息脱敏后再存储
6. 容量控制 — 注入 prompt 的记忆要过"预算"检查

类比 Java:
  Working Memory  = ThreadLocal
  Short-term      = Redis
  Long-term       = MySQL + Elasticsearch
  Scratchpad      = 方法内的局部变量
```

---

**下一篇**：[06-主流框架对比](./06-frameworks-overview.md)
