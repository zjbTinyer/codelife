# 09 — 生产化部署

## 9.1 Agent 上生产的核心挑战

把 Agent 从"能跑的 Demo"变成"生产级服务"，类似于把 Spring Boot 单体变成微服务集群，需要考虑很多"额外的东西"：

```
开发阶段:
  只关心: 能不能完成用户的任务？

生产阶段:
  还要关心:
  ├── 安全: 会不会被注入攻击？
  ├── 成本: 一次调用花了多少钱？
  ├── 延迟: 用户等了多久？
  ├── 可用性: 挂了怎么办？
  ├── 合规: 日志是否记录了关键决策？
  ├── 监控: 现在有多少 Agent 正在运行？
  └── 版本: 如何灰度发布新的 System Prompt？
```

## 9.2 安全防护

### 9.2.1 Prompt Injection 防御

```python
class PromptInjectionGuard:
    """Prompt 注入检测与防御"""

    INJECTION_PATTERNS = [
        r"ignore (all |your )?(previous |above )?instructions?",
        r"forget (all |your )?(previous |above )?instructions?",
        r"you are now .* instead",
        r"new system prompt",
        r"你的新身份是",
        r"忽略(所有)?(之前的)指令",
    ]

    def detect(self, user_input: str) -> dict:
        """检测是否包含注入攻击"""
        import re

        for pattern in self.INJECTION_PATTERNS:
            if re.search(pattern, user_input, re.IGNORECASE):
                return {
                    "is_attack": True,
                    "matched_pattern": pattern,
                    "action": "block"
                }

        # 也检查长度和特殊字符
        if len(user_input) > 10000:
            return {"is_attack": True, "reason": "输入过长", "action": "block"}

        return {"is_attack": False}

    def sanitize(self, user_input: str) -> str:
        """清理用户输入"""
        # 移除潜在的指令分隔符
        dangerous = [
            "### System:", "### System：",
            "<<SYS>>", "<</SYS>>",
            "[INST]", "[/INST]",
        ]
        cleaned = user_input
        for d in dangerous:
            cleaned = cleaned.replace(d, "")
        return cleaned


# 在 Agent 中使用
class SecureAgent:
    def __init__(self):
        self.guard = PromptInjectionGuard()

    def run(self, user_input: str) -> str:
        # 1. 检测注入
        detection = self.guard.detect(user_input)
        if detection["is_attack"]:
            print(f"[Security] 检测到注入攻击: {detection}")
            return "我无法处理这个请求。如有疑问请联系人工客服。"

        # 2. 清理输入
        cleaned_input = self.guard.sanitize(user_input)

        # 3. 正常处理
        return self.agent.run(cleaned_input)
```

### 9.2.2 工具调用安全

```python
class ToolSecurityPolicy:
    """工具调用安全策略"""

    def __init__(self):
        # 每个工具的权限策略
        self.policies = {
            "query_db": {
                "allowed_operations": ["SELECT"],
                "max_rows": 100,
                "rate_limit_per_minute": 30,
                "timeout_seconds": 5,
            },
            "send_email": {
                "allowed_domains": ["@company.com"],
                "max_recipients": 5,
                "rate_limit_per_minute": 10,
                "require_approval": True,  # 需要人工审核
            },
            "create_refund": {
                "max_amount": 500.00,
                "rate_limit_per_minute": 3,
                "require_approval": True,
            },
        }

    def authorize(self, tool_name: str, params: dict) -> dict:
        """授权检查 — 类似 Spring Security 的 @PreAuthorize"""
        policy = self.policies.get(tool_name)

        if not policy:
            return {"authorized": False, "reason": "未知工具"}

        # 限流检查
        if not self._check_rate_limit(tool_name, policy):
            return {"authorized": False, "reason": "频率超限"}

        # 参数安全检查
        if tool_name == "query_db":
            sql = params.get("sql", "")
            if not sql.strip().upper().startswith("SELECT"):
                return {"authorized": False, "reason": "仅允许 SELECT"}
            if any(kw in sql.upper() for kw in ["DROP", "DELETE", "--", "EXEC"]):
                return {"authorized": False, "reason": "包含危险操作"}

        elif tool_name == "send_email":
            to_addr = params.get("to", "")
            allowed = any(to_addr.endswith(d) for d in policy["allowed_domains"])
            if not allowed:
                return {"authorized": False, "reason": "仅允许发送到公司邮箱"}

        elif tool_name == "create_refund":
            if params.get("amount", 0) > policy["max_amount"]:
                return {
                    "authorized": False,
                    "reason": f"退款金额超过上限 {policy['max_amount']}",
                    "escalate_to": "human_approval"
                }

        return {"authorized": True}

    def _check_rate_limit(self, tool_name: str, policy: dict) -> bool:
        """滑动窗口限流"""
        minute_ago = time.time() - 60
        recent_calls = [t for t in self.call_history[tool_name] if t > minute_ago]
        return len(recent_calls) < policy["rate_limit_per_minute"]
```

### 9.2.3 输出安全

```python
class OutputSafetyCheck:
    """输出安全检查"""

    def __init__(self):
        self.forbidden_patterns = [
            (r'\b\d{3}-\d{2}-\d{4}\b', '***SSN***'),      # SSN
            (r'\b\d{16}\b', '***CC***'),                    # 信用卡号
            (r'password\s*[=:]\s*\S+', 'password=***'),     # 密码泄露
        ]
        self.sensitive_keywords = [
            "API_KEY", "SECRET", "TOKEN", "PRIVATE_KEY"
        ]

    def check(self, text: str) -> dict:
        """检查输出是否包含不适当内容"""
        import re
        issues = []

        # 1. 敏感信息泄露检查
        for pattern, replacement in self.forbidden_patterns:
            matches = re.findall(pattern, text)
            if matches:
                issues.append({
                    "type": "sensitive_data",
                    "count": len(matches),
                    "details": f"发现 {len(matches)} 处可疑敏感信息"
                })

        # 2. 有害内容检查（可用单独的 LLM 做）
        # 3. 幻觉内容检查（引用了不存在的订单号等）

        return {
            "safe": len(issues) == 0,
            "issues": issues,
            "sanitized": self._sanitize(text) if issues else text
        }

    def _sanitize(self, text: str) -> str:
        import re
        for pattern, replacement in self.forbidden_patterns:
            text = re.sub(pattern, replacement, text)
        return text
```

## 9.3 成本控制

### 9.3.1 Token 预算管理

```python
class TokenBudget:
    """Token 预算管理器"""

    def __init__(self, daily_limit: int = 1_000_000, per_session_limit: int = 100_000):
        self.daily_limit = daily_limit
        self.per_session_limit = per_session_limit
        self.daily_used = 0
        self.session_budgets = {}  # session_id → remaining

    def start_session(self, session_id: str) -> int:
        """开始新会话，分配预算"""
        remaining_daily = self.daily_limit - self.daily_used
        budget = min(self.per_session_limit, remaining_daily)
        self.session_budgets[session_id] = budget
        return budget

    def consume(self, session_id: str, tokens: int) -> bool:
        """消费 Token"""
        if session_id not in self.session_budgets:
            return False

        remaining = self.session_budgets[session_id]
        if tokens > remaining:
            print(f"[Budget] 会话 {session_id[:8]} 预算耗尽")
            return False

        self.session_budgets[session_id] -= tokens
        self.daily_used += tokens
        return True

    def get_remaining(self, session_id: str) -> int:
        return self.session_budgets.get(session_id, 0)

    def is_daily_exhausted(self) -> bool:
        return self.daily_used >= self.daily_limit


# 在 Agent 中集成
class BudgetAwareAgent:
    def __init__(self, budget: TokenBudget):
        self.budget = budget

    def run(self, session_id: str, user_input: str) -> str:
        if self.budget.is_daily_exhausted():
            return "服务暂时繁忙，请稍后再试。如紧急请拨打客服热线。"

        remaining = self.budget.get_remaining(session_id)
        if remaining < 1000:  # 低于 1000 token 就温和提示
            return ("您的会话预算即将用尽。建议简化问题或开启新会话。\n\n"
                    f"预算剩余: ~{remaining} tokens")

        # 正常处理（每次 LLM 调用后更新消费）
        response = self.agent.run(user_input)
        return response
```

### 9.3.2 模型降级策略

```python
class ModelDegradation:
    """根据预算和负载自动降级模型"""

    MODELS = {
        "premium": "claude-opus-4-8",    # 复杂任务
        "standard": "claude-sonnet-4-6", # 日常任务
        "economy": "claude-haiku-4-5",   # 简单任务
    }

    def select_model(self, task_complexity: str,
                     budget_remaining: int,
                     latency_requirement: str = "normal") -> str:
        """选择最合适的模型"""

        # 预算充足 + 复杂任务 → 旗舰模型
        if task_complexity == "complex" and budget_remaining > 50000:
            return self.MODELS["premium"]

        # 预算紧张 → 降级
        if budget_remaining < 10000:
            return self.MODELS["economy"]

        # 低延迟要求 → 快模型
        if latency_requirement == "low":
            return self.MODELS["economy"]

        # 默认
        return self.MODELS["standard"]

    def with_fallback(self, primary_model: str) -> str:
        """如果主模型不可用，自动降级"""
        fallback_chain = {
            "claude-opus-4-8": "claude-sonnet-4-6",
            "claude-sonnet-4-6": "claude-haiku-4-5",
        }
        return fallback_chain.get(primary_model, primary_model)
```

## 9.4 监控与可观测性

```python
import time
import logging
from dataclasses import dataclass, field
from typing import Optional

@dataclass
class AgentSpan:
    """单次 Agent 调用的跟踪记录"""
    trace_id: str
    session_id: str
    user_input: str
    steps: list = field(default_factory=list)
    total_tokens: int = 0
    total_cost: float = 0.0
    total_time_ms: float = 0.0
    success: bool = False
    error: Optional[str] = None

class AgentObservability:
    """Agent 可观测性框架"""

    def __init__(self):
        self.logger = logging.getLogger("agent")
        self.metrics = MetricsCollector()

    def trace_call(self, trace_id: str, session_id: str,
                   user_input: str) -> AgentSpan:
        return AgentSpan(
            trace_id=trace_id,
            session_id=session_id,
            user_input=user_input
        )

    def record_step(self, span: AgentSpan, step_num: int,
                    action: str, tokens: int, latency_ms: float):
        """记录每一步"""
        span.steps.append({
            "step": step_num,
            "action": action,
            "tokens": tokens,
            "latency_ms": latency_ms
        })
        span.total_tokens += tokens
        span.total_time_ms += latency_ms

        # 实时指标上报
        self.metrics.record("agent.step.latency", latency_ms)
        self.metrics.record("agent.step.tokens", tokens)

    def finish_trace(self, span: AgentSpan, success: bool,
                     error: str = None):
        """完成追踪"""
        span.success = success
        span.error = error

        # 结构化日志
        self.logger.info(json.dumps({
            "event": "agent_call_complete",
            "trace_id": span.trace_id,
            "session_id": span.session_id,
            "steps": len(span.steps),
            "tokens": span.total_tokens,
            "time_ms": span.total_time_ms,
            "success": success,
            "error": error
        }, ensure_ascii=False))

        # 业务指标
        self.metrics.record("agent.call.total", 1)
        if success:
            self.metrics.record("agent.call.success", 1)
        else:
            self.metrics.record("agent.call.failure", 1)
        self.metrics.record("agent.call.tokens", span.total_tokens)
        self.metrics.record("agent.call.latency", span.total_time_ms)


# Mock MetricsCollector (生产中用 Prometheus/Datadog)
class MetricsCollector:
    def record(self, name: str, value: float):
        # In production: prometheus_client.Counter / Histogram
        pass
```

## 9.5 架构设计

```
生产环境 Agent 系统架构:

┌─────────────────────────────────────────────────────┐
│                    Load Balancer                      │
│                  (Nginx / ALB)                        │
└────────────────────┬────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────┐
│              API Gateway + Auth                       │
│         (Kong / Spring Cloud Gateway)                 │
└────┬──────────┬──────────┬──────────┬────────────────┘
     │          │          │          │
┌────▼────┐ ┌───▼───┐ ┌───▼───┐ ┌───▼──────┐
│ Router  │ │ Agent │ │ Agent │ │ Agent     │
│ Service │ │ Pool 1│ │ Pool 2│ │ Pool 3    │
└────┬────┘ └───┬───┘ └───┬───┘ └───┬──────┘
     │          │          │          │
     └──────────┴──────────┴──────────┘
                     │
┌────────────────────┴────────────────────────────────┐
│              Shared Services                          │
│  ┌──────────┐ ┌──────────┐ ┌───────────────────┐    │
│  │ Memory   │ │ Tool     │ │ Observability     │    │
│  │ (Redis)  │ │ Registry │ │ (Prometheus/Graf) │    │
│  └──────────┘ └──────────┘ └───────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### 关键组件

```
1. API Gateway: 认证、限流、请求路由
2. Router Service: 意图识别、分发到专业 Agent Pool
3. Agent Pool: 多个 Agent 实例，通过 Redis 共享会话状态
4. Tool Registry: 工具的统一注册和发现（类似 Nacos/Eureka）
5. Memory (Redis): 跨实例共享对话状态
6. Observability: 日志 + 指标 + 追踪 (ELK + Prometheus + Jaeger)
```

## 9.6 部署检查清单

```markdown
## Agent 上线前检查清单

### 安全
- [ ] Prompt Injection 防护已启用
- [ ] 工具调用权限控制已配置
- [ ] 敏感信息（API Key、密码）不在日志中输出
- [ ] 输出安全过滤已启用
- [ ] 用户输入长度限制已设置

### 性能
- [ ] LLM API 调用有超时设置（建议 30s）
- [ ] 工具执行有超时设置
- [ ] 并发会话数有限流
- [ ] 连接池配置合理（HTTP Client）

### 成本
- [ ] 每会话 Token 预算已设置
- [ ] 每日 Token 总量上限已设置
- [ ] 模型降级策略已配置
- [ ] Prompt Cache 已启用（减少重复成本）

### 可靠性
- [ ] LLM API 失败有重试机制
- [ ] 工具调用失败有降级策略
- [ ] 多步任务有最大步骤限制
- [ ] 有熔断机制（连续失败 N 次后暂停）

### 监控
- [ ] 成功率监控已配置
- [ ] 平均延迟监控已配置
- [ ] Token 消耗监控已配置
- [ ] 告警规则已设置（成功率 <95% 告警）

### 运维
- [ ] 日志级别、保留策略已设置
- [ ] 灰度发布方案已准备（先放 10% 流量）
- [ ] 回滚方案已准备
- [ ] 人工客服接管流程已就绪
```

## 9.7 总结

```
生产化部署的核心理念:

1. 安全第一
   Agent 的能力越大，安全风险越大
   每增加一个工具 = 增加一个攻击面

2. 成本可控
   LLM 调用是"花钱"，不是"免费"的
   按天、按会话、按用户做预算

3. 可观测
   你不知道 Agent 内部发生了什么
   → 要把每一步都记下来

4. 兜底方案
   Agent 会犯错，一定会
   → 准备好人工介入的通道

Java 类比:
  Agent 安全 ≈ Spring Security
  Agent 限流 ≈ Sentinel
  Agent 监控 ≈ Micrometer + Prometheus
  Agent 降级 ≈ Hystrix / Resilience4j
```

---

**下一篇**：[10-实战项目](./10-hands-on-project.md)
