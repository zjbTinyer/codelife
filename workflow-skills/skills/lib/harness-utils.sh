#!/bin/bash
# ============================================================
# harness-utils.sh — 共享基础设施库 (Shell)
# ============================================================
# 提供:
#   1. 安全护栏: 输入校验、危险命令检测、PII 脱敏、风险评估
#   2. 失败处理: 错误分类、优雅降级、结构化错误输出
#   3. 弹性模式: 指数退避重试、熔断器、超时控制、限流
#   4. 可观测性: trace_id、审计日志、指标收集、告警阈值
#
# 用法:
#   source "$(dirname "$0")/lib/harness-utils.sh"
# ============================================================

# === 环境配置 ===
HARNESS_AUDIT_DIR="${HARNESS_AUDIT_DIR:-$HOME/.claude/skill-audit}"
HARNESS_CIRCUIT_DIR="${HARNESS_CIRCUIT_DIR:-$HOME/.claude/skill-circuit}"
HARNESS_METRICS_DIR="${HARNESS_METRICS_DIR:-$HOME/.claude/skill-metrics}"

mkdir -p "$HARNESS_AUDIT_DIR" "$HARNESS_CIRCUIT_DIR" "$HARNESS_METRICS_DIR"

# === 颜色和日志 ===
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ============================================================
# 第 1 部分: 可观测性基础设施
# ============================================================

# 生成 trace_id（贯穿整个 Skill 执行链）
HARNESS_TRACE_ID="${HARNESS_TRACE_ID:-$(date +%s)_$$_$((RANDOM % 10000))}"
HARNESS_SKILL_NAME="${HARNESS_SKILL_NAME:-unknown}"
HARNESS_START_TIME=$(date +%s%N)

export HARNESS_TRACE_ID HARNESS_SKILL_NAME

# 审计日志
audit_log() {
    local level="$1" event="$2" detail="${3:-}"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local log_entry=$(jq -nc \
        --arg ts "$timestamp" \
        --arg trace "$HARNESS_TRACE_ID" \
        --arg skill "$HARNESS_SKILL_NAME" \
        --arg level "$level" \
        --arg event "$event" \
        --arg detail "$detail" \
        '{$ts, trace_id: $trace, skill: $skill, level: $level, event: $event, detail: $detail}')
    echo "$log_entry" >> "$HARNESS_AUDIT_DIR/audit.jsonl"
}

# 指标收集
metric_incr() {
    local name="$1" value="${2:-1}"
    local file="$HARNESS_METRICS_DIR/${HARNESS_SKILL_NAME}_${name}.count"
    local count=$(cat "$file" 2>/dev/null || echo "0")
    echo $((count + value)) > "$file"
}

metric_latency() {
    local name="$1" ms="$2"
    local file="$HARNESS_METRICS_DIR/${HARNESS_SKILL_NAME}_${name}.latency"
    echo "$ms" >> "$file"
}

metric_last_value() {
    local name="$1"
    local file="$HARNESS_METRICS_DIR/${HARNESS_SKILL_NAME}_${name}.count"
    cat "$file" 2>/dev/null || echo "0"
}

# 结构化输出
harness_output() {
    local result="$1" checks_json="$2" suggestions_json="$3"
    local total_elapsed=$(( ($(date +%s%N) - HARNESS_START_TIME) / 1000000 ))

    # 计算成功率
    local total_checks=$(echo "$checks_json" | jq 'length' 2>/dev/null || echo "0")
    local passed_checks=$(echo "$checks_json" | jq '[.[] | select(.passed == true)] | length' 2>/dev/null || echo "0")

    metric_latency "total_duration" "$total_elapsed"
    metric_incr "total_runs"

    if [ "$result" = "pass" ]; then
        metric_incr "successful_runs"
        audit_log "INFO" "skill_complete" "result=pass checks=$passed_checks/$total_checks"
    elif [ "$result" = "degraded" ]; then
        metric_incr "degraded_runs"
        audit_log "WARN" "skill_degraded" "result=degraded checks=$passed_checks/$total_checks"
    else
        metric_incr "failed_runs"
        audit_log "ERROR" "skill_failed" "result=fail checks=$passed_checks/$total_checks"
    fi

    jq -n \
        --arg skill "$HARNESS_SKILL_NAME" \
        --arg trace_id "$HARNESS_TRACE_ID" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg result "$result" \
        --argjson checks "$checks_json" \
        --argjson suggestions "$suggestions_json" \
        --argjson duration_ms "$total_elapsed" \
        --argjson metrics "{\"total_runs\": $(metric_last_value total_runs), \"success_rate\": $([ $(metric_last_value total_runs) -gt 0 ] && echo "scale=1; $(metric_last_value successful_runs) * 100 / $(metric_last_value total_runs)" | bc || echo "0")}" \
        '{$skill, trace_id: $trace_id, timestamp: $timestamp, result: $result, checks: $checks, suggestions: $suggestions, duration_ms: $duration_ms, metrics: $metrics}'

    audit_log "INFO" "output_generated" "duration_ms=$total_elapsed"
}


# ============================================================
# 第 2 部分: 安全护栏
# ============================================================

# 危险命令模式库
DANGEROUS_PATTERNS=(
    "rm -rf /:CRITICAL:递归删除根目录"
    "rm -rf ~:CRITICAL:删除用户主目录"
    "> /dev/sd:CRITICAL:写入原始磁盘设备"
    "mkfs.:CRITICAL:格式化文件系统"
    "dd if=:HIGH:磁盘低级操作"
    "curl.*|.*sh:CRITICAL:远程脚本直接执行"
    "wget.*|.*sh:CRITICAL:远程脚本直接执行"
    "eval :HIGH:动态代码执行"
    "sudo :HIGH:提权操作"
    "chmod 777:HIGH:过度开放的权限"
    "ANTHROPIC_API_KEY:CRITICAL:敏感API密钥泄露"
    "OPENAI_API_KEY:CRITICAL:敏感API密钥泄露"
    "DB_PASSWORD:HIGH:数据库密码泄露"
    "PRIVATE_KEY:CRITICAL:私钥泄露"
)

# PII 脱敏
sanitize_pii() {
    local text="$1"
    # 手机号
    text=$(echo "$text" | sed -E 's/1[3-9][0-9]{9}/***PHONE***/g')
    # 身份证
    text=$(echo "$text" | sed -E 's/[0-9]{17}[0-9Xx]/***ID***/g')
    # API Key
    text=$(echo "$text" | sed -E 's/sk-[a-zA-Z0-9]{32,}/***API_KEY***/g')
    # Email
    text=$(echo "$text" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/***EMAIL***/g')
    echo "$text"
}

# 安全扫描
security_scan() {
    local content="$1"
    local max_risk=0
    local findings=()

    for pattern_def in "${DANGEROUS_PATTERNS[@]}"; do
        IFS=':' read -r pattern severity desc <<< "$pattern_def"
        if echo "$content" | grep -qE "$pattern"; then
            local risk=0
            case "$severity" in
                CRITICAL) risk=100 ;;
                HIGH)     risk=75 ;;
                MEDIUM)   risk=50 ;;
                LOW)      risk=25 ;;
            esac
            findings+=("{\"pattern\":\"$pattern\",\"severity\":\"$severity\",\"description\":\"$desc\",\"risk\":$risk}")
            [ $risk -gt $max_risk ] && max_risk=$risk
        fi
    done

    local findings_json="[$(IFS=,; echo "${findings[*]}")]"
    local action="allow"
    [ $max_risk -ge 100 ] && action="block"
    [ $max_risk -ge 75 ] && [ $max_risk -lt 100 ] && action="warn"

    echo "{\"max_risk\":$max_risk,\"action\":\"$action\",\"findings\":$findings_json}"
}

# 输入校验
validate_input() {
    local input="$1" max_length="${2:-10000}"

    if [ ${#input} -gt "$max_length" ]; then
        echo "{\"valid\":false,\"reason\":\"输入长度 ${#input} 超过限制 $max_length\"}"
        return 1
    fi

    # 检查是否有明显的注入尝试
    local injection_check
    injection_check=$(echo "$input" | grep -cE '(ignore|forget).*(instruction|prompt|rule|指令)' || true)
    if [ "$injection_check" -gt 0 ]; then
        echo "{\"valid\":false,\"reason\":\"检测到可能的 Prompt 注入\"}"
        return 1
    fi

    echo "{\"valid\":true}"
}


# ============================================================
# 第 3 部分: 弹性模式
# ============================================================

# 指数退避重试
retry_with_backoff() {
    local max_attempts="${1:-3}"
    local base_delay="${2:-1}"
    local max_delay="${3:-30}"
    local cmd="$4"

    local attempt=0
    local last_error=""

    while [ $attempt -lt "$max_attempts" ]; do
        if eval "$cmd" 2>/tmp/harness_retry_err.$$; then
            metric_incr "retry_success"
            return 0
        fi
        last_error=$(cat /tmp/harness_retry_err.$$ 2>/dev/null || echo "unknown")
        attempt=$((attempt + 1))

        if [ $attempt -lt "$max_attempts" ]; then
            local delay=$(( base_delay * (2 ** (attempt - 1)) ))
            # 添加 ±30% 抖动
            local jitter=$(( (RANDOM % (delay * 60 / 100)) - (delay * 30 / 100) ))
            delay=$(( delay + jitter ))
            [ $delay -gt "$max_delay" ] && delay=$max_delay

            audit_log "WARN" "retry_attempt" "attempt=$attempt/$max_attempts delay=${delay}s error=${last_error:0:100}"
            echo -e "${YELLOW}[RETRY ${attempt}/${max_attempts}]${NC} ${last_error:0:100} — ${delay}s 后重试..."
            sleep "$delay"
        fi
    done

    metric_incr "retry_exhausted"
    audit_log "ERROR" "retry_exhausted" "attempts=$max_attempts error=${last_error:0:100}"
    return 1
}

# 熔断器
circuit_breaker_check() {
    local circuit_name="$1" failure_threshold="${2:-5}" recovery_secs="${3:-60}"
    local state_file="$HARNESS_CIRCUIT_DIR/${circuit_name}.json"

    # 读取熔断器状态
    if [ -f "$state_file" ]; then
        local state=$(jq -r '.state // "closed"' "$state_file" 2>/dev/null || echo "closed")
        local failures=$(jq -r '.failures // 0' "$state_file" 2>/dev/null || echo "0")
        local last_failure=$(jq -r '.last_failure // 0' "$state_file" 2>/dev/null || echo "0")
        local now=$(date +%s)

        if [ "$state" = "open" ]; then
            local elapsed=$((now - last_failure))
            if [ $elapsed -ge "$recovery_secs" ]; then
                # 半开状态：允许尝试
                echo '{"state":"half_open","allowed":true}'
                return 0
            else
                echo "{\"state\":\"open\",\"allowed\":false,\"retry_after\":$((recovery_secs - elapsed))}"
                return 1
            fi
        fi
    fi

    echo '{"state":"closed","allowed":true}'
}

circuit_breaker_record() {
    local circuit_name="$1" success="$2"
    local state_file="$HARNESS_CIRCUIT_DIR/${circuit_name}.json"

    if [ "$success" = "true" ]; then
        # 成功 → 重置
        echo '{"state":"closed","failures":0,"last_failure":0}' > "$state_file"
    else
        local state="closed" failures=0 last_failure=0
        [ -f "$state_file" ] && eval "$(jq -r '"state=\(.state//"closed");failures=\(.failures//0);last_failure=\(.last_failure//0)"' "$state_file" 2>/dev/null)"

        failures=$((failures + 1))
        last_failure=$(date +%s)
        local threshold="${3:-5}"
        [ $failures -ge "$threshold" ] && state="open"

        echo "{\"state\":\"$state\",\"failures\":$failures,\"last_failure\":$last_failure}" > "$state_file"

        if [ "$state" = "open" ]; then
            audit_log "ERROR" "circuit_open" "name=$circuit_name failures=$failures"
        fi
    fi
}

# 超时控制
run_with_timeout() {
    local timeout_secs="$1"
    local cmd="$2"
    local fallback="${3:-}"

    if timeout "$timeout_secs" bash -c "$cmd" 2>/dev/null; then
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            audit_log "WARN" "timeout" "timeout=${timeout_secs}s"
            metric_incr "timeouts"
            if [ -n "$fallback" ]; then
                echo -e "${YELLOW}[TIMEOUT]${NC} 操作超时 (${timeout_secs}s)，执行降级..."
                eval "$fallback"
                return 0
            fi
        fi
        return $exit_code
    fi
}

# 降级管理器
degradation_level=0  # 0=正常, 1=部分降级, 2=最小服务

check_degradation() {
    local error_count=$(metric_last_value "errors")
    local timeout_count=$(metric_last_value "timeouts")

    if [ "$error_count" -gt 10 ] || [ "$timeout_count" -gt 5 ]; then
        degradation_level=2
    elif [ "$error_count" -gt 5 ] || [ "$timeout_count" -gt 2 ]; then
        degradation_level=1
    fi

    echo "$degradation_level"
}

# 错误分类
classify_error() {
    local error_msg="$1"
    local error_lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

    if echo "$error_lower" | grep -qE 'timeout|timed out|connection refused|temporarily unavailable|too many|rate limit|429|503|502'; then
        echo "TRANSIENT"  # 瞬时错误，可重试
    elif echo "$error_lower" | grep -qE 'not found|invalid|unauthorized|forbidden|permission denied|404|401|403'; then
        echo "PERMANENT"  # 永久错误，不应重试
    elif echo "$error_lower" | grep -qE 'degraded|partial|fallback|skip'; then
        echo "DEGRADED"   # 已降级
    else
        echo "TRANSIENT"  # 默认假定瞬时（更安全）
    fi
}


# ============================================================
# 第 4 部分: 初始化
# ============================================================

harness_init() {
    local skill_name="$1"
    export HARNESS_SKILL_NAME="$skill_name"
    export HARNESS_TRACE_ID="${HARNESS_TRACE_ID:-$(date +%s)_$$_$((RANDOM % 10000))}"
    export HARNESS_START_TIME=$(date +%s%N)

    audit_log "INFO" "skill_start" "trace_id=$HARNESS_TRACE_ID"

    echo -e "${CYAN}[HARNESS]${NC} $skill_name — trace: ${HARNESS_TRACE_ID:0:12}"
}

harness_finish() {
    local result="$1"
    local total_elapsed=$(( ($(date +%s%N) - HARNESS_START_TIME) / 1000000 ))

    audit_log "INFO" "skill_finish" "result=$result duration_ms=$total_elapsed"
    metric_latency "total_duration" "$total_elapsed"

    local success_rate="N/A"
    local total=$(metric_last_value "total_runs")
    if [ "$total" -gt 0 ]; then
        local success=$(metric_last_value "successful_runs")
        success_rate="$(echo "scale=1; $success * 100 / $total" | bc)%"
    fi

    echo -e "${CYAN}──────────────────────────────────────${NC}"
    echo -e "${CYAN}[HARNESS]${NC} 结果: ${result} | 耗时: ${total_elapsed}ms | 成功率: ${success_rate}"
    echo -e "${CYAN}[HARNESS]${NC} 审计: ${HARNESS_AUDIT_DIR}/audit.jsonl"
    echo -e "${CYAN}[HARNESS]${NC} 指标: ${HARNESS_METRICS_DIR}/"
}
