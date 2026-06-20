# 1.5 — LLM 可观测性

## 1. 什么是 LLM 可观测性？

可观测性不仅仅是"监控"。它是通过**日志(Logs)、指标(Metrics)、追踪(Traces)**来理解系统内部状态的能力。

```
LLM 可观测性的"三个知道":
1. 知道 Agent 在做什么（每一步的思考和行动）
2. 知道系统花费了多少（Token、延迟、成本）
3. 知道哪里出了问题（错误、异常、降级）
```

### LLM 特有的可观测性挑战

| 传统系统 | LLM 系统 |
|---------|---------|
| 固定执行路径 | 动态决策（Agent 自己选下一步） |
| 二进制结果 | 语义结果（"对"但不精确） |
| HTTP 状态码 | "我理解你的需求"（真的理解吗？） |
| 数据库查询耗时 | 这个 Prompt 为什么效果不好？ |

## 2. 追踪 (Tracing)

### 2.1 单次调用追踪

```python
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional
import json

@dataclass
class Span:
    """追踪 Span"""
    span_id: str
    parent_id: Optional[str]
    name: str               # "llm_call", "tool_execute", "agent_step"
    start_time: float
    end_time: Optional[float] = None

    # LLM 专用字段
    model: Optional[str] = None
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cost: float = 0.0

    # 业务字段
    input: Optional[str] = None
    output: Optional[str] = None
    tool_name: Optional[str] = None
    error: Optional[str] = None

    # 元数据
    metadata: dict = field(default_factory=dict)


class AgentTracer:
    """Agent 追踪器 — 类似 Jaeger/Zipkin"""

    def __init__(self):
        self.traces = {}  # trace_id → [spans]

    def start_trace(self, user_input: str, session_id: str) -> str:
        """开始一次追踪"""
        trace_id = str(uuid.uuid4())[:8]

        root_span = Span(
            span_id=f"{trace_id}-root",
            parent_id=None,
            name="agent_request",
            start_time=time.time(),
            input=user_input,
            metadata={"session_id": session_id}
        )

        self.traces[trace_id] = [root_span]
        return trace_id

    def start_span(self, trace_id: str, name: str,
                   parent_span_id: str = None) -> Span:
        """开始一个子 Span"""
        span = Span(
            span_id=f"{trace_id}-{name}-{len(self.traces[trace_id])}",
            parent_id=parent_span_id,
            name=name,
            start_time=time.time()
        )
        self.traces[trace_id].append(span)
        return span

    def end_span(self, span: Span, output: str = None,
                 error: str = None, tokens: int = 0):
        """结束 Span"""
        span.end_time = time.time()
        span.output = output
        span.error = error
        if tokens:
            span.prompt_tokens = tokens

    def finish_trace(self, trace_id: str) -> dict:
        """完成追踪，返回汇总"""
        spans = self.traces.get(trace_id, [])
        root = spans[0] if spans else None

        if not root:
            return {}

        total_time = sum(
            (s.end_time - s.start_time)
            for s in spans if s.end_time
        )
        total_tokens = sum(s.prompt_tokens for s in spans)
        total_errors = sum(1 for s in spans if s.error)

        return {
            "trace_id": trace_id,
            "total_time_ms": total_time * 1000,
            "total_tokens": total_tokens,
            "span_count": len(spans),
            "errors": total_errors,
            "spans": [self._span_to_dict(s) for s in spans]
        }

    def _span_to_dict(self, span: Span) -> dict:
        return {
            "id": span.span_id,
            "name": span.name,
            "duration_ms": (span.end_time - span.start_time) * 1000 if span.end_time else None,
            "model": span.model,
            "tokens": span.prompt_tokens,
            "tool": span.tool_name,
            "error": span.error,
        }
```

### 2.2 在 Agent 中集成追踪

```python
class TraceableAgent:
    """带追踪的 Agent"""

    def __init__(self):
        self.tracer = AgentTracer()

    def run(self, user_input: str, session_id: str) -> str:
        trace_id = self.tracer.start_trace(user_input, session_id)

        try:
            for step in range(max_steps):
                # LLM 调用 Span
                llm_span = self.tracer.start_span(trace_id, "llm_call")
                try:
                    response = self.llm_call()
                    self.tracer.end_span(llm_span, output="success",
                                        tokens=response.usage.total_tokens)
                except Exception as e:
                    self.tracer.end_span(llm_span, error=str(e))
                    raise

                # 工具调用 Span
                for tool in response.tool_calls:
                    tool_span = self.tracer.start_span(trace_id, f"tool.{tool.name}")
                    try:
                        result = self.execute_tool(tool)
                        self.tracer.end_span(tool_span, output=json.dumps(result)[:200])
                    except Exception as e:
                        self.tracer.end_span(tool_span, error=str(e))

            return final_response

        finally:
            summary = self.tracer.finish_trace(trace_id)
            # 异步上报到追踪系统
            self._report_to_backend(summary)

    def _report_to_backend(self, summary: dict):
        """上报到追踪后端（Jaeger / Datadog / 自建）"""
        # 生产环境: opentelemetry + jaeger
        pass
```

## 3. 指标 (Metrics)

```python
class AgentMetrics:
    """Agent 指标体系"""

    def __init__(self):
        self.counters = {}
        self.histograms = {}
        self.gauges = {}

    def increment(self, name: str, value: int = 1, tags: dict = None):
        """计数器 +1"""
        key = self._key(name, tags)
        self.counters[key] = self.counters.get(key, 0) + value

    def record_latency(self, name: str, latency_ms: float, tags: dict = None):
        """记录延迟"""
        key = self._key(name, tags)
        if key not in self.histograms:
            self.histograms[key] = []
        self.histograms[key].append(latency_ms)

    def set_gauge(self, name: str, value: float, tags: dict = None):
        """设置瞬时值"""
        key = self._key(name, tags)
        self.gauges[key] = value

    def _key(self, name: str, tags: dict = None) -> str:
        if not tags:
            return name
        tag_str = ",".join(f"{k}={v}" for k, v in sorted(tags.items()))
        return f"{name}{{{tag_str}}}"


# ===== 关键指标定义 =====

# LLM 指标
LLM_METRICS = [
    "llm.call.count",           # 总调用次数
    "llm.call.latency",         # 调用延迟
    "llm.call.tokens_input",    # 输入 Token 数
    "llm.call.tokens_output",   # 输出 Token 数
    "llm.call.cost",            # 调用成本
    "llm.call.error_rate",      # 错误率
]

# Agent 指标
AGENT_METRICS = [
    "agent.request.count",      # 总请求数
    "agent.request.success",    # 成功数
    "agent.request.failure",    # 失败数
    "agent.steps.avg",          # 平均步骤数
    "agent.steps.max",          # 最大步骤数
    "agent.latency.p50",        # P50 延迟
    "agent.latency.p95",        # P95 延迟
    "agent.latency.p99",        # P99 延迟
]

# 工具指标
TOOL_METRICS = [
    "tool.call.count",          # 工具调用次数
    "tool.call.success_rate",   # 成功率
    "tool.call.latency",        # 延迟
    "tool.call.error_rate",     # 错误率
]

# 业务指标
BUSINESS_METRICS = [
    "business.task_completion_rate",  # 任务完成率
    "business.user_satisfaction",     # 用户满意度
    "business.escalation_rate",       # 人工升级率
    "business.refund_approval_rate",  # 退款审批通过率
]
```

### 指标采集与暴露

```python
# 生产环境用 Prometheus 格式暴露
"""
from prometheus_client import Counter, Histogram, Gauge, generate_latest

llm_call_count = Counter(
    'llm_call_total',
    'Total LLM API calls',
    ['model', 'status']
)

llm_call_latency = Histogram(
    'llm_call_latency_seconds',
    'LLM API call latency',
    ['model'],
    buckets=[0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0]
)

llm_token_usage = Counter(
    'llm_token_usage_total',
    'Total token usage',
    ['model', 'type']  # type: input/output
)

# 在 Agent 中使用
@llm_call_latency.labels(model="claude-sonnet-4-6").time()
def llm_call():
    response = client.messages.create(...)
    llm_call_count.labels(model="...", status="success").inc()
    llm_token_usage.labels(model="...", type="input").inc(input_tokens)
    return response
"""
```

## 4. 日志 (Logging)

### 4.1 结构化日志

```python
import logging
import json
from datetime import datetime

class AgentLogger:
    """Agent 专用日志器"""

    def __init__(self, agent_name: str):
        self.logger = logging.getLogger(f"agent.{agent_name}")

    def log_agent_start(self, trace_id: str, session_id: str, user_input: str):
        self.logger.info(json.dumps({
            "event": "agent.start",
            "trace_id": trace_id,
            "session_id": session_id,
            "user_input": user_input[:200],
            "timestamp": datetime.now().isoformat()
        }, ensure_ascii=False))

    def log_llm_call(self, trace_id: str, step: int, model: str,
                     input_tokens: int, output_tokens: int, latency_ms: float):
        self.logger.info(json.dumps({
            "event": "llm.call",
            "trace_id": trace_id,
            "step": step,
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "latency_ms": latency_ms,
            "cost": self._calculate_cost(model, input_tokens, output_tokens),
        }))

    def log_tool_call(self, trace_id: str, step: int,
                      tool_name: str, tool_input: dict,
                      tool_result: any, latency_ms: float,
                      success: bool):
        """记录工具调用 — 敏感信息要脱敏"""
        # 脱敏处理
        safe_input = self._sanitize(tool_input)

        self.logger.info(json.dumps({
            "event": "tool.call",
            "trace_id": trace_id,
            "step": step,
            "tool": tool_name,
            "input": safe_input,
            "result_summary": str(tool_result)[:200],
            "latency_ms": latency_ms,
            "success": success,
        }, ensure_ascii=False))

    def log_agent_end(self, trace_id: str, success: bool,
                      total_steps: int, total_tokens: int,
                      total_cost: float, total_time_ms: float,
                      error: str = None):
        self.logger.info(json.dumps({
            "event": "agent.end",
            "trace_id": trace_id,
            "success": success,
            "steps": total_steps,
            "tokens": total_tokens,
            "cost": total_cost,
            "duration_ms": total_time_ms,
            "error": error,
        }, ensure_ascii=False))

    def log_security_event(self, trace_id: str, event_type: str,
                           details: dict, severity: str = "warning"):
        getattr(self.logger, severity)(
            json.dumps({
                "event": f"security.{event_type}",
                "trace_id": trace_id,
                "severity": severity,
                "details": details,
            }, ensure_ascii=False)
        )

    def _calculate_cost(self, model: str, input_tokens: int, output_tokens: int) -> float:
        PRICES = {
            "claude-haiku-4-5": (0.001, 0.005),
            "claude-sonnet-4-6": (0.003, 0.015),
            "claude-opus-4-8": (0.015, 0.075),
        }
        ip, op = PRICES.get(model, (0.003, 0.015))
        return (input_tokens * ip + output_tokens * op) / 1000

    def _sanitize(self, data: dict) -> dict:
        """脱敏：移除 PII"""
        import copy
        safe = copy.deepcopy(data)
        sensitive_keys = ["password", "token", "secret", "api_key", "ssn", "phone"]
        for key in safe:
            if any(sk in key.lower() for sk in sensitive_keys):
                safe[key] = "***REDACTED***"
        return safe
```

## 5. 可观测性架构

```
┌──────────────────────────────────────────────────────────┐
│                     Agent 应用                             │
│                                                           │
│  ┌─────────────┐  ┌────────────┐  ┌───────────────────┐  │
│  │   追踪       │  │   指标      │  │   日志             │  │
│  │ OpenTelemetry│  │ Prometheus │  │ 结构化JSON         │  │
│  └──────┬──────┘  └─────┬──────┘  └────────┬──────────┘  │
│         │               │                  │              │
└─────────┼───────────────┼──────────────────┼──────────────┘
          │               │                  │
          v               v                  v
    ┌──────────┐   ┌───────────┐    ┌──────────────┐
    │  Jaeger  │   │Prometheus │    │ Elasticsearch │
    │  追踪系统 │   │  指标收集  │    │   日志分析    │
    └────┬─────┘   └─────┬─────┘    └──────┬───────┘
         │               │                  │
         └───────────────┼──────────────────┘
                         v
                 ┌──────────────┐
                 │    Grafana    │
                 │  统一仪表盘   │
                 └──────────────┘
```

## 6. 告警规则

```python
ALERTING_RULES = {
    "high_error_rate": {
        "metric": "agent.request.error_rate",
        "threshold": "> 0.05",  # 5%
        "window": "5m",
        "severity": "critical",
        "message": "Agent 错误率超过 5%",
    },
    "high_latency": {
        "metric": "agent.latency.p95",
        "threshold": "> 10000",  # 10s
        "window": "5m",
        "severity": "warning",
        "message": "Agent P95 延迟超过 10s",
    },
    "cost_spike": {
        "metric": "agent.cost.per_hour",
        "threshold": "> 50",  # $50/h
        "window": "1h",
        "severity": "critical",
        "message": "Agent 每小时成本超过 $50",
    },
    "safety_violations": {
        "metric": "security.violation.count",
        "threshold": "> 0",
        "window": "1m",
        "severity": "critical",
        "message": "检测到安全违规",
    },
    "circuit_breaker_open": {
        "metric": "agent.circuit_breaker.state",
        "threshold": "== open",
        "window": "1m",
        "severity": "critical",
        "message": "Agent 熔断器已打开",
    }
}
```

## 7. 总结

```
LLM 可观测性三大支柱:

1. 追踪 (Tracing)
   每个请求的完整生命周期
   LLM调用 → 工具执行 → 工具结果 → LLM分析 → 最终输出

2. 指标 (Metrics)
   RED 方法: Rate(速率) + Errors(错误) + Duration(延迟)
   额外: Token消耗、成本、安全事件

3. 日志 (Logging)
   结构化 JSON，方便检索和分析
   安全事件单独标记和告警

关键原则:
  - 所有 LLM 调用都必须记录成本和 Token
  - 安全事件必须实时告警
  - 用户输入要脱敏后再记录

Java 类比:
  Tracing  = Spring Cloud Sleuth / Micrometer Tracing
  Metrics  = Micrometer + Prometheus
  Logging  = Logback + ELK
  Alerting = Prometheus AlertManager
```
