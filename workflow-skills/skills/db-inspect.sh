#!/bin/bash
# ============================================================
# db-inspect.sh — GCP PostgreSQL 诊断工具 (Harness 增强版)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness-utils.sh"

harness_init "db-inspect"

# === 配置 ===
DB_HOST="${DB_HOST:-localhost}" DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}" DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="" QUERY="" MODE="" SCHEMA_TABLE=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) DB_NAME="$2"; shift 2 ;;
        --host) DB_HOST="$2"; shift 2 ;;
        --port) DB_PORT="$2"; shift 2 ;;
        --user) DB_USER="$2"; shift 2 ;;
        --password) DB_PASSWORD="$2"; shift 2 ;;
        --tables) MODE="tables"; shift ;;
        --diagnose) MODE="diagnose"; shift ;;
        --monitor) MODE="monitor"; shift ;;
        --schema) MODE="schema"; SCHEMA_TABLE="$2"; shift 2 ;;
        --query) MODE="query"; QUERY="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

audit_log "INFO" "config" "host=$DB_HOST port=$DB_PORT db=$DB_NAME mode=$MODE"

# === 安全护栏: 数据库连接检查 ===
if [ -z "$DB_NAME" ]; then
    echo "用法: db-inspect.sh --db <数据库名> [--tables|--diagnose|--monitor|--schema|--query]"
    exit 1
fi

# 安全检查: 目标主机
host_scan=$(security_scan "$DB_HOST")
if [ "$(echo "$host_scan" | jq -r '.action')" = "block" ]; then
    echo -e "${RED}[FATAL]${NC} 安全策略阻止连接该数据库主机"
    harness_finish "blocked"
    exit 1
fi

# psql 封装（只读，带超时重试）
run_psql() {
    local sql="$1" timeout="${2:-10}"

    # SQL 安全检查
    if [ "$MODE" != "query" ] || [ "${ALLOW_WRITE:-false}" != "true" ]; then
        local sql_upper=$(echo "$sql" | tr '[:lower:]' '[:upper:]')
        if ! [[ "$sql_upper" =~ ^SELECT|^EXPLAIN|^SHOW|^\\d ]]; then
            audit_log "WARN" "sql_blocked" "非SELECT操作被阻止: ${sql:0:100}"
            echo "[BLOCKED] 仅允许只读查询。如需写操作，请设置 ALLOW_WRITE=true"
            return 1
        fi
    fi

    PGPASSWORD="$DB_PASSWORD" psql \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "$sql" --no-align --field-separator=" | " \
        -v ON_ERROR_STOP=1 2>&1
}

# 诊断查询集
declare -A DIAGNOSE_QUERIES
DIAGNOSE_QUERIES["连接数"]="SELECT count(*) FILTER (WHERE state='active') as active, count(*) FILTER (WHERE state='idle') as idle, count(*) FILTER (WHERE state='idle in transaction') as idle_xact FROM pg_stat_activity WHERE datname='$DB_NAME';"
DIAGNOSE_QUERIES["长查询(>5s)"]="SELECT pid, now()-query_start AS duration, state, LEFT(query,80) FROM pg_stat_activity WHERE state!='idle' AND now()-query_start > interval '5 seconds' AND datname='$DB_NAME' LIMIT 10;"
DIAGNOSE_QUERIES["锁等待"]="SELECT blocked_locks.pid AS blocked, blocking_locks.pid AS blocking FROM pg_catalog.pg_locks blocked_locks JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype=blocked_locks.locktype AND blocking_locks.pid!=blocked_locks.pid JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid=blocking_locks.pid WHERE NOT blocked_locks.granted LIMIT 10;"
DIAGNOSE_QUERIES["表大小(Top20)"]="SELECT schemaname||'.'||tablename AS tbl, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_stat_user_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 20;"
DIAGNOSE_QUERIES["缓存命中率"]="SELECT round(sum(heap_blks_hit)*100.0/greatest(sum(heap_blks_hit)+sum(heap_blks_read),1),2) AS table_cache_pct FROM pg_statio_user_tables;"
DIAGNOSE_QUERIES["未使用索引"]="SELECT schemaname||'.'||relname AS tbl, indexrelname AS idx, pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan FROM pg_stat_user_indexes WHERE idx_scan<10 AND indexrelname NOT LIKE '%pkey%' ORDER BY pg_relation_size(indexrelid) DESC LIMIT 10;"
DIAGNOSE_QUERIES["死元组(VACUUM)"]="SELECT schemaname||'.'||relname AS tbl, n_dead_tup, round(100*n_dead_tup::numeric/greatest(n_live_tup+n_dead_tup,1),2) AS dead_pct FROM pg_stat_user_tables WHERE n_dead_tup>1000 ORDER BY n_dead_tup DESC LIMIT 10;"

# === 主流程 ===
main() {
    echo "╔══════════════════════════════════════════╗"
    echo "║     GCP PostgreSQL 诊断 — $DB_NAME       ║"
    echo "║     Trace: ${HARNESS_TRACE_ID:0:12}      ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # 连接检查（带熔断器）
    local cb=$(circuit_breaker_check "db_$DB_NAME" 5 60)
    if [ "$(echo "$cb" | jq -r '.allowed')" != "true" ]; then
        local retry=$(echo "$cb" | jq -r '.retry_after')
        echo -e "${RED}[CIRCUIT OPEN]${NC} 数据库 $DB_NAME 熔断中，${retry}s 后可重试"
        harness_finish "blocked"
        exit 1
    fi

    echo -e "${BLUE}[INFO]${NC} 连接: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"

    # 带重试的连接
    if ! retry_with_backoff 3 1 10 "run_psql 'SELECT 1' 5 >/dev/null 2>&1"; then
        log_fail "无法连接到数据库（已重试3次）"
        audit_log "ERROR" "connection_failed" "host=$DB_HOST db=$DB_NAME"
        circuit_breaker_record "db_$DB_NAME" "false"
        harness_finish "fail"
        exit 1
    fi

    circuit_breaker_record "db_$DB_NAME" "true"
    log_pass "连接成功"

    # 按模式执行
    case "$MODE" in
        tables)
            echo -e "\n📋 用户表:"
            run_psql "SELECT schemaname||'.'||tablename AS tbl, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY schemaname, tablename;" 30
            ;;

        diagnose)
            echo -e "\n🔍 诊断报告"
            for title in "连接数" "长查询(>5s)" "锁等待" "表大小(Top20)" "缓存命中率" "未使用索引" "死元组(VACUUM)"; do
                echo -e "\n── ${title} ──"
                run_psql "${DIAGNOSE_QUERIES[$title]}" 15 || echo "  (查询不可用)"
            done

            # 阈值告警
            local cache_hit=$(run_psql "${DIAGNOSE_QUERIES[缓存命中率]}" 5 | grep -oP '\d+\.?\d*' | head -1 || echo "100")
            if (( $(echo "$cache_hit < 95" | bc -l) )); then
                echo -e "\n${YELLOW}[ALERT]${NC} 缓存命中率 ${cache_hit}% < 95% — 考虑增加 shared_buffers 或优化查询"
                audit_log "WARN" "low_cache_hit" "cache_hit_pct=$cache_hit"
            fi

            local dead_count=$(run_psql "${DIAGNOSE_QUERIES[死元组(VACUUM)]}" 5 | grep -c "|" || echo "0")
            if [ "$dead_count" -gt 5 ]; then
                echo -e "${YELLOW}[ALERT]${NC} $dead_count 个表有大量死元组 — 检查 autovacuum 配置"
                audit_log "WARN" "dead_tuples" "tables_with_dead=$dead_count"
            fi
            ;;

        monitor)
            echo "🔄 实时监控 (Ctrl+C 退出)"
            trap 'echo ""; harness_finish "stopped"; exit 0' INT
            while true; do
                clear
                echo "╔══════════════════════════════════════════════╗"
                echo "║  PostgreSQL 实时监控 — $DB_NAME ($(date '+%H:%M:%S')) ║"
                echo "╚══════════════════════════════════════════════╝"
                echo ""
                run_psql "SELECT state, count(*) FROM pg_stat_activity WHERE datname='$DB_NAME' GROUP BY state;" 5
                echo ""
                run_psql "SELECT pid, round(extract(epoch FROM now()-query_start))::int AS secs, LEFT(query,60) FROM pg_stat_activity WHERE state!='idle' AND now()-query_start > interval '1 second' AND datname='$DB_NAME' LIMIT 5;" 5
                sleep 5
            done
            ;;

        schema)
            [ -z "$SCHEMA_TABLE" ] && { echo "请指定表名: --schema <table>"; exit 1; }
            echo -e "\n📐 表结构: $SCHEMA_TABLE"
            echo -e "\n── 字段 ──"
            run_psql "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name='$SCHEMA_TABLE' ORDER BY ordinal_position;" 10
            echo -e "\n── 索引 ──"
            run_psql "SELECT indexname, indexdef FROM pg_indexes WHERE tablename='$SCHEMA_TABLE';" 10
            ;;

        query)
            [ -z "$QUERY" ] && { echo "请指定查询: --query <SQL>"; exit 1; }
            local sanitized=$(sanitize_pii "$QUERY")
            audit_log "INFO" "custom_query" "query_hash=$(echo "$QUERY" | md5 -q 2>/dev/null || echo 'N/A')"
            run_psql "$QUERY" 30
            ;;

        *) echo "请指定: --tables / --diagnose / --monitor / --schema / --query"; exit 1 ;;
    esac

    harness_finish "pass"
}

main "$@"
