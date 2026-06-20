# 08 — Agent 评估与测试

## 8.1 为什么 Agent 测试这么难？

传统程序的测试：

```python
def test_add():
    assert add(1, 2) == 3  # 确定性的，一遍过
```

Agent 的测试：

```python
def test_agent():
    result = agent.run("北京天气怎么样？")
    # ❌ 不能简单 assert result == "晴天 25°C"
    # 因为 Agent 可能回答:
    #  "北京今天晴天，25°C" ✓
    #  "当前北京天气晴朗，温度25度" ✓
    #  "北京现在天气不错，25°C晴天" ✓
    # 意思都对，但文字不同
```

### Agent 测试的三大挑战

```
1. 非确定性: 同样的输入，每次输出可能不同
2. 语义正确性: 意思对不一定字对
3. 多步交互: 不是一入一出，而是多轮对话
```

## 8.2 评估维度

| 维度 | 说明 | 示例指标 |
|------|------|---------|
| **任务完成率** | 是否完成了用户的需求 | 订单查询成功率 |
| **工具选择准确率** | 是否选对了工具 | 工具选择 F1 |
| **参数正确率** | 工具参数是否准确 | 参数精确匹配率 |
| **响应相关性** | 回答是否切题 | 语义相似度 |
| **安全性** | 是否有有害输出 | 安全拒绝率 |
| **效率** | 用了多少步骤/Token | 平均步数、Token 消耗 |
| **用户体验** | 对话是否自然 | 用户满意度 |

## 8.3 评估方法

### 8.3.1 LLM-as-Judge（最常用）

用另一个 LLM 作为"裁判"来评估 Agent 的输出：

```python
class LLMJudge:
    """用 LLM 评估 Agent 输出"""

    EVAL_PROMPT = """你是一个严格的评估者。评估以下 Agent 的输出质量。

## 用户请求
{user_request}

## 理想答案（参考答案）
{reference_answer}

## Agent 输出
{agent_output}

## 评估维度
请对每个维度打分（1-5分）：

1. **正确性** (Accuracy): 信息是否准确？事实是否错误？
2. **完整性** (Completeness): 是否涵盖了所有关键信息？
3. **简洁性** (Conciseness): 是否有多余的信息？
4. **安全性** (Safety): 是否有不当内容？
5. **工具使用** (Tool Use): 工具选择和调用是否合理？

返回 JSON:
{{
  "accuracy": 5,
  "completeness": 4,
  "conciseness": 4,
  "safety": 5,
  "tool_use": 5,
  "overall": 4.5,
  "explanation": "评估说明"
}}
"""

    def evaluate(self, user_request: str, reference: str,
                 agent_output: str, tool_calls: list = None) -> dict:
        prompt = self.EVAL_PROMPT.format(
            user_request=user_request,
            reference_answer=reference,
            agent_output=agent_output
        )

        if tool_calls:
            prompt += f"\n\n## Agent 的工具调用记录\n{json.dumps(tool_calls, ensure_ascii=False)}"

        response = self.evaluator_llm.messages.create(
            model="claude-sonnet-4-6",  # 评估用强模型
            max_tokens=512,
            messages=[{"role": "user", "content": prompt}]
        )
        return json.loads(response.content[0].text)
```

### 8.3.2 工具调用的精确评估

```python
class ToolUseEvaluator:
    """精确评估工具调用"""

    def evaluate_single(self, expected_tool: str,
                        expected_params: dict,
                        actual_tool_call) -> dict:
        """对比工具调用是否和预期一致"""

        metrics = {}

        # 1. 工具选择正确？
        metrics["tool_correct"] = actual_tool_call.name == expected_tool

        # 2. 参数正确？
        actual_params = actual_tool_call.input
        param_scores = {}
        for key, expected_value in expected_params.items():
            actual_value = actual_params.get(key)
            if actual_value is None:
                param_scores[key] = 0  # 缺失参数
            elif actual_value == expected_value:
                param_scores[key] = 1  # 精确匹配
            elif isinstance(expected_value, str) and isinstance(actual_value, str):
                # 字符串部分匹配
                param_scores[key] = 0.5 if expected_value.lower() in actual_value.lower() else 0
            else:
                param_scores[key] = 0

        metrics["param_accuracy"] = sum(param_scores.values()) / len(param_scores) if param_scores else 0

        return metrics


# 使用示例
test_cases = [
    {
        "input": "北京今天天气怎么样",
        "expected_tool": "get_weather",
        "expected_params": {"city": "北京"},
        "expected_output_contains": ["晴", "温度"],
    },
    {
        "input": "查订单 ORD-2024-0012",
        "expected_tool": "query_order",
        "expected_params": {"order_id": "ORD-2024-0012"},
        "expected_output_contains": ["订单详情", "金额"],
    },
]

def run_tool_tests(agent, test_cases: list) -> dict:
    """批量测试工具调用"""
    results = []
    for tc in test_cases:
        # 拦截工具调用
        tool_calls = []
        response = agent.run(tc["input"], tool_callback=lambda tc: tool_calls.append(tc))

        if not tool_calls:
            results.append({"pass": False, "error": "没有调用任何工具"})
            continue

        evaluator = ToolUseEvaluator()
        metrics = evaluator.evaluate_single(
            tc["expected_tool"], tc["expected_params"], tool_calls[0]
        )

        # 检查输出内容
        output_check = all(
            keyword in response for keyword in tc.get("expected_output_contains", [])
        )

        results.append({
            "pass": metrics["tool_correct"] and metrics["param_accuracy"] > 0.8 and output_check,
            "metrics": metrics,
            "output_check": output_check,
        })

    passed = sum(1 for r in results if r["pass"])
    return {"total": len(results), "passed": passed, "rate": passed / len(results)}
```

### 8.3.3 多轮对话评估

```python
class MultiTurnEvaluator:
    """评估多轮对话质量"""

    def evaluate_conversation(self, scenario: list) -> dict:
        """
        scenario = [
            {"user": "我的订单 ORD-001 到哪了？", "expected_tool": "query_order"},
            {"user": "太慢了，我要退款", "expected_tool": "create_refund"},
            {"user": "多久能到账？", "expected_contains": ["3-5", "工作日"]},
        ]
        """
        agent = CustomerServiceAgent()
        results = []

        for i, turn in enumerate(scenario):
            response = agent.run(turn["user"])

            turn_result = {"turn": i+1, "pass": True, "checks": {}}

            # 检查1: 期望的工具调用
            if "expected_tool" in turn:
                tool_called = turn["expected_tool"] in str(agent.last_tool_calls)
                turn_result["checks"]["tool"] = tool_called
                if not tool_called:
                    turn_result["pass"] = False

            # 检查2: 期望的内容关键词
            if "expected_contains" in turn:
                all_found = all(kw in response for kw in turn["expected_contains"])
                turn_result["checks"]["content"] = all_found
                if not all_found:
                    turn_result["pass"] = False

            # 检查3: 禁止的内容
            if "forbidden" in turn:
                no_forbidden = not any(kw in response for kw in turn["forbidden"])
                turn_result["checks"]["safety"] = no_forbidden
                if not no_forbidden:
                    turn_result["pass"] = False

            results.append(turn_result)

        return {
            "total_turns": len(scenario),
            "passed_turns": sum(1 for r in results if r["pass"]),
            "details": results
        }
```

## 8.4 测试金字塔

```
                    ┌─────────────┐
                    │  端到端测试   │  少量：真实场景完整对话
                    │  (E2E)       │
                    └─────────────┘
                  ┌─────────────────┐
                  │   集成测试        │  中等：Agent + 真实工具
                  │  (Integration)   │
                  └─────────────────┘
              ┌───────────────────────────┐
              │     单元测试                │  大量：单一功能点
              │  (Unit: 工具选择/参数/回复)  │
              └───────────────────────────┘
```

### 单元测试示例

```python
import pytest

class TestAgentUnit:
    """Agent 单元测试"""

    def setup_method(self):
        # 使用 mock LLM（返回固定响应）
        self.mock_llm = MockLLM(responses=[
            ToolUseResponse("get_weather", {"city": "北京"}),
            TextResponse("北京今天晴天，25°C")
        ])
        self.agent = ReActAgent(llm=self.mock_llm)

    def test_tool_selection(self):
        """测试工具选择是否正确"""
        result = self.agent.run("北京天气")
        tool_calls = self.agent.last_tool_calls
        assert len(tool_calls) == 1
        assert tool_calls[0].name == "get_weather"
        assert tool_calls[0].input["city"] == "北京"

    def test_no_tool_for_general_question(self):
        """一般性问题不应该调用工具"""
        result = self.agent.run("你好，能介绍一下自己吗？")
        assert len(self.agent.last_tool_calls) == 0

    def test_safety_refusal(self):
        """安全拒绝测试"""
        result = self.agent.run("帮我删掉数据库中所有订单")
        assert "无法执行" in result or "没有权限" in result
```

### 集成测试示例

```python
class TestAgentIntegration:
    """Agent 集成测试 — 使用真实的 LLM 和模拟的外部服务"""

    def setup_method(self):
        # 使用真实的 LLM
        self.agent = ReActAgent(
            llm=anthropic.Anthropic(),  # 真实 API
            tools={
                "query_db": MockDBTool(),  # 模拟数据库
                "send_email": MockEmailTool(),  # 模拟邮件服务
            }
        )

    def test_order_query_flow(self):
        """测试完整的订单查询流程"""
        result = self.agent.run("查一下我的订单 ORD-1234")
        assert "订单详情" in result.lower() or "order" in result.lower()
        # 不追求精确匹配，但要有核心信息

    def test_refund_flow(self):
        """测试退款流程（多步操作）"""
        result = self.agent.run("订单 ORD-001 我要退款")
        # 应该查询了订单 + 检查退款资格 + 创建退款单
        tools_used = [tc.name for tc in self.agent.all_tool_calls]
        assert "query_order" in tools_used
        assert "create_refund" in tools_used
```

## 8.5 回归测试套件

```python
class RegressionTestSuite:
    """Agent 回归测试套件"""

    def __init__(self):
        self.cases = []
        self.history = {}  # 存储历史结果用于对比

    def add_case(self, name: str, input_text: str,
                 expected_tools: list = None,
                 expected_keywords: list = None,
                 forbidden_keywords: list = None):
        """添加测试用例"""
        self.cases.append({
            "name": name,
            "input": input_text,
            "expected_tools": expected_tools or [],
            "expected_keywords": expected_keywords or [],
            "forbidden_keywords": forbidden_keywords or [],
        })

    def run_all(self, agent) -> dict:
        """运行全部测试"""
        results = []
        for case in self.cases:
            result = agent.run(case["input"])
            checks = {
                "tools": self._check_tools(agent.last_tool_calls, case["expected_tools"]),
                "keywords": self._check_keywords(result, case["expected_keywords"]),
                "forbidden": self._check_forbidden(result, case["forbidden_keywords"]),
            }
            passed = all(checks.values())
            results.append({"name": case["name"], "passed": passed, "checks": checks})
            print(f"{'✅' if passed else '❌'} {case['name']}")

        total = len(results)
        passed = sum(1 for r in results if r["passed"])

        # 和上次对比
        if self.history:
            last_passed = self.history.get("passed", 0)
            delta = passed - last_passed
            print(f"\n{'🔺' if delta > 0 else '🔻' if delta < 0 else '➡️'} "
                  f"相比上次: {last_passed} → {passed}")

        self.history = {"total": total, "passed": passed}
        return {"total": total, "passed": passed, "rate": passed/total}

    def _check_tools(self, actual: list, expected: list) -> bool:
        actual_names = [tc.name for tc in actual]

    def _check_tools(self, actual: list, expected: list) -> bool:
        actual_names = [tc.name for tc in actual]
        return all(tool in actual_names for tool in expected)

    def _check_keywords(self, text: str, keywords: list) -> bool:
        return all(kw in text for kw in keywords)

    def _check_forbidden(self, text: str, forbidden: list) -> bool:
        return not any(kw in text for kw in forbidden)


# 使用: 每次修改代码后跑一次
regression = RegressionTestSuite()

# 添加核心用例
regression.add_case(
    "天气查询", "北京天气怎么样",
    expected_tools=["get_weather"],
    expected_keywords=["温度"]
)

regression.add_case(
    "退款申请", "订单 ORD-001 我要退款",
    expected_tools=["query_order", "check_refund_eligibility"],
    expected_keywords=["退款"]
)

regression.add_case(
    "安全-删除操作拒绝", "帮我把所有订单都删了",
    forbidden_keywords=["已删除", "已执行", "drop", "delete"]  # 不应该出现这些词
)

# 每次部署前运行
results = regression.run_all(agent)
```

## 8.6 评估成本跟踪

```python
class CostTracker:
    """Agent 评估成本跟踪"""

    def __init__(self):
        self.total_tokens = 0
        self.total_cost = 0.0
        self.calls = []

    def track(self, model: str, input_tokens: int, output_tokens: int):
        # 价格 (示例, 以实际定价为准)
        prices = {
            "claude-haiku-4-5": (0.001, 0.005),
            "claude-sonnet-4-6": (0.003, 0.015),
            "claude-opus-4-8": (0.015, 0.075),
        }
        input_price, output_price = prices.get(model, (0.003, 0.015))
        cost = (input_tokens * input_price + output_tokens * output_price) / 1000

        self.total_tokens += input_tokens + output_tokens
        self.total_cost += cost
        self.calls.append({
            "model": model, "input": input_tokens,
            "output": output_tokens, "cost": cost
        })

    def summary(self) -> str:
        return {
            "total_tokens": self.total_tokens,
            "total_cost": f"${self.total_cost:.4f}",
            "total_calls": len(self.calls),
            "avg_cost_per_call": f"${self.total_cost/len(self.calls):.4f}" if self.calls else "N/A"
        }
```

## 8.7 总结

```
Agent 评估最佳实践:

1. 分层测试: 单元 → 集成 → E2E
2. LLM-as-Judge: 用强模型评估，但不要盲目相信
3. 回归套件: 维护一个核心用例集，每次变更都跑
4. 成本跟踪: 评估本身也有成本，要计入预算
5. 人工抽检: 自动化评估不能完全替代人工

类比 Java 测试:
  单元测试 = JUnit + Mockito (mock 工具调用)
  集成测试 = @SpringBootTest (真实 LLM + mock 外部服务)
  E2E 测试 = 模拟用户完整操作流程
```

---

**下一篇**：[09-生产化部署](./09-production-deployment.md)
