#!/bin/sh
# ut_manage_service_httpd.sh
# UT for manage_service.sh (httpd)
# 判定：終了コード(rc)のみ
# 前提が崩れている場合は FATAL で即停止（rc=1 連発の原因切り分け）

cd "$(dirname "$0")" || exit 1

TARGET="./manage_service.sh"
SERVICE="httpd"

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

# com 配置前提（manage_service.sh は ../com を読む）
[ -f "../com/utils.shrc" ] || fatal "../com/utils.shrc が存在しない（ディレクトリ構造が崩れている）"
[ -f "../com/logger.shrc" ] || fatal "../com/logger.shrc が存在しない（ディレクトリ構造が崩れている）"

# root 実行前提（runAs で落ちると rc=1）
[ "$(id -u)" -eq 0 ] || fatal "root で実行すること"

# systemctl / httpd.service 前提
command -v systemctl >/dev/null 2>&1 || fatal "systemctl が存在しない"
systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service" || fatal "${SERVICE}.service が存在しない"

echo "========================================"
echo "UNIT TEST : manage_service.sh (httpd)"
echo "========================================"

# ------------------------------------------------------------
# 状態セット（テスト前提を作るために必要最小限）
# ------------------------------------------------------------
ensure_running() {
    systemctl start "$SERVICE" >/dev/null 2>&1
    systemctl is-active --quiet "$SERVICE" || fatal "${SERVICE} を running にできない（サービス側の不具合）"
}

ensure_stopped() {
    systemctl stop "$SERVICE" >/dev/null 2>&1
    systemctl is-active --quiet "$SERVICE" && fatal "${SERVICE} を stopped にできない（サービス側の不具合）"
}

# ============================================================
# ① 引数テスト（全パターン）
# 期待値は「実装事実」に合わせる：ここが rc=1 なら前提崩壊
# ============================================================
run_expect_eq "T01 no args"               2
run_expect_eq "T02 -s only"               2 -s httpd
run_expect_eq "T03 -c only"               2 -c start
run_expect_eq "T04 -s empty"              2 -s ""
run_expect_eq "T05 -c empty"              2 -c ""
run_expect_eq "T06 -s httpd -c empty"     2 -s httpd -c ""
run_expect_eq "T07 -s empty -c start"     2 -s "" -c start
run_expect_eq "T08 invalid command"       2 -s httpd -c dummy
run_expect_eq "T09 invalid option"        2 -x

# reverse order は実装上 OK（rc=0）
run_expect_eq "T10 reverse order" 0 -c start -s httpd

# ============================================================
# ② 正常系（状態を作ってから叩く）
# ============================================================
ensure_stopped
run_expect_eq "T11 start (stopped)"       0 -s httpd -c start

ensure_running
run_expect_eq "T12 start (running)"       0 -s httpd -c start

ensure_running
run_expect_eq "T13 stop (running)"        0 -s httpd -c stop

ensure_stopped
run_expect_eq "T14 stop (stopped)"        0 -s httpd -c stop

ensure_running
run_expect_eq "T15 restart (running)"     0 -s httpd -c restart

ensure_stopped
run_expect_eq "T16 restart (stopped)"     0 -s httpd -c restart

ensure_running
run_expect_eq "T17 status (running)"      0 -s httpd -c status

ensure_stopped
run_expect_eq "T18 status (stopped)"      0 -s httpd -c status

ensure_running
run_expect_eq "T19 graceful (running)"    0 -s httpd -c graceful

ensure_stopped
run_expect_eq "T20 graceful-stop (stopped)" 0 -s httpd -c graceful-stop

# ============================================================
# ③ 異常系
# ============================================================
ensure_stopped
run_expect_ne0 "T21 graceful when stopped" -s httpd -c graceful

ensure_stopped
run_expect_eq "T22 double graceful-stop"  0 -s httpd -c graceful-stop

run_expect_ne0 "T23 invalid service"      -s dummy -c start

# SIGINT（実装が 2 を返す想定。rc=1 なら前提崩壊）
(
    sh "$TARGET" -s httpd -c start >/dev/null 2>&1
) &
PID=$!
sleep 0.1
kill -INT "$PID" >/dev/null 2>&1
wait "$PID"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "T24 SIGINT"
else
    ng "T24 SIGINT" "$rc"
fi

echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]

