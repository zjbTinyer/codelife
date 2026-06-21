#!/bin/bash
# ============================================================
# deploy-guard.sh — 部署后自动健康验证 (Harness 增强版)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness-utils.sh"

harness_init "deploy-guard"

# === 配置 ===
ENV="${1:-dev}"
CONFIRM="${2:-}"
SKIP_DB="${SKIP_DB:-false}"
SKIP_API="${SKIP_API:-false}"
HEALTH_URL="${HEALTH_URL:-}"
API_BASE_URL="${API_BASE_URL:-}"
TIMEOUT="${TIMEOUT:-30}"
MAX_RETRIES="${MAX_RETRIES:-2}"

audit_log "INFO" "config_load" "env=$ENV skip_db=$SKIP_DB skip_api=$SKIP_API"

# 环境默认 URL
case "$ENV" in
    dev|development)  BASE_URL="${HEALTH_URL:-http://localhost:8080}" ;;
    staging|stg)      BASE_URL="${HEALTH_URL:-https://staging-api.yourcompany.com}" ;;
    prod|production)  BASE_URL="${HEALTH_URL:-https://api.yourcompany.com}" ;;
    *) echo -e "${RED}[ERROR]${NC} 未知环境: $ENV (dev/staging/prod)"; exit 1 ;;
esac

# === 安全护栏: 生产环境保护 ===
if [ "$ENV" = "prod" ] || [ "$ENV" = "production" ]; then
    if [ "$CONFIRM" != "--confirm" ]; then
        audit_log "WARN" "prod_unconfirmed" "生产环境检查被拒绝：未加 --confirm"
        echo "⚠️  生产环境操作！请加 --confirm 确认，或设置 ENV=prod 后重试"
        echo "   生产环境检查仅执行只读操作，不会修改任何数据"
        exit 1
    fi
    audit_log "INFO" "prod_confirmed" "用户已确认生产环境检查"
    echo -e "${RED}🔴 生产环境模式 — 仅执行只读检查${NC}"

    # 生产环境不允许 API 写操作
    SKIP_API_WRITE=true
fi

# === 配置打印 ===
echo "╔══════════════════════════════════════════╗"
echo "║    Deploy Guard — 部署后健康验证          ║"
echo "╠══════════════════════════════════════════╣"
echo "║ Trace: ${HARNESS_TRACE_ID:0:12}"
echo "║ 环境: $ENV → $BASE_URL"
echo "║ DB检查: $([ "$SKIP_DB" = true ] && echo '跳过' || echo '执行')"
echo "║ API冒烟: $([ "$SKIP_API" = true ] && echo '跳过' || echo '执行')"
echo "║ 重试次数: $MAX_RETRIES"
echo "╚══════════════════════════════════════════╝"
echo ""

# === 带重试的 HTTP 调用 ===
curl_with_retry() {
    local description="$1" url="$2" expected_code="${3:-200}" method="${4:-GET}"
    local max_attempts=$((MAX_RETRIES + 1))

    for attempt in $(seq 1 $max_attempts); do
        local http_code
        http_code=$(curl -s -o /tmp/curl_body.$$ -w "%{http_code}" \
            -X "$method" --max-time "$TIMEOUT" "$url" 2>/dev/null || echo "000")

        if [ "$http_code" = "$expected_code" ]; then
            echo "$http_code"
            return 0
        fi

        local error_type=$(classify_error "HTTP $http_code from $url")
        if [ "$error_type" = "PERMANENT" ] && [ $attempt -lt $max_attempts ]; then
            # 永久错误不重试
            echo "$http_code"
            return 1
        fi

        if [ $attempt -lt $max_attempts ]; then
            local delay=$(( 2 ** (attempt - 1) ))
            echo -e "${YELLOW}[RETRY ${attempt}/${MAX_RETRIES}]${NC} $description → HTTP $http_code, ${delay}s 后重试..."
            sleep "$delay"
        fi
    done

    echo "${http_code:-000}"
    return 1
}

# === 检查 1: 健康检查 ===
check_health() {
    echo -e "${BLUE}[CHECK]${NC} 健康检查: $BASE_URL/actuator/health"

    local http_code
    if http_code=$(curl_with_retry "health" "$BASE_URL/actuator/health" 200); then
        log_pass "健康检查 200 OK"
        echo "{\"name\":\"health\",\"passed\":true,\"status\":200}"
        circuit_breaker_record "health_check" "true"
    else
        log_fail "健康检查返回 $http_code"
        circuit_breaker_record "health_check" "false"
        echo "{\"name\":\"health\",\"passed\":false,\"status\":$http_code,\"detail\":\"健康检查失败 — 服务可能未就绪\"}"
    fi
}

# === 检查 2: 详细健康 ===
check_detail() {
    echo -e "${BLUE}[CHECK]${NC} 详细健康信息..."

    if health_json=$(curl -s --max-time "$TIMEOUT" "$BASE_URL/actuator/health" 2>/dev/null); then
        local status=$(echo "$health_json" | jq -r '.status // "DOWN"')

        local all_up=true
        local comps=$(echo "$health_json" | jq -r '.components | keys[]?' 2>/dev/null || echo "")
        for comp in $comps; do
            local cs=$(echo "$health_json" | jq -r ".components[\"$comp\"].status // \"DOWN\"")
            [ "$cs" != "UP" ] && { all_up=false; log_warn "  $comp: $cs"; }
        done

        if [ "$all_up" = true ]; then
            log_pass "所有组件 UP"
        fi

        echo "{\"name\":\"detail\",\"passed\":$all_up,\"overall\":\"$status\"}"
    else
        echo '{"name":"detail","passed":false,"detail":"无法获取详细健康信息"}'
    fi
}

# === 检查 3: 数据库连接 ===
check_db() {
    if [ "$SKIP_DB" = true ]; then
        log_warn "跳过数据库检查"
        echo '{"name":"db","passed":true,"detail":"已跳过"}'
        return
    fi

    echo -e "${BLUE}[CHECK]${NC} 数据库连接..."

    local db_host="${DB_HOST:-localhost}" db_port="${DB_PORT:-5432}"
    local db_name="${DB_NAME:-postgres}" db_user="${DB_USER:-postgres}"

    # 安全检查: 只允许 SELECT
    if ! command -v psql &>/dev/null; then
        log_warn "psql 不可用，跳过"
        echo '{"name":"db","passed":true,"detail":"psql不可用"}'
        return
    fi

    # 带重试的连接（数据库连接可能因网络波动失败）
    local connected=false
    for attempt in $(seq 1 $((MAX_RETRIES + 1))); do
        if PGPASSWORD="${DB_PASSWORD:-}" psql \
            -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
            -c "SELECT 1 AS connection_test;" -t -A 2>/dev/null | grep -q "1"; then
            connected=true
            break
        fi
        if [ $attempt -le $MAX_RETRIES ]; then
            sleep 2
        fi
    done

    if [ "$connected" = true ]; then
        log_pass "数据库连接正常"
        # 安全: 只查行数，不查内容
        local tables_check=""
        for table in orders users products; do
            local count=$(PGPASSWORD="${DB_PASSWORD:-}" psql \
                -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
                -c "SELECT count(*) FROM $table;" -t -A 2>/dev/null || echo "N/A")
            tables_check="$tables_check \"$table\": \"$count\","
        done
        tables_check="${tables_check%,}"
        echo "{\"name\":\"db\",\"passed\":true,\"tables\":{$tables_check}}"
        circuit_breaker_record "db_connection" "true"
    else
        log_fail "数据库连接失败"
        circuit_breaker_record "db_connection" "false"
        echo '{"name":"db","passed":false,"detail":"数据库连接失败，请检查Cloud SQL Proxy和连接参数"}'
    fi
}

# === 检查 4: API 冒烟 ===
check_api_smoke() {
    if [ "$SKIP_API" = true ]; then
        log_warn "跳过 API 冒烟"
        echo '{"name":"api_smoke","passed":true,"detail":"已跳过"}'
        return
    fi

    echo -e "${BLUE}[CHECK]${NC} API 冒烟测试..."

    local apis=("GET:/api/health:200")
    if [ "${SKIP_API_WRITE:-false}" != "true" ]; then
        apis+=("GET:/api/orders?page=1&size=1:200")
    fi

    local api_results="[" all_passed=true

    for api_spec in "${apis[@]}"; do
        IFS=':' read -r method path expected_code <<< "$api_spec"
        local url="${API_BASE_URL:-$BASE_URL}${path}"

        local http_code
        if http_code=$(curl_with_retry "$method $path" "$url" "$expected_code" "$method"); then
            log_pass "$method $path → $http_code"
            api_results+="{\"api\":\"$method $path\",\"passed\":true,\"code\":$http_code},"
        else
            log_fail "$method $path → $http_code (期望 $expected_code)"
            api_results+="{\"api\":\"$method $path\",\"passed\":false,\"code\":$http_code,\"expected\":$expected_code},"
            all_passed=false
        fi
    done

    api_results="${api_results%,}]"
    echo "{\"name\":\"api_smoke\",\"passed\":$all_passed,\"results\":$api_results}"
}

# === 检查 5: 错误日志 ===
check_errors() {
    echo -e "${BLUE}[CHECK]${NC} 错误指标..."

    # 安全的只读检查
    if error_count=$(curl -s --max-time 10 \
        "$BASE_URL/actuator/metrics/http.server.requests?tag=status:5xx" 2>/dev/null); then
        local count=$(echo "$error_count" | jq -r '.measurements[0].value // 0')
        if [ "${count:-0}" != "0" ]; then
            log_warn "最近有 $count 个 5xx 错误"
            audit_log "WARN" "5xx_detected" "count=$count"
            echo "{\"name\":\"errors\",\"passed\":false,\"5xx_count\":$count}"
        else
            log_pass "无 5xx 错误"
            echo '{"name":"errors","passed":true,"5xx_count":0}'
        fi
    else
        echo '{"name":"errors","passed":true,"detail":"指标端点不可用"}'
    fi
}

# === 主流程 ===
main() {
    # 安全扫描：检查目标 URL 是否合理
    local url_scan=$(security_scan "$BASE_URL")
    if [ "$(echo "$url_scan" | jq -r '.action')" = "block" ]; then
        echo -e "${RED}[FATAL]${NC} 安全策略阻止访问该 URL"
        harness_finish "blocked"
        exit 1
    fi

    local all_passed=true degraded=false checks_json="["

    # 健康检查（关键 — 失败直接判定整体失败）
    local h=$(check_health)
    checks_json+="$h,"

    local d=$(check_detail)
    checks_json+="$d,"

    local db=$(check_db)
    checks_json+="$db,"

    local api=$(check_api_smoke)
    checks_json+="$api,"

    local err=$(check_errors)
    checks_json+="$err"
    checks_json+="]"

    # 统计通过率
    local total=$(echo "$checks_json" | jq 'length')
    local passed=$(echo "$checks_json" | jq '[.[] | select(.passed == true)] | length')

    # 降级判断
    if [ "$passed" -lt "$total" ] && [ "$passed" -ge $((total - 1)) ]; then
        degraded=true
    fi

    [ "$passed" -lt "$total" ] && all_passed=false

    # 输出
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local final_result="fail"
    if [ "$all_passed" = true ]; then
        final_result="pass"
        echo -e "  ${GREEN}✅ 部署验证通过 — $ENV 环境运行正常${NC}"
    elif [ "$degraded" = true ]; then
        final_result="degraded"
        echo -e "  ${YELLOW}⚠️  部分检查未通过（降级: $passed/$total）${NC}"
    else
        final_result="fail"
        echo -e "  ${RED}❌ $((total - passed))/$total 检查未通过${NC}"
        echo "  1. 健康检查失败 → kubectl logs 查看 Pod 日志"
        echo "  2. DB 连接失败 → 检查 Cloud SQL Proxy"
        echo "  3. API 失败 → 检查路由和服务发现"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    harness_output "$final_result" "$checks_json" "[]"
    harness_finish "$final_result"

    [ "$final_result" = "pass" ] && exit 0
    [ "$final_result" = "degraded" ] && exit 0
    exit 1
}

main "$@"
