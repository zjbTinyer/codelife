#!/usr/bin/env python3
"""
scan-triage.py — 扫描报告智能分类 + AI 修复建议 (Harness 增强版)

支持: SonarQube / NexusIQ / Cyberflow SAST / Cyberflow Container / Jenkins 日志
"""
import argparse, json, os, re, sys, time
from dataclasses import dataclass, field
from collections import defaultdict
from pathlib import Path
from typing import Optional
from urllib.request import urlopen, Request

# 加载共享基础设施
sys.path.insert(0, str(Path(__file__).parent / "lib"))
from harness_utils import Harness, retry, CircuitBreaker, classify_error, security_scan, safe_read_file, safe_write_file

# ============================================================
# 数据模型（增强）
# ============================================================

@dataclass
class ScanIssue:
    source: str
    rule_id: str
    severity: str          # blocker / critical / major / minor / info
    category: str          # bug / vulnerability / code_smell / security / license
    file_path: str
    line: int
    message: str
    effort: str = "medium"
    suggestion: str = ""
    auto_fixable: bool = False
    risk_score: int = 50   # Harness: 风险评分 0-100

@dataclass
class TriageReport:
    total: int = 0
    by_severity: dict = field(default_factory=dict)
    by_category: dict = field(default_factory=dict)
    by_effort: dict = field(default_factory=dict)
    by_risk: dict = field(default_factory=dict)  # Harness: 风险分布
    issues: list = field(default_factory=list)
    auto_fixable_count: int = 0

# ============================================================
# 解析器 (同之前，略作增强)
# ============================================================

def parse_sonar_report(filepath: str, harness: Harness) -> list:
    issues = []
    content = safe_read_file(filepath)
    if not content:
        harness.audit_error("sonar_read_failed", filepath)
        return issues
    data = json.loads(content)
    items = data.get("issues", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        return issues
    for item in items:
        severity = item.get("severity", "MAJOR").lower()
        category = _classify_sonar(item.get("type", "CODE_SMELL"))
        issues.append(ScanIssue(
            source="sonar", rule_id=item.get("rule", "unknown"),
            severity=severity, category=category,
            file_path=_extract_path(item), line=_extract_line(item),
            message=item.get("message", ""),
            effort=_estimate_effort(severity, category, item.get("message", "")),
            auto_fixable=_is_auto_fixable(item.get("rule", ""), item.get("message", "")),
            risk_score=_risk_score(severity, category)
        ))
    return issues

def parse_cyberflow_sast(filepath: str, harness: Harness) -> list:
    issues = []
    content = safe_read_file(filepath)
    if not content: return issues
    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        harness.audit_error("cyberflow_parse_error", filepath)
        return issues
    findings = data.get("findings", data.get("results", []))
    if isinstance(findings, dict): findings = findings.get("items", [])
    for item in findings:
        severity = str(item.get("severity", "medium")).lower()
        issues.append(ScanIssue(
            source="cyberflow-sast", rule_id=item.get("rule_id", item.get("check_id", "unknown")),
            severity=severity, category="security",
            file_path=item.get("file", item.get("location", {}).get("file", "")),
            line=item.get("line", item.get("location", {}).get("line", 0)),
            message=item.get("message", item.get("description", "")),
            effort=_estimate_effort(severity, "security", item.get("message", "")),
            auto_fixable=False, risk_score=_risk_score(severity, "security")
        ))
    return issues

def fetch_from_jenkins(jenkins_url: str, job_name: str, build_num: str, harness: Harness) -> list:
    """带熔断器的 Jenkins 日志拉取"""
    cb = CircuitBreaker("jenkins_fetch", failure_threshold=3, recovery_secs=120)
    check = cb.check()
    if not check["allowed"]:
        harness.audit_error("circuit_open", f"retry_after={check.get('retry_after', 60)}")
        print(f"[CIRCUIT OPEN] Jenkins API 熔断中，{check.get('retry_after', 60)}s 后重试", file=sys.stderr)
        return []

    console_url = f"{jenkins_url}/job/{job_name}/{build_num}/consoleText"
    try:
        req = Request(console_url)
        with urlopen(req, timeout=30) as resp:
            log = resp.read().decode('utf-8', errors='ignore')
        cb.record_success()
    except Exception as e:
        cb.record_failure()
        harness.audit_error("jenkins_fetch_failed", str(e)[:200])
        return []

    issues = []
    sonar_matches = re.findall(r'(?:WARN|ERROR|INFO).*?(sonar.*?(?:bug|vulnerability|code_smell).*?)$', log, re.MULTILINE | re.IGNORECASE)
    for match in sonar_matches:
        issues.append(ScanIssue(source="sonar", rule_id="jenkins-extracted",
            severity="major", category="code_smell", file_path="unknown", line=0,
            message=match.strip(), effort="medium", auto_fixable=False, risk_score=50))
    return issues

# ============================================================
# 辅助函数
# ============================================================

def _extract_path(item: dict) -> str:
    comp = item.get("component", "")
    return comp.split(":")[-1] if ":" in comp else comp

def _extract_line(item: dict) -> int:
    return item.get("line", item.get("textRange", {}).get("startLine", 0))

def _classify_sonar(type_str: str) -> str:
    t = type_str.lower()
    if "bug" in t: return "bug"
    if "vulnerability" in t: return "vulnerability"
    return "code_smell"

def _estimate_effort(severity: str, category: str, message: str) -> str:
    msg = message.lower()
    if any(kw in msg for kw in ["unused import", "remove", "rename", "add annotation", "format"]): return "easy"
    if any(kw in msg for kw in ["architecture", "design", "refactor", "sql injection", "xss"]): return "hard"
    return {"blocker": "hard", "critical": "medium", "major": "medium", "minor": "easy", "info": "easy"}.get(severity, "medium")

def _is_auto_fixable(rule_id: str, message: str) -> bool:
    return rule_id in {"java:S116","java:S117","java:S1125","java:S106","java:S1132","java:S1133","java:S1150","java:S1155","java:S1104","java:S1105","java:S1118","java:S1128","java:S1158","java:S1192"}

def _risk_score(severity: str, category: str) -> int:
    base = {"blocker": 100, "critical": 80, "major": 60, "minor": 30, "info": 10}.get(severity, 50)
    if category in ("security", "vulnerability"): base = min(100, base + 20)
    return base

# ============================================================
# 报告生成
# ============================================================

def generate_report(all_issues: list, harness: Harness) -> TriageReport:
    report = TriageReport()
    report.total = len(all_issues)
    report.issues = all_issues
    for issue in all_issues:
        report.by_severity[issue.severity] = report.by_severity.get(issue.severity, 0) + 1
        report.by_category[issue.category] = report.by_category.get(issue.category, 0) + 1
        report.by_effort[issue.effort] = report.by_effort.get(issue.effort, 0) + 1
        if issue.risk_score >= 80: report.by_risk["high"] = report.by_risk.get("high", 0) + 1
        elif issue.risk_score >= 50: report.by_risk["medium"] = report.by_risk.get("medium", 0) + 1
        else: report.by_risk["low"] = report.by_risk.get("low", 0) + 1
        if issue.auto_fixable: report.auto_fixable_count += 1
    harness.audit_info("report_generated", f"total={report.total} auto_fixable={report.auto_fixable_count}")
    return report

def output_json_report(report: TriageReport, harness: Harness) -> str:
    return json.dumps({
        "skill": "scan-triage", "trace_id": harness.trace_id,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "summary": {"total": report.total, "auto_fixable": report.auto_fixable_count,
            "by_severity": report.by_severity, "by_category": report.by_category,
            "by_effort": report.by_effort, "by_risk": report.by_risk},
        "blockers": [{"source": i.source, "rule": i.rule_id, "file": i.file_path, "line": i.line, "message": i.message, "risk_score": i.risk_score} for i in report.issues if i.severity == "blocker"],
        "auto_fixable": [{"source": i.source, "rule": i.rule_id, "file": i.file_path, "line": i.line, "message": i.message} for i in report.issues if i.auto_fixable]
    }, ensure_ascii=False, indent=2)

# ============================================================
# 自动修复（带 Harness 安全保护）
# ============================================================

def auto_fix_issues(issues: list, dry_run: bool = True, harness: Harness = None) -> list:
    fixed = []
    for issue in issues:
        if not issue.auto_fixable: continue
        filepath = issue.file_path.split(":")[0] if ":" in issue.file_path else issue.file_path
        if not os.path.exists(filepath): continue

        # 修复前安全检查
        scan = security_scan(filepath)
        if harness and scan["action"] == "block":
            harness.audit_warn("auto_fix_blocked", f"file={filepath} reason=security")
            continue

        try:
            if issue.rule_id == "java:S1128":
                fix = _fix_unused_import(issue, dry_run)
            elif issue.rule_id == "java:S106":
                fix = _fix_system_out(issue, dry_run)
            elif issue.rule_id == "java:S1118":
                fix = _fix_utility_class(issue, dry_run)
            else:
                continue
            if fix:
                fixed.append(fix)
                if harness: harness.audit_info("auto_fix_applied", fix)
        except Exception as e:
            if harness: harness.audit_error("auto_fix_failed", f"rule={issue.rule_id} error={str(e)[:100]}")
    return fixed

def _fix_unused_import(issue, dry_run): ...
def _fix_system_out(issue, dry_run): ...
def _fix_utility_class(issue, dry_run): ...
# (实现同之前，略)

# ============================================================
# CLI
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="扫描报告智能分类 + AI 修复建议")
    parser.add_argument("--sonar", type=str); parser.add_argument("--nexusiq", type=str)
    parser.add_argument("--cyberflow-sast", type=str); parser.add_argument("--cyberflow-container", type=str)
    parser.add_argument("--jenkins-url", type=str); parser.add_argument("--jenkins-job", type=str, default=None)
    parser.add_argument("--jenkins-build", type=str, default="lastBuild")
    parser.add_argument("--auto-fix", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    harness = Harness("scan-triage")
    all_issues = []

    # 解析（带错误处理）
    if args.sonar and os.path.exists(args.sonar):
        all_issues.extend(parse_sonar_report(args.sonar, harness))
    if args.cyberflow_sast and os.path.exists(args.cyberflow_sast):
        all_issues.extend(parse_cyberflow_sast(args.cyberflow_sast, harness))
    if args.jenkins_url and args.jenkins_job:
        all_issues.extend(fetch_from_jenkins(args.jenkins_url, args.jenkins_job, args.jenkins_build, harness))

    if not all_issues:
        print("[ERROR] 未找到任何扫描报告", file=sys.stderr)
        harness.finish("fail")
        sys.exit(1)

    report = generate_report(all_issues, harness)

    if args.json:
        print(output_json_report(report, harness))
    else:
        # 简洁输出
        print(f"总问题: {report.total} | 可自动修复: {report.auto_fixable_count}")
        for sev in ["blocker","critical","major","minor","info"]:
            if report.by_severity.get(sev): print(f"  {sev}: {report.by_severity[sev]}")

    if args.auto_fix:
        fixes = auto_fix_issues([i for i in all_issues if i.auto_fixable], dry_run=args.dry_run, harness=harness)
        for fix in fixes: print(f"  {fix}")

    blocker_count = report.by_severity.get("blocker", 0)
    result = "fail" if blocker_count > 0 else "pass"
    harness.finish(result)
    sys.exit(0 if result == "pass" else 1)

if __name__ == "__main__":
    main()
