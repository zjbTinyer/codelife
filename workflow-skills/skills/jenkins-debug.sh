#!/bin/bash
# ============================================================
# jenkins-debug.sh — Jenkins Pipeline 问题定位 (Harness 增强版)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness-utils.sh"

harness_init "jenkins-debug"

# === 配置 ===
JENKINS_URL="${JENKINS_URL:-}" JENKINS_USER="${JENKINS_USER:-}" JENKINS_TOKEN="${JENKINS_TOKEN:-}"
JOB_NAME="" BUILD_NUM="" LOCAL_LOG="" WAIT_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --job) JOB_NAME="$2"; shift 2 ;;
        --build) BUILD_NUM="$2"; shift 2 ;;
        --log) LOCAL_LOG="$2"; shift 2 ;;
        --url) JENKINS_URL="$2"; shift 2 ;;
        --wait) WAIT_MODE=true; shift ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

audit_log "INFO" "config" "job=$JOB_NAME build=${BUILD_NUM:-last}"

# === 错误模式库（带类型分类） ===
declare -A ERROR_PATTERNS
ERROR_PATTERNS["maven.*BUILD FAILURE"]="Maven 构建失败 — 检查编译错误或测试失败|TRANSIENT"
ERROR_PATTERNS["Compilation failure"]="编译失败 — 检查源码语法错误|PERMANENT"
ERROR_PATTERNS["cannot find symbol"]="找不到符号 — 可能缺少依赖或 import|PERMANENT"
ERROR_PATTERNS["Tests run:.*Failures: [1-9]"]="单元测试失败 — 查看 test-report|PERMANENT"
ERROR_PATTERNS["Failed to execute goal"]="Maven 插件执行失败 — 检查插件配置|PERMANENT"
ERROR_PATTERNS["sonar.*Quality Gate failed"]="Sonar 质量门禁失败 — 运行 /scan-triage|TRANSIENT"
ERROR_PATTERNS["nexus.*policy.*violation"]="NexusIQ 策略违规 — 存在安全或许可证问题|PERMANENT"
ERROR_PATTERNS["cyberflow.*critical"]="Cyberflow 发现严重漏洞 — 查看 SAST/Container 报告|PERMANENT"
ERROR_PATTERNS["devx.*failed"]="DevX 构建失败 — 检查 devx 配置|TRANSIENT"
ERROR_PATTERNS["g3.*deploy.*failed"]="G3 部署失败 — 检查部署参数和集群状态|TRANSIENT"
ERROR_PATTERNS["Connection refused"]="连接被拒绝 — 目标服务未启动|TRANSIENT"
ERROR_PATTERNS["Connection timed out"]="连接超时 — 网络问题或服务过载|TRANSIENT"
ERROR_PATTERNS["OutOfMemoryError"]="内存溢出 — 增加 JVM 堆内存 (-Xmx)|PERMANENT"
ERROR_PATTERNS["Permission denied"]="权限不足 — 检查文件/目录权限|PERMANENT"
ERROR_PATTERNS["Kubernetes.*CrashLoopBackOff"]="Pod 持续崩溃 — 查看容器日志|PERMANENT"
ERROR_PATTERNS["ImagePullBackOff"]="镜像拉取失败 — 检查镜像仓库和凭证|PERMANENT"

# === 拉取 Jenkins 日志（带重试和熔断） ===
fetch_log() {
    local url="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/consoleText"

    local cb=$(circuit_breaker_check "jenkins_fetch" 3 120)
    if [ "$(echo "$cb" | jq -r '.allowed')" != "true" ]; then
        echo -e "${RED}[CIRCUIT OPEN]${NC} Jenkins 日志拉取熔断"
        return 1
    fi

    local auth=""
    [ -n "$JENKINS_USER" ] && [ -n "$JENKINS_TOKEN" ] && auth="-u ${JENKINS_USER}:${JENKINS_TOKEN}"

    local log_content
    if log_content=$(curl -s $auth --max-time 60 "$url" 2>/dev/null); then
        if echo "$log_content" | grep -q "Not Found\|Access Denied"; then
            audit_log "ERROR" "jenkins_access_denied" "url=$url"
            circuit_breaker_record "jenkins_fetch" "false"
            return 1
        fi
        circuit_breaker_record "jenkins_fetch" "true"
        echo "$log_content"
    else
        circuit_breaker_record "jenkins_fetch" "false"
        return 1
    fi
}

# === 分析 ===
analyze() {
    local log="$1"

    # PII 脱敏
    log=$(sanitize_pii "$log")

    echo "╔══════════════════════════════════════════╗"
    echo "║    Jenkins Pipeline 构建分析              ║"
    echo "║    Trace: ${HARNESS_TRACE_ID:0:12}        ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # 构建结果
    local result=$(echo "$log" | grep -oP '(?:BUILD |Result: )?\K(SUCCESS|FAILURE|UNSTABLE|ABORTED)' | tail -1)
    local duration=$(echo "$log" | grep -oP 'Total time: \K[\d.ms]+' | tail -1)

    echo "## 构建概况"
    case "$result" in
        SUCCESS) echo -e "  状态: ${GREEN}✅ SUCCESS${NC}" ;;
        FAILURE) echo -e "  状态: ${RED}❌ FAILURE${NC}"; metric_incr "build_failures" ;;
        UNSTABLE) echo -e "  状态: ${YELLOW}⚠️  UNSTABLE${NC}" ;;
        *) echo "  状态: $result" ;;
    esac
    echo "  耗时: ${duration:-未知}"
    echo ""

    # Stage 分析
    echo "## Stage 执行情况"
    local stage_patterns=("devx.*build" "sonar" "nexus" "cyberflow.*sast" "cyberflow.*container" "g3.*deploy" "test" "compile")

    for pattern in "${stage_patterns[@]}"; do
        local output=$(echo "$log" | grep -i "$pattern" | tail -3 || echo "")
        if [ -n "$output" ]; then
            if echo "$output" | grep -qi "error\|fail\|violation"; then
                echo -e "  ${RED}❌${NC} $pattern — 失败"
                echo "$output" | head -3 | while read line; do echo "       ${line:0:120}"; done
            else
                echo -e "  ${GREEN}✅${NC} $pattern — 通过"
            fi
        fi
    done
    echo ""

    # 错误匹配
    echo "## 错误分析"
    local found=0
    for pattern in "${!ERROR_PATTERNS[@]}"; do
        if echo "$log" | grep -qi "$pattern"; then
            IFS='|' read -r desc etype <<< "${ERROR_PATTERNS[$pattern]}"
            local flag="🔴"
            [ "$etype" = "TRANSIENT" ] && flag="🟡"
            echo -e "  ${flag} $desc [$etype]"
            echo "$log" | grep -i "$pattern" | head -2 | while read line; do
                echo "    └─ ${line:0:150}"
            done
            ((found++))
        fi
    done
    [ "$found" -eq 0 ] && echo "  未匹配已知模式。将日志提供给 Claude Code 深度分析"
    echo ""

    # 堆栈
    local exceptions=$(echo "$log" | grep -A 20 -E 'Exception|Error: |FAILED' | head -30 || echo "")
    [ -n "$exceptions" ] && echo "## 异常堆栈" && echo "$exceptions" | head -20 && echo ""

    # 建议
    echo "## 💡 修复建议"
    [ "$result" = "FAILURE" ] && cat <<'EOF'
  1. 查看上方 ❌ 标记的 Stage 和错误分析
  2. 扫描问题 → 运行 /scan-triage
  3. 测试失败 → 本地 mvn test
  4. 覆盖率 → 运行 /coverage-hunt
  5. 部署失败 → 检查 G3 集群和 Pod 日志
EOF
    [ "$result" = "UNSTABLE" ] && echo "  1. 通常是测试或警告。检查 Flaky Test 和新 Warning"
    [ "$result" = "SUCCESS" ] && echo "  构建成功！运行 /deploy-guard 验证部署环境"

    echo ""
    echo "## 🛠️ 辅助命令"
    echo "  /scan-triage --jenkins-url $JENKINS_URL --jenkins-job $JOB_NAME"
}

# === 主流程 ===
main() {
    local log_content=""

    if [ -n "$LOCAL_LOG" ]; then
        [ ! -f "$LOCAL_LOG" ] && { log_fail "文件不存在: $LOCAL_LOG"; harness_finish "fail"; exit 1; }
        log_content=$(cat "$LOCAL_LOG")
        audit_log "INFO" "local_log" "file=$LOCAL_LOG"
    elif [ -n "$JOB_NAME" ]; then
        [ -z "$JENKINS_URL" ] && { log_fail "请设置 JENKINS_URL"; harness_finish "fail"; exit 1; }
        BUILD_NUM="${BUILD_NUM:-lastBuild}"

        # 熔断器保护
        local cb=$(circuit_breaker_check "jenkins_fetch" 3 120)
        if [ "$(echo "$cb" | jq -r '.allowed')" != "true" ]; then
            echo -e "${RED}[CIRCUIT OPEN]${NC} Jenkins API 熔断中"
            harness_finish "blocked"
            exit 1
        fi

        log_content=$(fetch_log) || {
            harness_finish "fail"
            exit 1
        }
    else
        log_fail "请指定 --job <job-name> 或 --log <file>"
        harness_finish "fail"
        exit 1
    fi

    # 安全扫描日志内容（脱敏）
    log_scan=$(security_scan "$log_content" 2>/dev/null || echo '{"action":"allow"}')
    if [ "$(echo "$log_scan" | jq -r '.action')" = "block" ]; then
        audit_log "ERROR" "log_content_blocked" "日志包含敏感信息"
    fi

    analyze "$log_content"
    harness_finish "pass"
}

main "$@"
