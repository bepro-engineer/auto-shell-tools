#!/bin/sh
# ut_manage_service_tomcat.sh
# UT for manage_service.sh (tomcat)
# 判定：終了コード(rc)のみ
# 前提が崩れている場合は FATAL で即停止（rc=1 連発の原因切り分け）

cd "$(dirname "$0")" || exit 1

TARGET="./manage_service.sh"
SERVICE="tomcat9"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    echo "[OK] $1"
}

ng() {
    FAIL=$((FAIL + 1))
    echo "[NG] $1 (rc=$2)"
}

fatal() {
    echo "[FATAL] $1"
    exit 1
}

run_expect_eq() {
    name="$1"
    expect="$2"
    shift 2
    sh "$TARGET" "$@" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$expect" ]; then
        ok "$name"
    else
        ng "$name" "$rc"
    fi
}

run_expect_ne0() {
    name="$1"
    shift 1
    sh "$TARGET" "$@" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "$name"
    else
        ng "$name" "$rc"
    fi
}

# ------------------------------------------------------------
# 前提チェック（ここが通らない限り UT は成立しない）
# ------------------------------------------------------------
[ -f "$TARGET" ] || fatal "manage_service.sh が見つからない（bin 配下で実行しているか確認）"

[ -f "../com/utils.shrc" ] || fatal "../com/utils.shrc が存在しない（ディレクトリ構造が崩れている）"
[ -f "../com/logger.shrc" ] || fatal "../com/logger.shrc が存在しない（ディレクトリ構造が崩れている）"

[ "$(id -u)" -eq 0 ] || fatal "root で実行すること"

command -v systemctl >/dev/null 2>&1 || fatal "systemctl が存在しない"
systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service" || fatal "${SERVICE}.service が存在しない"

echo "========================================"
echo "UNIT TEST : manage_service.sh (tomcat)"
echo "========================================"

# ------------------------------------------------------------
# 状態セット（UT 前提を作るための最小操作）
# ------------------------------------------------------------
ensure_running() {
    systemctl start "$SERVICE" >/dev/null 2>&1
    systemctl is-active --quiet "$SERVICE" || fatal "${SERVICE} を running にできない"
}

ensure_stopped() {
    systemctl stop "$SERVICE" >/dev/null 2>&1
    systemctl is-active --quiet "$SERVICE" && fatal "${SERVICE} を stopped にできない"
}

# ============================================================
# ① 引数テスト
# ============================================================
run_expect_eq "T01 no args"               2
run_expect_eq "T02 -s only"               2 -s "$SERVICE"
run_expect_eq "T03 -c only"               2 -c start
run_expect_eq "T04 -s empty"              2 -s ""
run_expect_eq "T05 -c empty"              2 -c ""
run_expect_eq "T06 -s tomcat -c empty"    2 -s "$SERVICE" -c ""
run_expect_eq "T07 -s empty -c start"     2 -s "" -c start
run_expect_eq "T08 invalid command"       2 -s "$SERVICE" -c dummy
run_expect_eq "T09 invalid option"        2 -x

run_expect_eq "T10 reverse order"          0 -c start -s "$SERVICE"

# ============================================================
# ② 正常系
# ============================================================
ensure_stopped
run_expect_eq "T11 start (stopped)"        0 -s "$SERVICE" -c start

ensure_running
run_expect_eq "T12 start (running)"        0 -s "$SERVICE" -c start

ensure_running
run_expect_eq "T13 stop (running)"         0 -s "$SERVICE" -c stop

ensure_stopped
run_expect_eq "T14 stop (stopped)"         0 -s "$SERVICE" -c stop

ensure_running
run_expect_eq "T15 restart (running)"      0 -s "$SERVICE" -c restart

ensure_stopped
run_expect_eq "T16 restart (stopped)"      0 -s "$SERVICE" -c restart

ensure_running
run_expect_eq "T17 status (running)"       0 -s "$SERVICE" -c status

ensure_stopped
run_expect_eq "T18 status (stopped)"       0 -s "$SERVICE" -c status

# ============================================================
# ③ 異常系
# ============================================================
run_expect_ne0 "T19 invalid service"       -s dummy -c start

(
    sh "$TARGET" -s "$SERVICE" -c start >/dev/null 2>&1
) &
PID=$!
sleep 0.1
kill -INT "$PID" >/dev/null 2>&1
wait "$PID"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "T20 SIGINT"
else
    ng "T20 SIGINT" "$rc"
fi

echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]

