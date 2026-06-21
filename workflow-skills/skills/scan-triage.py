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

# === SonarQube Web API ===

def fetch_from_sonarqube(sonar_url: str, project_key: str, token: str = None, harness: Harness = None) -> list:
    """直接调 SonarQube Web API 拉取issues

    用法:
      fetch_from_sonarqube(
          sonar_url="https://sonarqube.company.com",
          project_key="com.company:order-service",
          token=os.environ["SONAR_TOKEN"]   # 或传空，用环境变量
      )
    """
    issues = []
    if not token:
        token = os.environ.get("SONAR_TOKEN", "")

    api_url = f"{sonar_url.rstrip('/')}/api/issues/search"
    params = f"projectKeys={project_key}&severities=BLOCKER,CRITICAL,MAJOR,MINOR&ps=500"

    full_url = f"{api_url}?{params}"
    req = Request(full_url)
    if token:
        import base64
        auth = base64.b64encode(f"{token}:".encode()).decode()
        req.add_header("Authorization", f"Basic {auth}")

    if harness:
        harness.audit_info("sonar_api_call", f"url={sonar_url} project={project_key}")

    try:
        with urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        if harness:
            harness.audit_error("sonar_api_failed", str(e)[:200])
        print(f"[ERROR] SonarQube API 请求失败: {e}", file=sys.stderr)
        print(f"[INFO] 检查: 1) SONAR_TOKEN 是否设置 2) {sonar_url} 是否可访问 3) projectKey 是否正确", file=sys.stderr)
        return issues

    for item in data.get("issues", []):
        severity = item.get("severity", "MAJOR").lower()
        issues.append(ScanIssue(
            source="sonar",
            rule_id=item.get("rule", "unknown"),
            severity=severity,
            category=_classify_sonar(item.get("type", "CODE_SMELL")),
            file_path=_extract_path(item),
            line=_extract_line(item),
            message=item.get("message", ""),
            effort=_estimate_effort(severity, _classify_sonar(item.get("type", "")), item.get("message", "")),
            auto_fixable=_is_auto_fixable(item.get("rule", ""), item.get("message", "")),
            risk_score=_risk_score(severity, _classify_sonar(item.get("type", "")))
        ))

    if harness:
        harness.audit_info("sonar_api_result", f"project={project_key} issues={len(issues)}")
    return issues


def trigger_local_scan(module: str = None, harness: Harness = None) -> str:
    """本地触发 mvn sonar:sonar，返回 projectKey

    前提: pom.xml 中已配置 <sonar.host.url> 和 <sonar.projectKey>
    """
    cmd = "mvn sonar:sonar"
    if module:
        cmd += f" -pl {module} -am"
    cmd += " -Dsonar.scm.disabled=true"  # 跳过 SCM blame，加速

    if harness:
        harness.audit_info("local_scan_trigger", f"cmd={cmd}")

    import subprocess
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=600)

    # 从输出提取 projectKey
    match = re.search(r"projectKey[=:]\s*([\w.:-]+)", result.stdout + result.stderr)
    if match:
        return match.group(1)

    # 从 pom.xml 读取
    try:
        pom = Path("pom.xml").read_text()
        match = re.search(r"<sonar\.projectKey>([^<]+)", pom)
        if match:
            return match.group(1)
    except:
        pass

    # 默认从 pom.xml 推断
    try:
        import xml.etree.ElementTree as ET
        root = ET.parse("pom.xml").getroot()
        ns = {"m": "http://maven.apache.org/POM/4.0.0"}
        gid = root.findtext("m:groupId", "", ns) or root.findtext("groupId", "")
        aid = root.findtext("m:artifactId", "", ns) or root.findtext("artifactId", "")
        if gid and aid:
            return f"{gid}:{aid}"
    except:
        pass

    return ""


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
# NexusIQ / Cyberflow 修复策略
# ============================================================

# NexusIQ CVE → 最小安全版本映射 (示例，生产环境应该从 NexusIQ API 获取)
NEXUS_FIX_VERSIONS = {
    # "groupId:artifactId": {"vulnerable": "<X.X", "fix": "X.X.X", "cve": "CVE-XXXX"}
}

def suggest_nexus_upgrade(issue: ScanIssue, pom_path: str = "pom.xml") -> dict:
    """分析 NexusIQ 依赖漏洞，给出升级建议

    NexusIQ 问题通常是第三方库的 CVE 漏洞，修复方式是升级版本。
    这个函数读取 pom.xml，找到对应的依赖，给出建议版本。
    """
    component = issue.file_path.split("(")[0].strip() if "(" in issue.file_path else issue.file_path
    suggestion = {
        "issue": issue.message[:200],
        "action": "manual_review",
        "reason": "需要在 pom.xml 中升级依赖版本，请确认兼容性",
        "component": component,
        "current_version": "?",
        "suggested_version": "请查看 NexusIQ 报告中的 'Recommended Version'",
        "risk": "升级可能导致 API 不兼容，建议在测试环境验证后再上线"
    }

    # 尝试从 pom.xml 找到当前版本
    try:
        pom_content = Path(pom_path).read_text() if Path(pom_path).exists() else ""
        # 解析 groupId:artifactId 格式
        if ":" in component:
            gid, aid = component.split(":")[:2]
            # 从 pom.xml 查找版本
            import xml.etree.ElementTree as ET
            root = ET.parse(pom_path).getroot()
            ns = {"m": "http://maven.apache.org/POM/4.0.0"}
            for dep in root.findall(".//m:dependency", ns):
                d_gid = dep.findtext("m:groupId", "", ns)
                d_aid = dep.findtext("m:artifactId", "", ns)
                if d_gid == gid and d_aid == aid:
                    ver = dep.findtext("m:version", "", ns)
                    if ver:
                        suggestion["current_version"] = ver
                        suggestion["action"] = "upgrade_version"
                        suggestion["pom_line"] = f"<version>{ver}</version> → 升级到安全版本"
    except:
        pass

    return suggestion


def suggest_cyberflow_fix(issue: ScanIssue) -> dict:
    """分析 Cyberflow SAST 安全问题，给出修复指导

    SAST 问题不能自动修复（涉及安全逻辑判断），但可以给出详细的修复方向和代码示例
    """
    msg_lower = issue.message.lower()

    suggestions = {
        "sql_injection": {
            "pattern": "sql injection|prepare statement|parameterize",
            "fix": "使用 PreparedStatement 或 MyBatis #{} 而非 ${}",
            "code": "// ❌ Statement stmt = conn.createStatement(); stmt.executeQuery(\"SELECT * FROM users WHERE id=\" + userId);\n// ✅ PreparedStatement ps = conn.prepareStatement(\"SELECT * FROM users WHERE id=?\"); ps.setInt(1, userId);",
            "effort": "easy"
        },
        "xss": {
            "pattern": "xss|cross.site",
            "fix": "对用户输入做 HTML 转义，使用 OWASP Encoder 或 Spring HtmlUtils",
            "code": "// ❌ return \"<div>\" + userInput + \"</div>\";\n// ✅ return \"<div>\" + HtmlUtils.htmlEscape(userInput) + \"</div>\";",
            "effort": "easy"
        },
        "hardcoded_credentials": {
            "pattern": "hardcoded|password|secret|api.key|credential",
            "fix": "从环境变量或配置中心读取敏感信息，不要硬编码",
            "code": "// ❌ String apiKey = \"sk-xxxxxxxxxxxx\";\n// ✅ String apiKey = System.getenv(\"API_KEY\");",
            "effort": "easy"
        },
        "insecure_deserialization": {
            "pattern": "deserial|objectinputstream|readobject",
            "fix": "使用 Jackson ObjectMapper 并启用安全配置，或使用白名单校验",
            "code": "// ❌ new ObjectInputStream(input).readObject();\n// ✅ objectMapper.enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);",
            "effort": "medium"
        },
        "path_traversal": {
            "pattern": "path.traversal|directory.traversal|file.separator",
            "fix": "校验用户输入的文件路径，使用 getCanonicalPath() 验证路径在允许范围内",
            "code": "// ❌ new FileInputStream(userProvidedPath);\n// ✅ File file = new File(baseDir, userPath).getCanonicalFile();\n//    if (!file.getPath().startsWith(baseDir.getCanonicalPath())) throw new SecurityException();",
            "effort": "medium"
        },
        "command_injection": {
            "pattern": "command.injection|runtime.exec|processbuilder",
            "fix": "避免用用户输入拼接命令，使用 ProcessBuilder 传参数列表（非字符串）",
            "code": "// ❌ Runtime.getRuntime().exec(\"ls \" + userInput);\n// ✅ new ProcessBuilder(\"ls\", userInput).start();  // 但最好完全避免用用户输入调用系统命令",
            "effort": "hard"
        },
    }

    for vuln_type, info in suggestions.items():
        if re.search(info["pattern"], msg_lower):
            return {
                "vuln_type": vuln_type,
                "action": "manual_fix_required",
                "fix_description": info["fix"],
                "code_example": info["code"],
                "effort": info["effort"],
                "warning": "安全修复需要人工确认，自动修改可能引入新漏洞"
            }

    return {
        "action": "manual_review",
        "reason": "未知漏洞类型，请参考 Cyberflow 报告详情",
        "warning": "安全修复需要安全工程师审查"
    }


def suggest_container_fix(issue: ScanIssue) -> dict:
    """分析 Cyberflow Container 漏洞，给出 Dockerfile 修复建议

    容器扫描问题通常是基础镜像或系统包有已知 CVE
    """
    msg_lower = issue.message.lower()
    cve = issue.rule_id if issue.rule_id.startswith("CVE") else ""

    suggestion = {
        "action": "manual_review",
        "cve": cve,
        "component": issue.file_path,
        "detail": issue.message[:200]
    }

    # 容器漏洞修复策略
    if "base image" in msg_lower or "docker" in msg_lower:
        suggestion["action"] = "upgrade_base_image"
        suggestion["fix"] = "升级 Dockerfile 中的 FROM 基础镜像版本"
        suggestion["code"] = "# FROM openjdk:8-jre-alpine  ← 可能包含已知漏洞\n# FROM openjdk:8u332-jre-alpine  ← 升级到安全版本"

    elif any(kw in msg_lower for kw in ["openssl", "libssl", "curl", "wget"]):
        suggestion["action"] = "update_system_package"
        suggestion["fix"] = "在 Dockerfile 中加入 RUN apt-get update && apt-get upgrade -y"
        suggestion["code"] = "RUN apt-get update && apt-get upgrade -y openssl libssl-dev"

    elif any(kw in msg_lower for kw in ["python", "pip", "pypi"]):
        suggestion["action"] = "upgrade_pip_package"
        suggestion["fix"] = "升级 requirements.txt 或 Pipfile 中的 Python 包版本"

    elif "npm" in msg_lower or "node" in msg_lower:
        suggestion["action"] = "npm_audit_fix"
        suggestion["fix"] = "运行 npm audit fix 或在 package.json 中升级版本"

    suggestion["warning"] = "升级基础镜像或系统包可能影响应用行为，请在测试环境验证"

    return suggestion


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

def auto_fix_issues(issues: list, dry_run: bool = True, harness: Harness = None) -> dict:
    """对所有可修复问题进行修复，按来源分类处理

    返回: {"fixed": [...], "suggestions": [...], "cannot_fix": [...]}
    """
    result = {"fixed": [], "suggestions": [], "cannot_fix": []}

    for issue in issues:
        # === Sonar: 直接改源码 ===
        if issue.source == "sonar" and issue.auto_fixable:
            fix = _apply_sonar_fix(issue, dry_run, harness)
            if fix:
                result["fixed"].append(fix)
            continue

        # === NexusIQ: 版本升级建议（不自动改 pom.xml） ===
        if issue.source == "nexusiq":
            sug = suggest_nexus_upgrade(issue)
            sug["dry_run"] = dry_run
            if sug["action"] == "upgrade_version":
                # 自动修改 pom.xml 版本（谨慎：只在 dry_run 模式下预览）
                pom_fix = _apply_nexus_fix(issue, sug, dry_run, harness)
                if pom_fix:
                    result["fixed"].append(pom_fix)
                else:
                    result["suggestions"].append(sug)
            else:
                result["suggestions"].append(sug)
            continue

        # === Cyberflow SAST: 给出修复指导，不自动改 ===
        if issue.source == "cyberflow-sast":
            sug = suggest_cyberflow_fix(issue)
            sug["file"] = issue.file_path
            sug["line"] = issue.line
            result["cannot_fix"].append(sug)
            continue

        # === Cyberflow Container: 给出 Dockerfile 修改建议 ===
        if issue.source == "cyberflow-container":
            sug = suggest_container_fix(issue)
            sug["dry_run"] = dry_run
            if sug["action"] in ("upgrade_base_image", "update_system_package"):
                result["suggestions"].append(sug)
            else:
                result["cannot_fix"].append(sug)
            continue

        # 其他未知来源
        result["cannot_fix"].append({
            "source": issue.source,
            "message": issue.message[:200],
            "reason": "未知问题来源，无法自动修复"
        })

    return result


def _apply_sonar_fix(issue, dry_run: bool, harness) -> str:
    """Sonar 自动修复"""
    filepath = issue.file_path.split(":")[0] if ":" in issue.file_path else issue.file_path
    if not os.path.exists(filepath):
        return ""

    # 安全检查
    scan = security_scan(filepath)
    if harness and scan["action"] == "block":
        harness.audit_warn("auto_fix_blocked", f"file={filepath} reason=security")
        return ""

    try:
        if issue.rule_id == "java:S1128":
            return _fix_unused_import(issue, dry_run)
        elif issue.rule_id == "java:S106":
            return _fix_system_out(issue, dry_run)
        elif issue.rule_id == "java:S1118":
            return _fix_utility_class(issue, dry_run)
    except Exception as e:
        if harness:
            harness.audit_error("sonar_fix_failed", f"rule={issue.rule_id} error={str(e)[:100]}")
    return ""


def _apply_nexus_fix(issue, suggestion: dict, dry_run: bool, harness) -> str:
    """NexusIQ 修复: 升级 pom.xml 中依赖版本（仅在 dry_run 模式下预览）"""
    if not dry_run:
        return ""  # 从不自动修改 pom.xml，只给出建议

    component = suggestion.get("component", "")
    suggested_ver = suggestion.get("suggested_version", "?")
    current_ver = suggestion.get("current_version", "?")
    return f"[NexusIQ PREVIEW] {component}: {current_ver} → {suggested_ver} (需手动操作: sed -i 's/{current_ver}/{suggested_ver}/' pom.xml)"


def _fix_unused_import(issue, dry_run): ...
def _fix_system_out(issue, dry_run): ...
def _fix_utility_class(issue, dry_run): ...
# (实现同之前，略)

# ============================================================
# CLI
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="扫描报告智能分类 + AI 修复建议")
    parser.add_argument("--sonar", type=str, help="SonarQube JSON 报告文件路径")
    parser.add_argument("--sonar-url", type=str, help="SonarQube 服务器 URL (如 https://sonarqube.company.com)")
    parser.add_argument("--sonar-project-key", type=str, help="SonarQube projectKey (如 com.company:order-service)")
    parser.add_argument("--sonar-token", type=str, help="SonarQube API Token (默认读环境变量 SONAR_TOKEN)")
    parser.add_argument("--trigger-scan", action="store_true", help="本地触发 mvn sonar:sonar，然后从 API 拉取报告")
    parser.add_argument("--module", type=str, default=None, help="指定 Maven 模块（用于 --trigger-scan）")
    parser.add_argument("--nexusiq", type=str)
    parser.add_argument("--cyberflow-sast", type=str); parser.add_argument("--cyberflow-container", type=str)
    parser.add_argument("--jenkins-url", type=str); parser.add_argument("--jenkins-job", type=str, default=None)
    parser.add_argument("--jenkins-build", type=str, default="lastBuild")
    parser.add_argument("--auto-fix", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    harness = Harness("scan-triage")
    all_issues = []

    # === 解析报告（多数据源） ===

    # 数据源 1: 本地触发扫描 → 从 SonarQube API 拉取 (最常用)
    if args.trigger_scan:
        print("[STEP] 本地触发 mvn sonar:sonar...", file=sys.stderr)
        project_key = trigger_local_scan(args.module, harness)
        if project_key and args.sonar_url:
            print(f"[STEP] 从 SonarQube 拉取: {args.sonar_url} | {project_key}", file=sys.stderr)
            all_issues.extend(fetch_from_sonarqube(args.sonar_url, project_key, args.sonar_token, harness))
        elif project_key:
            print(f"[WARN] 扫描完成，但未指定 --sonar-url，无法拉取报告", file=sys.stderr)
            print(f"[INFO] projectKey: {project_key}", file=sys.stderr)
            print(f"[INFO] 请加参数: --sonar-url https://your-sonar.company.com --sonar-project-key {project_key}", file=sys.stderr)

    # 数据源 2: SonarQube Web API (直接拉取)
    if args.sonar_url and args.sonar_project_key:
        all_issues.extend(fetch_from_sonarqube(args.sonar_url, args.sonar_project_key, args.sonar_token, harness))

    # 数据源 3: 本地 Sonar JSON 报告文件
    if args.sonar and os.path.exists(args.sonar):
        all_issues.extend(parse_sonar_report(args.sonar, harness))

    # 数据源 4: Cyberflow SAST
    if args.cyberflow_sast and os.path.exists(args.cyberflow_sast):
        all_issues.extend(parse_cyberflow_sast(args.cyberflow_sast, harness))

    # 数据源 5: Cyberflow Container
    if args.cyberflow_container and os.path.exists(args.cyberflow_container):
        all_issues.extend(parse_cyberflow_container(args.cyberflow_container, harness))

    # 数据源 6: Jenkins 构建日志
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
        print("\n🤖 自动修复中...\n")
        fix_result = auto_fix_issues(all_issues, dry_run=args.dry_run, harness=harness)

        # Sonar: 已修复
        if fix_result["fixed"]:
            print(f"✅ Sonar 自动修复 ({len(fix_result['fixed'])} 项):")
            for f in fix_result["fixed"][:10]:
                print(f"   {f}")

        # NexusIQ / Container: 升级建议
        if fix_result["suggestions"]:
            print(f"\n💡 升级建议 (需手动操作, {len(fix_result['suggestions'])} 项):")
            for s in fix_result["suggestions"][:10]:
                action = s.get("action", "?").replace("_", " ")
                comp = s.get("component", s.get("file", s.get("cve", "?")))
                warning = s.get("warning", s.get("reason", ""))
                print(f"   [{action}] {comp}")
                if warning:
                    print(f"          ⚠️  {warning}")

        # Cyberflow SAST: 不能自动修
        if fix_result["cannot_fix"]:
            print(f"\n🔒 需人工安全审查 ({len(fix_result['cannot_fix'])} 项):")
            for s in fix_result["cannot_fix"][:10]:
                vtype = s.get("vuln_type", "unknown")
                fix_desc = s.get("fix_description", s.get("reason", ""))
                print(f"   [{vtype}] {fix_desc[:120]}")

    blocker_count = report.by_severity.get("blocker", 0)
    result = "fail" if blocker_count > 0 else "pass"
    harness.finish(result)
    sys.exit(0 if result == "pass" else 1)

if __name__ == "__main__":
    main()
