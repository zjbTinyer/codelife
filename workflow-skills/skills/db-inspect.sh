#!/bin/bash
# ============================================================
# db-inspect.sh — GCP PostgreSQL 诊断工具 (Harness 增强版)
# ============================================================
# 连接方式:
#   1. Service Account Key (推荐):
#      db-inspect.sh --gcp-instance proj:region:db --gcp-key ~/.gcp-keys/proj-sa.json --db mydb --diagnose
#
#   2. 自动查找 key 目录下的匹配文件:
#      ls ~/.gcp-keys/
#        project-a-db.json    → --gcp-instance project-a:asia:pg 时自动匹配
#        project-b-db.json
#
#   3. Proxy 已经在跑:
#      db-inspect.sh --db mydb --no-proxy --diagnose
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness-utils.sh"

harness_init "db-inspect"

# === 配置 ===
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME=""
QUERY=""
MODE=""
SCHEMA_TABLE=""
GCP_INSTANCE="${GCP_INSTANCE:-}"
GCP_KEY="${GCP_KEY:-}"                         # 单个 SA key 路径
GCP_KEY_DIR="${GCP_KEY_DIR:-$HOME/.gcp-keys}" # SA key 存放目录
AUTO_PROXY="${AUTO_PROXY:-true}"
PROXY_PID=""
GCP_IAM_AUTH="${GCP_IAM_AUTH:-false}"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) DB_NAME="$2"; shift 2 ;;
        --host) DB_HOST="$2"; shift 2 ;;
        --port) DB_PORT="$2"; shift 2 ;;
        --user) DB_USER="$2"; shift 2 ;;
        --password) DB_PASSWORD="$2"; shift 2 ;;
        --gcp-instance) GCP_INSTANCE="$2"; shift 2 ;;
        --gcp-key) GCP_KEY="$2"; shift 2 ;;
        --gcp-key-dir) GCP_KEY_DIR="$2"; shift 2 ;;
        --list-keys) MODE="list_keys"; shift ;;
        --gcp-iam-auth) GCP_IAM_AUTH=true; shift ;;
        --no-proxy) AUTO_PROXY=false; shift ;;
        --tables) MODE="tables"; shift ;;
        --diagnose) MODE="diagnose"; shift ;;
        --monitor) MODE="monitor"; shift ;;
        --schema) MODE="schema"; SCHEMA_TABLE="$2"; shift 2 ;;
        --query) MODE="query"; QUERY="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# === 列出可用的 SA Key ===
list_sa_keys() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  本地 Service Account Key 文件           ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    if [ -d "$GCP_KEY_DIR" ]; then
        for f in "$GCP_KEY_DIR"/*.json; do
            [ -f "$f" ] || continue
            local project=$(jq -r '.project_id // "unknown"' "$f" 2>/dev/null)
            local email=$(jq -r '.client_email // "unknown"' "$f" 2>/dev/null)
            local created=$(stat -f "%Sm" "$f" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d' ' -f1)
            local size=$(du -h "$f" | cut -f1)
            echo "  📄 $(basename "$f")"
            echo "     Project: $project  |  SA: $email"
            echo "     Size: $size  |  Modified: $created"
            echo ""
        done
    else
        echo "  目录不存在: $GCP_KEY_DIR"
        echo "  请创建目录并把 SA key JSON 文件放进去:"
        echo "    mkdir -p $GCP_KEY_DIR"
        echo "    cp /path/to/service-account-key.json $GCP_KEY_DIR/"
        echo ""
        echo "  或直接指定 key 文件:"
        echo "    --gcp-key /path/to/service-account-key.json"
    fi
}

# === 自动匹配 SA Key ===
resolve_gcp_key() {
    # 优先级: 1) --gcp-key 指定  2) GCP_KEY 环境变量  3) 自动匹配
    if [ -n "$GCP_KEY" ] && [ -f "$GCP_KEY" ]; then
        echo -e "${GREEN}[INFO]${NC} SA Key: $(basename "$GCP_KEY")"
        return 0
    fi

    if [ -z "$GCP_INSTANCE" ]; then
        return 0  # 不是 GCP 模式
    fi

    if [ ! -d "$GCP_KEY_DIR" ]; then
        echo -e "${YELLOW}[WARN]${NC} SA key 目录不存在: $GCP_KEY_DIR"
        echo "  创建目录并放入 key 文件: mkdir -p $GCP_KEY_DIR"
        echo "  或指定: --gcp-key /path/to/key.json"
        return 1
    fi

    # 从 GCP_INSTANCE 提取 project ID (格式: project:region:instance)
    local proj_id="${GCP_INSTANCE%%:*}"

    # 先精确匹配: key 文件名包含 project ID
    local match=$(find "$GCP_KEY_DIR" -maxdepth 1 -name "*${proj_id}*" -name "*.json" 2>/dev/null | head -1)

    # 如果没匹配到，逐个检查 key 文件内部的 project_id
    if [ -z "$match" ]; then
        for f in "$GCP_KEY_DIR"/*.json; do
            [ -f "$f" ] || continue
            local file_proj=$(jq -r '.project_id // ""' "$f" 2>/dev/null)
            if [ "$file_proj" = "$proj_id" ]; then
                match="$f"
                break
            fi
        done
    fi

    # 如果还没匹配到，用目录下第一个 key
    if [ -z "$match" ]; then
        match=$(find "$GCP_KEY_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | head -1)
    fi

    if [ -n "$match" ]; then
        GCP_KEY="$match"
        local proj=$(jq -r '.project_id // "?"' "$GCP_KEY" 2>/dev/null)
        echo -e "${GREEN}[INFO]${NC} 自动匹配 SA Key: $(basename "$GCP_KEY") (project=$proj)"
        return 0
    fi

    echo -e "${RED}[ERROR]${NC} 未找到匹配的 SA Key"
    echo "  GCP Instance: $GCP_INSTANCE (project: $proj_id)"
    echo "  Key 目录: $GCP_KEY_DIR"
    echo "  解决: --gcp-key /path/to/sa-key.json 或运行 --list-keys 查看"
    return 1
}

# === GCP Cloud SQL Proxy 管理 ===
cleanup_proxy() {
    if [ -n "${PROXY_PID:-}" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        echo -e "\n${BLUE}[INFO]${NC} 关闭 Cloud SQL Proxy (pid=$PROXY_PID)..."
        kill "$PROXY_PID" 2>/dev/null
        wait "$PROXY_PID" 2>/dev/null
    fi
}
trap cleanup_proxy EXIT

setup_gcp_connection() {
    if [ -z "$GCP_INSTANCE" ]; then
        GCP_INSTANCE="${CLOUD_SQL_INSTANCE:-}"
        [ -z "$GCP_INSTANCE" ] && { audit_log "INFO" "connection_mode" "direct"; return 0; }
    fi

    # 解析 SA Key
    if ! resolve_gcp_key; then
        exit 1
    fi

    audit_log "INFO" "connection_mode" "gcp instance=$GCP_INSTANCE key=$(basename "${GCP_KEY:-none}")"

    # 检查 cloud-sql-proxy
    if ! command -v cloud-sql-proxy &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} 未找到 cloud-sql-proxy"
        echo "  安装: brew install cloud-sql-proxy"
        exit 1
    fi

    # 端口复用：如果已有 Proxy 在目标端口上，直接用
    if lsof -i ":$DB_PORT" -sTCP:LISTEN &>/dev/null; then
        echo -e "${GREEN}[INFO]${NC} 端口 $DB_PORT 已有 Proxy 运行，复用"
        audit_log "INFO" "proxy_reuse" "port=$DB_PORT"
        return 0
    fi

    # 启动 Proxy
    local proxy_port="${PROXY_PORT:-$DB_PORT}"
    echo -e "${BLUE}[INFO]${NC} 启动 Cloud SQL Proxy: $GCP_INSTANCE → localhost:$proxy_port"

    if [ -n "$GCP_KEY" ] && [ -f "$GCP_KEY" ]; then
        cloud-sql-proxy --credentials-file "$GCP_KEY" --port "$proxy_port" "$GCP_INSTANCE" &
    else
        cloud-sql-proxy --port "$proxy_port" "$GCP_INSTANCE" &
    fi
    PROXY_PID=$!

    # 等待就绪
    echo -ne "${BLUE}[INFO]${NC} 等待 Proxy 就绪"
    for i in $(seq 1 15); do
        if lsof -i ":$proxy_port" -sTCP:LISTEN &>/dev/null; then
            echo " ✅"
            DB_HOST="localhost"
            DB_PORT="$proxy_port"
            audit_log "INFO" "proxy_ready" "instance=$GCP_INSTANCE port=$proxy_port pid=$PROXY_PID"
            return 0
        fi
        sleep 1; echo -n "."
    done

    echo -e " ${RED}超时${NC}"
    kill "$PROXY_PID" 2>/dev/null || true
    exit 1
}

setup_gcp_auth() {
    [ "${GCP_IAM_AUTH:-false}" != "true" ] && return 0
    if ! command -v gcloud &>/dev/null; then return 0; fi

    # 用 SA Key 认证
    if [ -n "${GCP_KEY:-}" ] && [ -f "$GCP_KEY" ]; then
        gcloud auth activate-service-account --key-file="$GCP_KEY" --quiet 2>/dev/null || true
    fi

    local iam_user=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    if [ -n "$iam_user" ]; then
        DB_USER="${iam_user//@/_at_}"; DB_USER="${DB_USER//./_dot_}"
        DB_PASSWORD=$(gcloud auth print-access-token 2>/dev/null || echo "")
        [ -n "$DB_PASSWORD" ] && echo -e "${GREEN}[INFO]${NC} GCP IAM 认证: $iam_user"
    fi
}

# === psql 执行（只读）===
run_psql() {
    local sql="$1" timeout="${2:-10}"
    local sql_upper=$(echo "$sql" | tr '[:lower:]' '[:upper:]')
    if ! [[ "$sql_upper" =~ ^SELECT|^EXPLAIN|^SHOW|^\\d ]]; then
        audit_log "WARN" "sql_blocked" "${sql:0:100}"
        echo "[BLOCKED] 仅允许只读查询"
        return 1
    fi
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "$sql" --no-align --field-separator=" | " -v ON_ERROR_STOP=1 2>&1
}

# === 诊断查询 ===
declare -A DIAGNOSE_QUERIES
DIAGNOSE_QUERIES["连接数"]="SELECT count(*) FILTER (WHERE state='active') AS active, count(*) FILTER (WHERE state='idle') AS idle, count(*) FILTER (WHERE state='idle in transaction') AS idle_xact FROM pg_stat_activity WHERE datname='$DB_NAME';"
DIAGNOSE_QUERIES["长查询(>5s)"]="SELECT pid, now()-query_start AS duration, state, LEFT(query,80) FROM pg_stat_activity WHERE state!='idle' AND now()-query_start>interval'5 seconds' AND datname='$DB_NAME' LIMIT 10;"
DIAGNOSE_QUERIES["锁等待"]="SELECT blocked_locks.pid AS blocked, blocking_locks.pid AS blocking FROM pg_catalog.pg_locks bl JOIN pg_catalog.pg_locks blk ON blk.locktype=bl.locktype AND blk.pid!=bl.pid JOIN pg_catalog.pg_stat_activity ba ON ba.pid=blk.pid WHERE NOT bl.granted LIMIT 10;"
DIAGNOSE_QUERIES["表大小(Top20)"]="SELECT schemaname||'.'||tablename AS tbl, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_stat_user_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 20;"
DIAGNOSE_QUERIES["缓存命中率"]="SELECT round(sum(heap_blks_hit)*100.0/greatest(sum(heap_blks_hit)+sum(heap_blks_read),1),2) AS cache_pct FROM pg_statio_user_tables;"
DIAGNOSE_QUERIES["未使用索引"]="SELECT schemaname||'.'||relname AS tbl, indexrelname AS idx, pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan FROM pg_stat_user_indexes WHERE idx_scan<10 AND indexrelname NOT LIKE '%pkey%' ORDER BY pg_relation_size(indexrelid) DESC LIMIT 10;"
DIAGNOSE_QUERIES["死元组"]="SELECT schemaname||'.'||relname AS tbl, n_dead_tup, round(100*n_dead_tup::numeric/greatest(n_live_tup+n_dead_tup,1),2) AS dead_pct FROM pg_stat_user_tables WHERE n_dead_tup>1000 ORDER BY n_dead_tup DESC LIMIT 10;"

# === 主流程 ===
main() {
    # --list-keys 模式（不需要连数据库）
    if [ "$MODE" = "list_keys" ]; then
        list_sa_keys
        harness_finish "pass"
        exit 0
    fi

    [ -z "$DB_NAME" ] && { echo "用法: db-inspect.sh --db <数据库名> [--tables|--diagnose|--monitor|--schema|--query] [--gcp-instance ...]"; exit 1; }

    # GCP 连接设置
    if [ "$AUTO_PROXY" = "true" ]; then
        setup_gcp_connection
    fi
    setup_gcp_auth

    echo "╔══════════════════════════════════════════╗"
    echo "║     GCP PostgreSQL 诊断 — $DB_NAME       ║"
    echo "║     Host: $DB_HOST:$DB_PORT              ║"
    [ -n "$GCP_INSTANCE" ] && echo "║     GCP: $GCP_INSTANCE"
    echo "║     Trace: ${HARNESS_TRACE_ID:0:12}      ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # 连接检查（带熔断器）
    local cb=$(circuit_breaker_check "db_$DB_NAME" 5 60)
    if [ "$(echo "$cb" | jq -r '.allowed')" != "true" ]; then
        echo -e "${RED}[CIRCUIT OPEN]${NC} 数据库 $DB_NAME 熔断中"
        harness_finish "blocked"; exit 1
    fi

    if ! retry_with_backoff 3 1 10 "run_psql 'SELECT 1' 5 >/dev/null 2>&1"; then
        log_fail "无法连接到数据库（已重试3次）"
        echo "  排查: 1) Proxy 是否正常  2) DB_USER/DB_PASSWORD 是否正确"
        echo "        3) GCP 实例名是否正确  4) SA Key 是否有 Cloud SQL Client 权限"
        circuit_breaker_record "db_$DB_NAME" "false"
        harness_finish "fail"; exit 1
    fi
    circuit_breaker_record "db_$DB_NAME" "true"
    log_pass "连接成功"

    # 按模式执行
    case "$MODE" in
        tables)
            run_psql "SELECT schemaname||'.'||tablename AS tbl, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY schemaname, tablename;" 30
            ;;
        diagnose)
            for title in "连接数" "长查询(>5s)" "锁等待" "表大小(Top20)" "缓存命中率" "未使用索引" "死元组"; do
                echo -e "\n── ${title} ──"
                run_psql "${DIAGNOSE_QUERIES[$title]}" 15 || echo "  (不可用)"
            done
            local cache_hit=$(run_psql "${DIAGNOSE_QUERIES[缓存命中率]}" 5 | grep -oP '\d+\.?\d*' | head -1 || echo "100")
            if (( $(echo "$cache_hit < 95" | bc -l) )); then
                echo -e "\n${YELLOW}[ALERT]${NC} 缓存命中率 ${cache_hit}% < 95%"
                audit_log "WARN" "low_cache_hit" "pct=$cache_hit"
            fi
            ;;
        monitor)
            trap 'echo ""; harness_finish "stopped"; exit 0' INT
            while true; do
                clear
                echo "╔══════════════════════════════════════════════╗"
                echo "║  PG 实时监控 — $DB_NAME ($(date '+%H:%M:%S')) ║"
                echo "╚══════════════════════════════════════════════╝"
                run_psql "SELECT state, count(*) FROM pg_stat_activity WHERE datname='$DB_NAME' GROUP BY state;" 5
                sleep 5
            done
            ;;
        schema)
            [ -z "$SCHEMA_TABLE" ] && { echo "请指定 --schema <table>"; exit 1; }
            run_psql "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name='$SCHEMA_TABLE' ORDER BY ordinal_position;" 10
            ;;
        query)
            [ -z "$QUERY" ] && { echo "请指定 --query <SQL>"; exit 1; }
            run_psql "$QUERY" 30
            ;;
        *) echo "请指定: --tables / --diagnose / --monitor / --schema / --query / --list-keys"; exit 1 ;;
    esac

    harness_finish "pass"
}

main "$@"
