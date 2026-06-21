#!/usr/bin/env python3
"""
harness-utils.py — 共享基础设施库 (Python)

提供:
  1. 安全护栏: 输入校验、危险操作检测、PII 脱敏
  2. 失败处理: 错误分类、优雅降级、结构化输出
  3. 弹性模式: 指数退避重试、熔断器、超时控制
  4. 可观测性: trace_id、审计日志、指标收集

用法:
  from harness_utils import Harness, retry, CircuitBreaker
"""

import functools
import hashlib
import json
import os
import random
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional


# ============================================================
# 第 1 部分: 可观测性基础设施
# ============================================================

class Harness:
    """Harness 基础设施 — 每个 Skill 一个实例"""

    def __init__(self, skill_name: str, trace_id: str = None):
        self.skill_name = skill_name
        self.trace_id = trace_id or f"{int(time.time())}_{os.getpid()}_{random.randint(0,9999)}"
        self.start_time = int(time.time() * 1000)

        # 目录
        self.audit_dir = Path.home() / ".claude" / "skill-audit"
        self.metrics_dir = Path.home() / ".claude" / "skill-metrics"
        self.circuit_dir = Path.home() / ".claude" / "skill-circuit"
        self.audit_dir.mkdir(parents=True, exist_ok=True)
        self.metrics_dir.mkdir(parents=True, exist_ok=True)
        self.circuit_dir.mkdir(parents=True, exist_ok=True)

        self._audit("INFO", "skill_start", f"trace_id={self.trace_id}")
        print(f"\033[36m[HARNESS]\033[0m {skill_name} — trace: {self.trace_id[:12]}")

    # ---- 审计日志 ----
    def _audit(self, level: str, event: str, detail: str = ""):
        entry = json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
            "trace_id": self.trace_id,
            "skill": self.skill_name,
            "level": level,
            "event": event,
            "detail": self._sanitize_pii(detail)[:500]
        }, ensure_ascii=False)
        with open(self.audit_dir / "audit.jsonl", "a") as f:
            f.write(entry + "\n")

    def audit_info(self, event: str, detail: str = ""):
        self._audit("INFO", event, detail)

    def audit_warn(self, event: str, detail: str = ""):
        self._audit("WARN", event, detail)

    def audit_error(self, event: str, detail: str = ""):
        self._audit("ERROR", event, detail)

    # ---- 指标 ----
    def metric_incr(self, name: str, value: int = 1):
        file = self.metrics_dir / f"{self.skill_name}_{name}.count"
        current = 0
        if file.exists():
            current = int(file.read_text().strip() or "0")
        file.write_text(str(current + value))

    def metric_latency(self, name: str, ms: int):
        file = self.metrics_dir / f"{self.skill_name}_{name}.latency"
        with open(file, "a") as f:
            f.write(f"{ms}\n")

    def metric_last(self, name: str) -> int:
        file = self.metrics_dir / f"{self.skill_name}_{name}.count"
        return int(file.read_text().strip()) if file.exists() else 0

    # ---- 输出 ----
    def output(self, result: str, checks: list, suggestions: list = None) -> str:
        elapsed = int(time.time() * 1000) - self.start_time
        total_checks = len(checks)
        passed_checks = sum(1 for c in checks if c.get("passed", False))

        self.metric_incr("total_runs")
        self.metric_latency("total_duration", elapsed)

        if result == "pass":
            self.metric_incr("successful_runs")
            self.audit_info("skill_complete", f"result=pass checks={passed_checks}/{total_checks}")
        elif result == "degraded":
            self.metric_incr("degraded_runs")
            self.audit_warn("skill_degraded", f"result=degraded checks={passed_checks}/{total_checks}")
        else:
            self.metric_incr("failed_runs")
            self.audit_error("skill_failed", f"result=fail checks={passed_checks}/{total_checks}")

        total = self.metric_last("total_runs")
        success = self.metric_last("successful_runs")
        success_rate = f"{success * 100 // total}%" if total > 0 else "N/A"

        output = {
            "skill": self.skill_name,
            "trace_id": self.trace_id,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "result": result,
            "checks": checks,
            "suggestions": suggestions or [],
            "duration_ms": elapsed,
            "metrics": {"total_runs": total, "success_rate": success_rate}
        }
        return json.dumps(output, ensure_ascii=False, indent=2)

    def finish(self, result: str):
        elapsed = int(time.time() * 1000) - self.start_time
        self.audit_info("skill_finish", f"result={result} duration_ms={elapsed}")
        self.metric_latency("total_duration", elapsed)

        total = self.metric_last("total_runs")
        success = self.metric_last("successful_runs")
        success_rate = f"{success * 100 // total}%" if total > 0 else "N/A"

        print(f"\033[36m──────────────────────────────────────\033[0m")
        print(f"\033[36m[HARNESS]\033[0m 结果: {result} | 耗时: {elapsed}ms | 成功率: {success_rate}")
        print(f"\033[36m[HARNESS]\033[0m 审计: {self.audit_dir}/audit.jsonl")
        print(f"\033[36m[HARNESS]\033[0m 指标: {self.metrics_dir}/")

    # ---- PII 脱敏 ----
    @staticmethod
    def _sanitize_pii(text: str) -> str:
        text = re.sub(r'1[3-9]\d{9}', '***PHONE***', text)
        text = re.sub(r'\d{17}[\dXx]', '***ID***', text)
        text = re.sub(r'sk-[a-zA-Z0-9]{32,}', '***API_KEY***', text)
        text = re.sub(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', '***EMAIL***', text)
        return text


# ============================================================
# 第 2 部分: 安全护栏
# ============================================================

# 危险模式库
DANGEROUS_PATTERNS = [
    (r"rm\s+-rf\s+/", "CRITICAL", "递归删除根目录"),
    (r"rm\s+-rf\s+~", "CRITICAL", "删除用户主目录"),
    (r">\s*/dev/sd[a-z]", "CRITICAL", "写入原始磁盘设备"),
    (r"mkfs\.", "CRITICAL", "格式化文件系统"),
    (r"curl.*\|\s*(ba)?sh", "CRITICAL", "远程脚本直接执行"),
    (r"wget.*\|\s*(ba)?sh", "CRITICAL", "远程脚本直接执行"),
    (r"sudo\s+", "HIGH", "提权操作"),
    (r"chmod\s+777", "HIGH", "过度开放权限"),
    (r"eval\s+", "HIGH", "动态代码执行"),
    (r"(ANTHROPIC_API_KEY|OPENAI_API_KEY|DB_PASSWORD|PRIVATE_KEY)", "CRITICAL", "敏感凭据泄露"),
]

def security_scan(content: str) -> dict:
    """扫描内容中的安全问题"""
    max_risk = 0
    findings = []

    for pattern, severity, desc in DANGEROUS_PATTERNS:
        if re.search(pattern, content, re.IGNORECASE):
            risk = {"CRITICAL": 100, "HIGH": 75, "MEDIUM": 50, "LOW": 25}[severity]
            findings.append({"pattern": pattern, "severity": severity, "description": desc, "risk": risk})
            max_risk = max(max_risk, risk)

    action = "block" if max_risk >= 100 else "warn" if max_risk >= 75 else "allow"
    return {"max_risk": max_risk, "action": action, "findings": findings}

def validate_sql(sql: str) -> dict:
    """校验 SQL 查询安全性"""
    sql_upper = sql.strip().upper()

    if not sql_upper.startswith("SELECT"):
        return {"valid": False, "reason": "仅允许 SELECT 语句"}

    dangerous = ["DROP", "DELETE", "INSERT", "UPDATE", "ALTER", "EXEC", "--", "CREATE", "TRUNCATE"]
    for kw in dangerous:
        if kw in sql_upper.split():
            return {"valid": False, "reason": f"SQL 中包含禁止的操作: {kw}"}

    return {"valid": True}


# ============================================================
# 第 3 部分: 弹性模式
# ============================================================

def retry(max_attempts: int = 3, base_delay: float = 1.0,
          max_delay: float = 30.0, retryable_exceptions: tuple = (Exception,),
          harness: Optional[Harness] = None):
    """指数退避重试装饰器"""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            last_error = None
            for attempt in range(max_attempts):
                try:
                    result = func(*args, **kwargs)
                    if harness:
                        harness.metric_incr("retry_success")
                    return result
                except retryable_exceptions as e:
                    last_error = e
                    error_class = classify_error(str(e))

                    if error_class == "PERMANENT":
                        if harness:
                            harness.audit_error("permanent_error", str(e)[:200])
                        raise

                    if attempt < max_attempts - 1:
                        delay = min(base_delay * (2 ** attempt), max_delay)
                        jitter = random.uniform(-0.3, 0.3) * delay
                        delay = max(0.1, delay + jitter)

                        msg = str(e)[:100]
                        if harness:
                            harness.audit_warn("retry_attempt", f"attempt={attempt+1}/{max_attempts} delay={delay:.1f}s error={msg}")
                        print(f"\033[33m[RETRY {attempt+1}/{max_attempts}]\033[0m {msg} — {delay:.1f}s 后重试...")
                        time.sleep(delay)

            if harness:
                harness.metric_incr("retry_exhausted")
                harness.audit_error("retry_exhausted", f"attempts={max_attempts} error={str(last_error)[:200]}")
            raise last_error
        return wrapper
    return decorator


class CircuitBreaker:
    """熔断器"""

    def __init__(self, name: str, failure_threshold: int = 5, recovery_secs: float = 60.0):
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_secs = recovery_secs
        self.state_file = Path.home() / ".claude" / "skill-circuit" / f"{name}.json"

    def check(self) -> dict:
        """检查熔断器状态"""
        if not self.state_file.exists():
            return {"state": "closed", "allowed": True}

        data = json.loads(self.state_file.read_text())
        state = data.get("state", "closed")
        failures = data.get("failures", 0)
        last_failure = data.get("last_failure", 0)

        if state == "open":
            elapsed = time.time() - last_failure
            if elapsed >= self.recovery_secs:
                return {"state": "half_open", "allowed": True}
            return {"state": "open", "allowed": False, "retry_after": int(self.recovery_secs - elapsed)}

        return {"state": state, "allowed": True, "failures": failures}

    def record_success(self):
        self.state_file.write_text(json.dumps({"state": "closed", "failures": 0, "last_failure": 0}))

    def record_failure(self):
        data = {"state": "closed", "failures": 0, "last_failure": 0}
        if self.state_file.exists():
            data = json.loads(self.state_file.read_text())

        data["failures"] = data.get("failures", 0) + 1
        data["last_failure"] = time.time()

        if data["failures"] >= self.failure_threshold:
            data["state"] = "open"

        self.state_file.write_text(json.dumps(data))


def classify_error(error_msg: str) -> str:
    """分类错误类型"""
    error_lower = error_msg.lower()
    if re.search(r'timeout|timed out|connection refused|temporarily unavailable|too many|rate limit|429|503|502', error_lower):
        return "TRANSIENT"
    if re.search(r'not found|invalid|unauthorized|forbidden|permission denied|404|401|403', error_lower):
        return "PERMANENT"
    if re.search(r'degraded|partial|fallback|skip', error_lower):
        return "DEGRADED"
    return "TRANSIENT"


# ============================================================
# 第 4 部分: 文件操作安全
# ============================================================

def safe_read_file(filepath: str, max_size_mb: int = 10) -> Optional[str]:
    """安全读取文件"""
    path = Path(filepath)
    if not path.exists():
        return None
    if path.stat().st_size > max_size_mb * 1024 * 1024:
        return None
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None

def safe_write_file(filepath: str, content: str, dry_run: bool = True) -> str:
    """安全写入文件（支持干跑）"""
    path = Path(filepath)
    if dry_run:
        return f"[DRY_RUN] 将写入: {path} ({len(content)} 字节)"

    # 备份原文件
    if path.exists():
        backup = path.with_suffix(path.suffix + ".bak")
        path.rename(backup)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return f"[WRITTEN] {path} ({len(content)} 字节)"
