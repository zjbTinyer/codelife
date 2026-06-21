#!/usr/bin/env python3
"""
coverage-hunt.py — 覆盖率缺口分析 + 测试生成 (Harness 增强版)
"""
import argparse, csv, json, os, sys, time, xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from collections import defaultdict
from typing import Optional

# 加载共享基础设施
sys.path.insert(0, str(Path(__file__).parent / "lib"))
from harness_utils import Harness, retry, CircuitBreaker, security_scan, safe_read_file, safe_write_file


@dataclass
class UncoveredMethod:
    class_name: str; method_name: str
    line_missed: int; branch_missed: int
    complexity: int = 0; priority: str = "medium"; source_file: Optional[str] = None

@dataclass
class CoverageReport:
    line_coverage: float = 0.0; branch_coverage: float = 0.0
    total_lines: int = 0; covered_lines: int = 0
    uncovered_methods: list = field(default_factory=list)
    packages: dict = field(default_factory=dict)


def find_jacoco_csv(module: Optional[str] = None) -> Optional[Path]:
    candidates = list(Path(module or ".").rglob("**/jacoco.csv"))
    candidates = [c for c in candidates if "/test/" not in str(c)]
    return candidates[0] if candidates else None

def parse_jacoco_csv(csv_path: Path, harness: Harness) -> CoverageReport:
    report = CoverageReport()
    packages = defaultdict(lambda: {"line_missed": 0, "line_covered": 0, "branch_missed": 0, "branch_covered": 0, "classes": []})
    content = safe_read_file(str(csv_path))
    if not content:
        harness.audit_error("jacoco_read_failed", str(csv_path))
        return report

    reader = csv.DictReader(content.splitlines())
    for row in reader:
        pkg = row.get("PACKAGE", row.get("package", ""))
        cls = row.get("CLASS", row.get("class", ""))
        lm = int(row.get("LINE_MISSED", row.get("INSTRUCTION_MISSED", 0)))
        lc = int(row.get("LINE_COVERED", row.get("INSTRUCTION_COVERED", 0)))
        bm = int(row.get("BRANCH_MISSED", 0)); bc = int(row.get("BRANCH_COVERED", 0))
        report.total_lines += (lm + lc); report.covered_lines += lc
        packages[pkg]["line_missed"] += lm; packages[pkg]["line_covered"] += lc
        packages[pkg]["branch_missed"] += bm; packages[pkg]["branch_covered"] += bc
        packages[pkg]["classes"].append({"name": cls, "line_missed": lm, "line_covered": lc, "coverage": round(lc * 100 / max(lm + lc, 1), 1)})

    if report.total_lines > 0:
        report.line_coverage = round(report.covered_lines * 100 / report.total_lines, 1)
    report.packages = dict(packages)
    return report


def find_uncovered_methods(module: Optional[str] = None) -> list:
    uncovered = []
    xml_files = list(Path(module or ".").rglob("**/jacoco.xml"))
    for xml_path in xml_files:
        try:
            root = ET.parse(xml_path).getroot()
            for pkg in root.findall(".//package"):
                pkg_name = pkg.get("name", "")
                for sf in pkg.findall("sourcefile"):
                    sf_name = sf.get("name", "")
                    for counter in sf.findall("counter"):
                        if counter.get("type") == "METHOD":
                            missed = int(counter.get("missed", 0))
                            if missed > 0:
                                uncovered.append(UncoveredMethod(
                                    class_name=f"{pkg_name}.{sf_name.replace('.java','')}",
                                    method_name=f"{missed} methods uncovered",
                                    line_missed=missed, branch_missed=0,
                                    priority="high" if missed > 5 else "medium"
                                ))
        except ET.ParseError: continue
    return uncovered


def prioritize_methods(methods: list) -> list:
    order = {"controller": 0, "api": 0, "resource": 0, "service": 1, "impl": 1,
             "repository": 2, "dao": 2, "mapper": 2, "config": 3, "util": 4, "helper": 4}
    def key(m): return (next((v for k, v in order.items() if k in m.class_name.lower()), 99), m.line_missed * -1)
    return sorted(methods, key=key)


def generate_test_skeleton(method: UncoveredMethod) -> str:
    parts = method.class_name.split("."); cls = parts[-1]; pkg = ".".join(parts[:-1])
    return f"""package {pkg};

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * {@link {cls}} 单元测试 (覆盖率缺口: {method.line_missed} methods)
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("{cls} 测试")
class {cls}Test {{
    @InjectMocks private {cls} target;

    @Nested @DisplayName("正常场景")
    class NormalCases {{
        @Test @DisplayName("TODO")
        void shouldXxx() {{ fail("未实现"); }}
    }}
    @Nested @DisplayName("边界条件")
    class EdgeCases {{
        @Test @DisplayName("null输入")
        void shouldHandleNull() {{ fail("未实现"); }}
    }}
    @Nested @DisplayName("异常场景")
    class ErrorCases {{
        @Test @DisplayName("依赖异常")
        void shouldHandleDependencyFailure() {{ fail("未实现"); }}
    }}
}}"""


def main():
    parser = argparse.ArgumentParser(description="覆盖率分析 + 测试生成")
    parser.add_argument("target", type=float, nargs="?", default=80)
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--generate-tests", action="store_true")
    parser.add_argument("--module", type=str, default=None)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--output-dir", type=str, default="src/test/java")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    harness = Harness("coverage-hunt")
    start_time = int(time.time() * 1000)

    # 熔断器保护
    cb = CircuitBreaker("coverage_hunt", failure_threshold=5)
    if not cb.check()["allowed"]:
        print("[CIRCUIT OPEN] 覆盖率分析熔断中，请稍后重试", file=sys.stderr)
        harness.finish("blocked"); sys.exit(1)

    # 生成 JaCoCo 报告（如果需要）
    csv_path = find_jacoco_csv(args.module)
    if not csv_path:
        harness.audit_info("jacoco_not_found", "generating report...")
        cmd = f"mvn jacoco:report {' -pl ' + args.module if args.module else ''} -q"
        os.system(f"{cmd} 2>/dev/null")
        csv_path = find_jacoco_csv(args.module)

    if not csv_path:
        print("❌ 无法找到或生成 JaCoCo 报告", file=sys.stderr)
        harness.finish("fail"); sys.exit(1)

    report = parse_jacoco_csv(csv_path, harness)
    methods = find_uncovered_methods(args.module)
    methods = prioritize_methods(methods)
    cb.record_success()

    harness.audit_info("coverage_analyzed", f"line_cov={report.line_coverage}% target={args.target}%")

    # 输出
    if args.json:
        print(json.dumps({
            "skill": "coverage-hunt", "trace_id": harness.trace_id,
            "coverage": {"line": report.line_coverage, "target": args.target, "gap": round(max(0, args.target - report.line_coverage), 1)},
            "top_uncovered": [{"class": m.class_name, "priority": m.priority, "missed": m.line_missed} for m in methods[:args.top]],
            "duration_ms": int(time.time() * 1000) - start_time
        }, ensure_ascii=False, indent=2))
    else:
        print(f"""╔══════════════════════════════════════════╗
║ Coverage Hunt — {report.line_coverage}% (目标 {args.target}%) | gap: {round(max(0, args.target - report.line_coverage), 1)}% ║
║ Trace: {harness.trace_id[:12]}                  ║
╚══════════════════════════════════════════╝
Top {args.top} 未覆盖类:""")
        for i, m in enumerate(methods[:args.top], 1):
            flag = "🔴" if m.priority == "high" else "🟡"
            print(f"  {i}. {flag} {m.class_name} ({m.line_missed} methods)")

    # 生成测试骨架
    if args.generate_tests:
        base = Path(args.output_dir)
        if args.module: base = Path(args.module) / base
        generated = 0
        for m in methods[:args.top]:
            if m.priority != "high": continue
            test_dir = base / "/".join(m.class_name.replace(".", "/").split("/")[:-1])
            test_dir.mkdir(parents=True, exist_ok=True)
            test_file = test_dir / f"{m.class_name.split('.')[-1]}Test.java"
            if test_file.exists():
                print(f"  ⏭️ 跳过: {test_file}"); continue
            result = safe_write_file(str(test_file), generate_test_skeleton(m), dry_run=args.dry_run)
            print(f"  {'📝' if args.dry_run else '✅'} {result}")
            generated += 1
        harness.audit_info("tests_generated", f"count={generated} dry_run={args.dry_run}")

    result = "pass" if report.line_coverage >= args.target else "fail"
    harness.finish(result)
    sys.exit(0 if result == "pass" else 1)

if __name__ == "__main__":
    main()
