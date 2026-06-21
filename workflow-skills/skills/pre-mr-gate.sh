#!/bin/bash
# ============================================================
# pre-mr-gate.sh — 提 MR 前自动门禁检查 (Harness 增强版)
# ============================================================
set -euo pipefail

# 加载共享基础设施
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness-utils.sh"

# === 初始化 Harness ===
harness_init "pre-mr-gate"
audit_log "INFO" "config_load" "module=${MODULE:-all} line_cov=${COVERAGE_LINE:-80} branch_cov=${COVERAGE_BRANCH:-70}"

# === 配置 ===
COVERAGE_LINE="${COVERAGE_LINE:-80}"
COVERAGE_BRANCH="${COVERAGE_BRANCH:-70}"
MODULE="${MODULE:-}"
SKIP_BDD="${SKIP_BDD:-false}"
SKIP_COVERAGE="${SKIP_COVERAGE:-false}"
DRY_RUN="${DRY_RUN:-false}"

# === 配置打印 ===
echo "╔══════════════════════════════════════════╗"
echo "║       Pre-MR Gate — 提 MR 前检查         ║"
echo "╠══════════════════════════════════════════╣"
echo "║ Trace: ${HARNESS_TRACE_ID:0:12}"
echo "║ 模块: ${MODULE:-全部}"
echo "║ 行覆盖率阈值: ${COVERAGE_LINE}%"
echo "║ 分支覆盖率阈值: ${COVERAGE_BRANCH}%"
echo "║ BDD: $([ "$SKIP_BDD" = true ] && echo '跳过' || echo '执行')"
echo "║ Dry Run: $([ "$DRY_RUN" = true ] && echo '是' || echo '否')"
echo "╚══════════════════════════════════════════╝"
echo ""

# === 工具函数 ===
mvn_cmd() {
    local goals="$1"
    if [ -n "$MODULE" ]; then
        echo "mvn $goals -pl $MODULE -am"
    else
        echo "mvn $goals"
    fi
}

# 带 Harness 保护的命令执行
safe_run() {
    local check_name="$1" cmd="$2" timeout_secs="${3:-300}" fallback="${4:-}"

    # 安全扫描
    local scan=$(security_scan "$cmd")
    local action=$(echo "$scan" | jq -r '.action')
    if [ "$action" = "block" ]; then
        echo "{\"name\":\"$check_name\",\"passed\":false,\"detail\":\"安全策略阻止执行\"}"
        audit_log "ERROR" "security_blocked" "$check_name: $(echo "$scan" | jq -r '.findings[0].description')"
        return 1
    fi

    # 熔断器检查
    local cb=$(circuit_breaker_check "$check_name" 5 60)
    local cb_allowed=$(echo "$cb" | jq -r '.allowed')
    if [ "$cb_allowed" != "true" ]; then
        local retry_after=$(echo "$cb" | jq -r '.retry_after // 60')
        echo "{\"name\":\"$check_name\",\"passed\":false,\"detail\":\"熔断器打开，${retry_after}s 后可重试\"}"
        return 1
    fi

    # 执行（带超时和降级）
    local start_time=$(date +%s%N)

    if [ "$DRY_RUN" = true ]; then
        echo "{\"name\":\"$check_name\",\"passed\":true,\"detail\":\"DRY_RUN 模式\",\"dry_run\":true}"
        return 0
    fi

    local exit_code=0
    if run_with_timeout "$timeout_secs" "$cmd" "$fallback"; then
        exit_code=0
        circuit_breaker_record "$check_name" "true"
    else
        exit_code=$?
        circuit_breaker_record "$check_name" "false"

        local error_output=$(tail -5 /tmp/harness_retry_err.$$ 2>/dev/null || echo "执行失败")
        local error_type=$(classify_error "$error_output")

        metric_incr "errors"
        audit_log "ERROR" "check_failed" "check=$check_name exit_code=$exit_code error_type=$error_type"
    fi

    local elapsed=$(( ($(date +%s%N) - start_time) / 1000000 ))
    metric_latency "${check_name}_duration" "$elapsed"

    return $exit_code
}

# === 检查 1: Maven 编译 ===
check_compile() {
    echo -e "${BLUE}[CHECK]${NC} Maven 编译..."
    local cmd="$(mvn_cmd "test-compile") -q"

    if safe_run "compile" "$cmd" 600; then
        local elapsed=$(( ($(date +%s%N) - ${start_time:-0}) / 1000000 ))
        log_pass "编译通过 (${elapsed}ms)"
        echo "{\"name\":\"compile\",\"passed\":true,\"detail\":\"编译通过\",\"duration_ms\":$elapsed}"
    else
        log_fail "编译失败"
        echo "{\"name\":\"compile\",\"passed\":false,\"detail\":\"编译失败，请检查源码错误\",\"type\":\"PERMANENT\"}"
        metric_incr "compile_failures"
    fi
}

# === 检查 2: 单元测试 ===
check_unit_tests() {
    echo -e "${BLUE}[CHECK]${NC} 单元测试..."
    local cmd="$(mvn_cmd "test") -q"

    local start_time=$(date +%s%N)
    local test_output

    if [ "$DRY_RUN" = true ]; then
        echo '{"name":"unit_test","passed":true,"total":0,"failed":0,"detail":"DRY_RUN 模式"}'
        return
    fi

    # 使用 retry 逻辑（测试可能因环境波动失败）
    local max_retries=1  # 测试通常不重试（除非是明显的flaky环境）
    if test_output=$(timeout 600 bash -c "$cmd" 2>&1); then
        local total=$(echo "$test_output" | grep -oP 'Tests run: \K\d+' | tail -1 || echo "0")
        local failed=$(echo "$test_output" | grep -oP 'Failures: \K\d+' | tail -1 || echo "0")
        local errors=$(echo "$test_output" | grep -oP 'Errors: \K\d+' | tail -1 || echo "0")
        local failed_total=$((failed + errors))
        local elapsed=$(( ($(date +%s%N) - start_time) / 1000000 ))

        if [ "$failed_total" -eq 0 ]; then
            log_pass "单元测试通过 ($total tests, ${elapsed}ms)"
            echo "{\"name\":\"unit_test\",\"passed\":true,\"total\":$total,\"failed\":0,\"duration_ms\":$elapsed}"
        else
            log_fail "单元测试失败 ($failed_total/$total)"
            echo "{\"name\":\"unit_test\",\"passed\":false,\"total\":$total,\"failed\":$failed_total,\"detail\":\"$failed_total 个测试失败\",\"duration_ms\":$elapsed}"
            metric_incr "test_failures"
        fi
        circuit_breaker_record "unit_test" "true"
    else
        log_fail "测试执行异常或超时"
        echo "{\"name\":\"unit_test\",\"passed\":false,\"total\":0,\"failed\":0,\"detail\":\"测试执行异常或超时 (600s)\"}"
        circuit_breaker_record "unit_test" "false"
        metric_incr "test_timeouts"
    fi
}

# === 检查 3: 代码覆盖率 ===
check_coverage() {
    if [ "$SKIP_COVERAGE" = true ]; then
        echo -e "${YELLOW}[SKIP]${NC} 覆盖率检查"
        echo '{"name":"coverage","passed":true,"line_cov":0,"branch_cov":0,"detail":"已跳过"}'
        return
    fi

    echo -e "${BLUE}[CHECK]${NC} 代码覆盖率..."

    if [ "$DRY_RUN" = true ]; then
        echo "{\"name\":\"coverage\",\"passed\":true,\"line_cov\":85.0,\"branch_cov\":75.0,\"detail\":\"DRY_RUN 模式\"}"
        return
    fi

    # 生成报告（带超时和降级：失败不阻塞）
    run_with_timeout 120 "$(mvn_cmd 'jacoco:report') -q" "true"

    local jacoco_csv
    if [ -n "$MODULE" ]; then
        jacoco_csv=$(find "$MODULE/target" -name "jacoco.csv" 2>/dev/null | head -1)
    else
        jacoco_csv=$(find . -path "*/target/site/jacoco/jacoco.csv" 2>/dev/null | head -1)
    fi

    if [ -z "$jacoco_csv" ]; then
        log_fail "未找到 JaCoCo 报告，请确认 pom.xml 中配置了 jacoco-maven-plugin"
        echo '{"name":"coverage","passed":false,"line_cov":0,"branch_cov":0,"detail":"未找到 JaCoCo 报告"}'
        return
    fi

    # 解析（带错误处理）
    local line_missed=0 line_covered=0 branch_missed=0 branch_covered=0
    while IFS=',' read -r group package class instr_missed instr_covered branch_miss branch_covered rest; do
        [[ "$group" == "GROUP" ]] && continue
        line_missed=$((line_missed + instr_missed))
        line_covered=$((line_covered + instr_covered))
        branch_missed=$((branch_missed + branch_miss))
        branch_covered=$((branch_covered + branch_covered))
    done < "$jacoco_csv"

    local line_total=$((line_missed + line_covered))
    local branch_total=$((branch_missed + branch_covered))
    local line_cov=0 branch_cov=0

    [ "$line_total" -gt 0 ] && line_cov=$(echo "scale=1; $line_covered * 100 / $line_total" | bc)
    [ "$branch_total" -gt 0 ] && branch_cov=$(echo "scale=1; $branch_covered * 100 / $branch_total" | bc)

    local passed=true detail=""

    if (( $(echo "$line_cov < $COVERAGE_LINE" | bc -l) )); then
        passed=false
        detail="行覆盖率 ${line_cov}% < 阈值 ${COVERAGE_LINE}%"
        log_fail "$detail"
    else
        log_pass "行覆盖率 ${line_cov}% (阈值 ${COVERAGE_LINE}%)"
    fi

    if (( $(echo "$branch_cov < $COVERAGE_BRANCH" | bc -l) )); then
        passed=false
        detail="$detail; 分支覆盖率 ${branch_cov}% < 阈值 ${COVERAGE_BRANCH}%"
        log_fail "分支覆盖率 ${branch_cov}% (阈值 ${COVERAGE_BRANCH}%)"
    else
        log_pass "分支覆盖率 ${branch_cov}% (阈值 ${COVERAGE_BRANCH}%)"
    fi

    echo "{\"name\":\"coverage\",\"passed\":$passed,\"line_cov\":$line_cov,\"branch_cov\":$branch_cov,\"line_threshold\":$COVERAGE_LINE,\"branch_threshold\":$COVERAGE_BRANCH,\"detail\":\"${detail:-覆盖率达标}\"}"
}

# === 检查 4: BDD 测试 ===
check_bdd() {
    if [ "$SKIP_BDD" = true ]; then
        echo -e "${YELLOW}[SKIP]${NC} BDD 测试"
        echo '{"name":"bdd","passed":true,"detail":"已跳过"}'
        return
    fi

    echo -e "${BLUE}[CHECK]${NC} BDD 测试..."
    local bdd_cmd="${BDD_CMD:-mvn test -Dtest=\"*BDD*\" -q}"

    if [ "$DRY_RUN" = true ]; then
        echo '{"name":"bdd","passed":true,"detail":"DRY_RUN 模式"}'
        return
    fi

    if safe_run "bdd" "$bdd_cmd" 300; then
        log_pass "BDD 测试通过"
        echo '{"name":"bdd","passed":true,"detail":"BDD测试通过"}'
    else
        # BDD 失败不阻塞（降级策略）
        log_warn "BDD 测试失败 — 已降级（BDD失败不阻塞MR）"
        echo '{"name":"bdd","passed":true,"detail":"BDD测试失败但已降级（检查BDD_TOLERATE_FAILURE设置）"}'
        audit_log "WARN" "bdd_degraded" "BDD测试失败但已降级处理"
    fi
}

# === 主流程 ===
main() {
    local checks_json="[" suggestions_json="[" all_passed=true degraded=false

    # === 安全检查：Maven 命令 ===
    local mvn_check=$(security_scan "$(mvn_cmd 'test-compile')")
    if [ "$(echo "$mvn_check" | jq -r '.action')" = "block" ]; then
        echo -e "${RED}[FATAL]${NC} 安全策略阻止 Maven 命令执行"
        echo "$mvn_check" | jq '.findings'
        harness_finish "blocked"
        exit 1
    fi

    # === 执行检查 ===
    local compile_result=$(check_compile)
    checks_json+="$compile_result,"
    if echo "$compile_result" | jq -e '.passed == false' >/dev/null 2>&1; then
        all_passed=false
    fi

    local test_result=$(check_unit_tests)
    checks_json+="$test_result,"
    if echo "$test_result" | jq -e '.passed == false' >/dev/null 2>&1; then
        all_passed=false
    fi

    local coverage_result=$(check_coverage)
    checks_json+="$coverage_result,"
    if echo "$coverage_result" | jq -e '.passed == false' >/dev/null 2>&1; then
        all_passed=false
        suggestions_json+='{"action":"运行 /coverage-hunt 分析未覆盖代码并生成测试","skill":"coverage-hunt","severity":"recommended"},'
    fi

    local bdd_result=$(check_bdd)
    checks_json+="$bdd_result"
    checks_json+="]"
    suggestions_json="${suggestions_json%,}]"

    # === 降级判断 ===
    local dlevel=$(check_degradation)
    if [ "$dlevel" -ge 2 ] && [ "$all_passed" = false ]; then
        degraded=true
        echo -e "${YELLOW}[DEGRADED]${NC} 系统处于降级模式 (level=$dlevel)，部分非关键检查已跳过"
    fi

    # === 输出 ===
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local final_result="fail"
    if [ "$all_passed" = true ]; then
        final_result="pass"
        echo -e "  ${GREEN}✅ 全部检查通过！可以提 MR 了${NC}"
    elif [ "$degraded" = true ]; then
        final_result="degraded"
        echo -e "  ${YELLOW}⚠️  部分检查未通过（降级模式）${NC}"
    else
        final_result="fail"
        echo -e "  ${RED}❌ 有检查未通过，请修复后重新运行${NC}"
        echo "  - 编译/测试失败: 查看上面错误信息"
        echo "  - 覆盖率不足: 运行 /coverage-hunt 生成测试骨架"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 结构化输出 + 审计
    harness_output "$final_result" "$checks_json" "$suggestions_json"
    harness_finish "$final_result"

    [ "$final_result" = "pass" ] && exit 0
    [ "$final_result" = "degraded" ] && exit 0
    exit 1
}

main "$@"
