# 1.3 — AI 系统可靠性工程

## 1. AI 系统为什么"不可靠"？

传统软件故障通常可预测（异常栈、HTTP 状态码），但 AI 的失败模式多种多样：

```
传统软件失败:
  NullPointerException → 栈追踪 → 修复 null 检查 ✓ 可预测

AI 系统失败:
  - 模型幻觉：编造了不存在的订单号
  - 工具选择错误：应该查订单，却调了退款
  - 超时：LLM API 响应慢，Agent 循环卡住
  - 输出格式异常：期望 JSON，返回了 Markdown
  - 成本爆炸：一个请求跑了 50 步工具调用
  - 内容安全：输出了不应该输出的信息
```

**可靠性工程的目标**：让 AI 系统在面对这些不确定因素时，仍能正常工作或优雅降级。

## 2. 错误分类与处理矩阵

```python
class AIFailureMode:
    """AI 系统故障模式分类"""

    FAILURE_MATRIX = {
        # (故障类型, 处理策略, 是否可重试)
        "llm_timeout": ("LLM API 超时", "retry_with_backoff", True),
        "llm_rate_limit": ("API 限流", "wait_and_retry", True),
        "llm_bad_output": ("LLM输出格式错误", "retry_with_stricter_prompt", True),
        "tool_timeout": ("工具执行超时", "retry_or_skip", True),
        "tool_error": ("工具执行失败", "retry_or_fallback", True),
        "hallucination": ("模型幻觉", "fact_check_and_correct", False),
        "infinite_loop": ("Agent 循环不终止", "force_terminate", False),
        "cost_runaway": ("Token消耗过大", "budget_enforce", False),
        "safety_violation": ("安全违规", "block_and_log", False),
        "tool_misuse": ("工具滥用", "block_and_escalate", False),
    }

    @classmethod
    def get_strategy(cls, failure_type: str) -> tuple:
        return cls.FAILURE_MATRIX.get(failure_type, ("未知错误", "escalate_to_human", False))
```

## 3. 核心可靠性模式

### 3.1 重试与退避

```python
import time
import random
from functools import wraps

class RetryPolicy:
    """可配置的重试策略"""

    def __init__(self, max_retries: int = 3, base_delay: float = 1.0,
                 max_delay: float = 30.0, backoff_factor: float = 2.0,
                 jitter: bool = True,
                 retryable_errors: tuple = (TimeoutError, ConnectionError)):
        self.max_retries = max_retries
        self.base_delay = base_delay
        self.max_delay = max_delay
        self.backoff_factor = backoff_factor
        self.jitter = jitter
        self.retryable_errors = retryable_errors

    def execute(self, func, *args, **kwargs):
        """执行函数，自动重试"""
        last_error = None

        for attempt in range(self.max_retries + 1):
            try:
                return func(*args, **kwargs)
            except self.retryable_errors as e:
                last_error = e
                if attempt == self.max_retries:
                    break

                delay = min(
                    self.base_delay * (self.backoff_factor ** attempt),
                    self.max_delay
                )

                if self.jitter:
                    delay *= (0.5 + random.random())  # ±50% jitter

                print(f"[Retry {attempt+1}/{self.max_retries}] "
                      f"错误: {e}, {delay:.1f}s后重试")
                time.sleep(delay)

        raise last_error


# LLM 调用专用重试
class LLMRetryPolicy(RetryPolicy):
    """LLM API 重试策略"""

    def __init__(self):
        super().__init__(
            max_retries=3,
            base_delay=1.0,
            max_delay=10.0,
            backoff_factor=2.0
        )

    def should_retry_on(self, error: Exception) -> bool:
        """判断 LLM 错误是否可重试"""
        error_str = str(error).lower()

        # 可重试的错误
        retryable = ["timeout", "rate_limit", "server_error", "503", "502", "overloaded"]
        if any(kw in error_str for kw in retryable):
            return True

        # 不可重试的错误
        non_retryable = ["invalid_api_key", "authentication", "not_found", "invalid_request"]
        if any(kw in error_str for kw in non_retryable):
            return False

        return True  # 默认重试
```

### 3.2 熔断器模式

```python
from datetime import datetime, timedelta

class CircuitBreaker:
    """熔断器 — 连续失败N次后暂时停止调用"""

    STATE_CLOSED = "closed"        # 正常
    STATE_OPEN = "open"            # 熔断
    STATE_HALF_OPEN = "half_open"  # 尝试恢复

    def __init__(self, failure_threshold: int = 5,
                 recovery_timeout: float = 30.0,
                 half_open_max_requests: int = 3):
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.half_open_max_requests = half_open_max_requests

        self.state = self.STATE_CLOSED
        self.failure_count = 0
        self.last_failure_time = None
        self.half_open_requests = 0

    def call(self, func, *args, **kwargs):
        """受熔断器保护的调用"""
        if self.state == self.STATE_OPEN:
            if self._should_try_recovery():
                self.state = self.STATE_HALF_OPEN
                self.half_open_requests = 0
                print("[CircuitBreaker] 进入半开状态，尝试恢复...")
            else:
                raise CircuitBreakerOpenError("熔断器已打开，拒绝请求")

        if self.state == self.STATE_HALF_OPEN:
            if self.half_open_requests >= self.half_open_max_requests:
                raise CircuitBreakerOpenError("半开状态下请求达到上限")
            self.half_open_requests += 1

        try:
            result = func(*args, **kwargs)
            self._on_success()
            return result
        except Exception as e:
            self._on_failure()
            raise e

    def _on_success(self):
        self.failure_count = 0
        if self.state == self.STATE_HALF_OPEN:
            self.state = self.STATE_CLOSED
            print("[CircuitBreaker] 已恢复正常 ✓")

    def _on_failure(self):
        self.failure_count += 1
        self.last_failure_time = datetime.now()
        if (self.state == self.STATE_CLOSED and
                self.failure_count >= self.failure_threshold):
            self.state = self.STATE_OPEN
            print(f"[CircuitBreaker] 连续失败{self.failure_count}次，熔断！")

    def _should_try_recovery(self) -> bool:
        if self.last_failure_time is None:
            return True
        elapsed = (datetime.now() - self.last_failure_time).total_seconds()
        return elapsed >= self.recovery_timeout


class CircuitBreakerOpenError(Exception):
    pass
```

### 3.3 超时控制

```python
import signal
import asyncio
from concurrent.futures import ThreadPoolExecutor, TimeoutError

class TimeoutGuard:
    """超时保护"""

    @staticmethod
    def run_with_timeout(func, timeout: float, *args, **kwargs):
        """在超时时间内执行函数"""
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(func, *args, **kwargs)
            try:
                return future.result(timeout=timeout)
            except TimeoutError:
                future.cancel()
                raise TimeoutError(f"操作超时 ({timeout}s): {func.__name__}")

# Agent 级别的超时配置
AGENT_TIMEOUTS = {
    "llm_api_call": 30.0,        # 单次 LLM 调用
    "tool_execution": 10.0,      # 单个工具执行
    "agent_total": 60.0,         # 整个 Agent 任务
    "user_response": 300.0,      # 等待用户输入
}


class TimeoutAwareAgent:
    """带超时保护的 Agent"""

    def __init__(self, timeouts: dict = None):
        self.timeouts = timeouts or AGENT_TIMEOUTS
        self.start_time = None

    def run(self, user_input: str) -> str:
        self.start_time = time.time()

        try:
            return self._run_with_total_timeout(user_input)
        except TimeoutError:
            elapsed = time.time() - self.start_time
            return (f"处理超时，已完成的部分可能不完整。"
                    f"(耗时 {elapsed:.1f}s)。请尝试简化您的问题。")

    def _run_with_total_timeout(self, user_input: str) -> str:
        total_timeout = self.timeouts["agent_total"]
        return TimeoutGuard.run_with_timeout(
            self._execute, total_timeout, user_input
        )

    def _execute(self, user_input: str) -> str:
        """实际的 Agent 执行逻辑"""
        for step in range(max_steps):
            # 检查总体时间
            elapsed = time.time() - self.start_time
            if elapsed > self.timeouts["agent_total"] * 0.8:
                print(f"[Warning] 接近总超时: {elapsed:.1f}s")

            # LLM 调用带超时
            try:
                response = TimeoutGuard.run_with_timeout(
                    self.llm_call, self.timeouts["llm_api_call"],
                    self.messages
                )
            except TimeoutError:
                return "LLM 响应超时，请稍后重试。"

            # 工具执行带超时
            for tool in response.tool_calls:
                try:
                    result = TimeoutGuard.run_with_timeout(
                        self.execute_tool, self.timeouts["tool_execution"],
                        tool
                    )
                except TimeoutError:
                    result = {"error": "工具执行超时，已跳过"}

            # ...

        return final_response
```

### 3.4 降级策略

```python
class DegradationManager:
    """优雅降级管理器"""

    def __init__(self):
        self.degradation_level = 0  # 0=正常, 1=部分降级, 2=大幅降级, 3=最小服务

    def execute(self, task: str, context: dict) -> str:
        """根据降级级别执行任务"""

        if self.degradation_level == 0:
            # 正常模式：全功能
            return self._full_service(task, context)

        elif self.degradation_level == 1:
            # 部分降级：跳过可选功能
            return self._reduced_service(task, context)

        elif self.degradation_level == 2:
            # 大幅降级：只用本地能力
            return self._minimal_service(task, context)

        else:  # level 3
            # 最小服务：只返回静态帮助信息
            return self._emergency_service(task)

    def _full_service(self, task, context):
        """正常模式"""
        return self.agent.run(task, tools=ALL_TOOLS, model="claude-sonnet-4-6")

    def _reduced_service(self, task, context):
        """部分降级：不使用高级工具"""
        return self.agent.run(task, tools=BASIC_TOOLS, model="claude-haiku-4-5")

    def _minimal_service(self, task, context):
        """大幅降级：只用本地规则"""
        # 用关键词匹配做基本意图识别
        if "订单" in task or "order" in task.lower():
            return "订单查询功能暂时受限，请提供订单号，我们会稍后处理。"
        return "服务暂时繁忙，已记录您的请求，稍后会有客服联系您。"

    def _emergency_service(self, task):
        """紧急模式"""
        return ("非常抱歉，我们正在处理一个技术问题。"
                "请拨打 400-888-8888 或稍后重试。")

    def update_level(self, metrics: dict):
        """根据监控指标自动调整降级级别"""
        error_rate = metrics.get("error_rate", 0)
        avg_latency = metrics.get("avg_latency", 0)
        llm_available = metrics.get("llm_available", True)

        if not llm_available:
            self.degradation_level = 3
        elif error_rate > 0.5 or avg_latency > 10.0:
            self.degradation_level = 2
        elif error_rate > 0.2 or avg_latency > 5.0:
            self.degradation_level = 1
        else:
            self.degradation_level = 0
```

### 3.5 预算保护（防成本爆炸）

```python
class BudgetGuard:
    """Token 预算保护"""

    def __init__(self, session_limit: int = 50000, step_limit: int = 5000):
        self.session_limit = session_limit
        self.step_limit = step_limit
        self.session_used = 0
        self.warnings_issued = 0

    def check_step(self, tokens_about_to_use: int) -> bool:
        """步骤前检查"""
        if tokens_about_to_use > self.step_limit:
            print(f"[BudgetGuard] 单步 Token ({tokens_about_to_use}) 超过限制 ({self.step_limit})")
            return False

        if self.session_used + tokens_about_to_use > self.session_limit:
            remaining = self.session_limit - self.session_used
            if remaining > 1000:
                print(f"[BudgetGuard] 预算不足，剩余: {remaining}")
            return False

        return True

    def consume(self, tokens: int):
        """消费 Token"""
        self.session_used += tokens

        # 80% 时发出警告
        if (self.session_used > self.session_limit * 0.8
                and self.warnings_issued == 0):
            print(f"[BudgetGuard] ⚠️ 已使用 {self.session_used}/{self.session_limit} tokens")
            self.warnings_issued += 1

    def get_remaining(self) -> int:
        return max(0, self.session_limit - self.session_used)


# 在 Agent 循环中集成
class BudgetAwareLoop:
    def run(self, user_input: str) -> str:
        budget = BudgetGuard(session_limit=50000)

        for step in range(max_steps):
            # 检查预算
            if not budget.check_step(2000):  # 预估本步消耗
                return ("当前会话已达到预算上限。"
                       "请简化问题或开启新会话。已完成的部分如下：\n"
                       + self._partial_results())

            response = self.llm_call()
            tokens_used = response.usage.total_tokens
            budget.consume(tokens_used)

            # ...
```

## 4. 可靠性模式组合

```python
class ReliableAgent:
    """整合所有可靠性模式的 Agent"""

    def __init__(self):
        self.retry_policy = LLMRetryPolicy()
        self.circuit_breaker = CircuitBreaker(failure_threshold=5)
        self.budget_guard = BudgetGuard()
        self.degradation = DegradationManager()
        self.timeout_guard = TimeoutGuard()

    def run(self, user_input: str, context: dict) -> str:
        # 检查熔断器
        try:
            return self.circuit_breaker.call(self._execute, user_input, context)
        except CircuitBreakerOpenError:
            # 熔断中 → 降级处理
            self.degradation.update_level({
                "error_rate": 1.0,
                "llm_available": False
            })
            return self.degradation.execute(user_input, context)

    def _execute(self, user_input: str, context: dict) -> str:
        # 总超时保护
        return self.timeout_guard.run_with_timeout(
            self._agent_loop,
            AGENT_TIMEOUTS["agent_total"],
            user_input, context
        )

    def _agent_loop(self, user_input: str, context: dict) -> str:
        for step in range(10):
            # 预算检查
            if not self.budget_guard.check_step(2000):
                return self._partial_results()

            # LLM 调用（带重试）
            response = self.retry_policy.execute(
                self.llm_api_call, user_input
            )

            # 工具执行（带重试和超时）
            for tool in response.tool_calls:
                try:
                    result = self.retry_policy.execute(
                        self.timeout_guard.run_with_timeout,
                        self.execute_tool,
                        AGENT_TIMEOUTS["tool_execution"],
                        tool
                    )
                except Exception as e:
                    # 工具失败 → 记录并继续
                    result = {"error": str(e), "tool": tool.name}

            # ...
```

## 5. 可靠性度量

```python
class ReliabilityMetrics:
    """可靠性指标收集"""

    def __init__(self):
        self.metrics = {
            "total_requests": 0,
            "successful": 0,
            "failed": 0,
            "degraded": 0,
            "retried": 0,
            "circuit_breaker_trips": 0,
            "timeouts": 0,
            "budget_exhausted": 0,
        }

    def compute_sli(self) -> dict:
        """计算 SLI (Service Level Indicators)"""
        total = self.metrics["total_requests"]
        if total == 0:
            return {}

        return {
            "availability": (self.metrics["successful"] + self.metrics["degraded"]) / total,
            "success_rate": self.metrics["successful"] / total,
            "degradation_rate": self.metrics["degraded"] / total,
            "retry_rate": self.metrics["retried"] / total,
            "timeout_rate": self.metrics["timeouts"] / total,
        }

    def check_slo(self, sli: dict) -> bool:
        """检查是否满足 SLO"""
        # SLO 目标
        targets = {
            "availability": 0.995,   # 99.5%
            "success_rate": 0.95,    # 95%
            "timeout_rate": 0.01,    # <1%
        }
        for metric, target in targets.items():
            if sli.get(metric, 1.0) < target:
                print(f"[SLO] ❌ {metric}: {sli[metric]:.3f} < {target}")
                return False
        return True
```

## 6. 总结

```
AI 系统可靠性工程核心理念:

1. 假设一切都会失败
   LLM 会幻觉、工具会超时、API 会限流
   → 为每种失败模式设计处理策略

2. 优先保护系统
   一个坏请求不能拖垮整个服务
   → 超时 + 熔断 + 限流 + 预算

3. 优雅降级 > 完全失败
   部分功能不可用时，提供降级服务
   → 不要 all-or-nothing

4. 可观测 = 可控制
   不知道哪里出了问题就无法修复
   → 所有失败都要记录和度量

Java 类比:
  重试策略  = Resilience4j Retry / Spring Retry
  熔断器    = Resilience4j CircuitBreaker / Hystrix
  限流      = Sentinel / RateLimiter
  超时控制  = @Transactional(timeout=30)
  降级      = @HystrixCommand(fallbackMethod=...)
```
