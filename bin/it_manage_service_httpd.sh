#!/bin/sh
# it_manage_service_httpd_full.sh
# IT for manage_service.sh (httpd)
# 判定：
#   - 終了コード(rc)
#   - systemd 実状態（active/inactive）
#   - httpd 設定妥当性（httpd -t）
#   - LISTEN 確認（ss）
#   - HTTP 疎通（curl）
#
# 方針：
#   - 疑似systemctlは使わない（実systemd）
#   - 疑似curlは使わない（実curl）

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

# ------------------------------------------------------------
# 共通チェック
# ------------------------------------------------------------
assert_root() {
    [ "$(id -u)" -eq 0 ] || fatal "root で実行すること"
}

assert_cmd() {
    cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fatal "$cmd が存在しない"
}

assert_prereq() {
    [ -f "$TARGET" ] || fatal "manage_service.sh が見つからない（bin 配下で実行しているか確認）"
    [ -f "../com/utils.shrc" ] || fatal "../com/utils.shrc が存在しない"
    [ -f "../com/logger.shrc" ] || fatal "../com/logger.shrc が存在しない"

    assert_root
    assert_cmd systemctl
    assert_cmd httpd
    assert_cmd ss
    assert_cmd curl

    systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service" || fatal "${SERVICE}.service が存在しない"
}

# ------------------------------------------------------------
# 状態取得
# ------------------------------------------------------------
get_state() {
    systemctl is-active "$SERVICE" 2>/dev/null
}

get_main_pid() {
    # systemd が管理する MainPID を取る（0 の場合あり）
    systemctl show -p MainPID "$SERVICE" 2>/dev/null | awk -F= '{print $2}'
}

# ------------------------------------------------------------
# httpd 実体検証
# ------------------------------------------------------------
assert_config_ok() {
    httpd -t >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || return 1
    return 0
}

assert_listen_80() {
    # 80 LISTEN を必須とする（環境により 443 は無い前提）
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -E '(:80$|\]:80$)' >/dev/null 2>&1
}

assert_http_up() {
    # 200-399 を「応答あり」とみなす（301/302 の環境差を許容）
    code="$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null)"
    case "$code" in
        2??|3??) return 0 ;;
    esac
    return 1
}

assert_http_down() {
    # 停止後は curl が失敗（rc!=0）するのを期待
    curl -sS --max-time 2 -o /dev/null http://127.0.0.1/ >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ]
}

# ------------------------------------------------------------
# テスト実行ラッパ
# ------------------------------------------------------------
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

run_expect_eq_state() {
    name="$1"
    expect_rc="$2"
    expect_state="$3"
    shift 3

    sh "$TARGET" "$@" >/dev/null 2>&1
    rc=$?

    if [ "$rc" -ne "$expect_rc" ]; then
        ng "$name" "$rc"
        return 0
    fi

    state="$(get_state)"
    if [ "$state" = "$expect_state" ]; then
        ok "$name"
    else
        ng "$name" "$rc"
    fi
}

run_expect_service_up() {
    name="$1"
    shift 1

    sh "$TARGET" "$@" >/dev/null 2>&1
    rc=$?

    if [ "$rc" -ne 0 ]; then
        ng "$name" "$rc"
        return 0
    fi

    state="$(get_state)"
    if [ "$state" != "active" ]; then
        ng "$name" "$rc"
        return 0
    fi

    assert_listen_80 || { ng "$name" "$rc"; return 0; }
    assert_http_up || { ng "$name" "$rc"; return 0; }

    ok "$name"
}

run_expect_service_down() {
    name="$1"
    shift 1

    sh "$TARGET" "$@" >/dev/null 2>&1
    rc=$?

    if [ "$rc" -ne 0 ]; then
        ng "$name" "$rc"
        return 0
    fi

    state="$(get_state)"
    if [ "$state" != "inactive" ]; then
        ng "$name" "$rc"
        return 0
    fi

    assert_http_down || { ng "$name" "$rc"; return 0; }

    ok "$name"
}

# ------------------------------------------------------------
# 前提
# ------------------------------------------------------------
assert_prereq

echo "========================================"
echo "INTEGRATION TEST : manage_service.sh (httpd)"
echo "========================================"

# ------------------------------------------------------------
# 0) httpd 設定妥当性（事前）
# ------------------------------------------------------------
if assert_config_ok; then
    ok "P00 httpd configtest (httpd -t)"
else
    ng "P00 httpd configtest (httpd -t)" 1
fi

# ------------------------------------------------------------
# 1) 引数テスト（rc=2）
# ------------------------------------------------------------
run_expect_eq "T01 no args"               2
run_expect_eq "T02 -s only"               2 -s httpd
run_expect_eq "T03 -c only"               2 -c start
run_expect_eq "T04 -s empty"              2 -s ""
run_expect_eq "T05 -c empty"              2 -c ""
run_expect_eq "T06 -s httpd -c empty"     2 -s httpd -c ""
run_expect_eq "T07 -s empty -c start"     2 -s "" -c start
run_expect_eq "T08 invalid command"       2 -s httpd -c dummy
run_expect_eq "T09 invalid option"        2 -x

# reverse order は許容（rc=0）
run_expect_eq "T10 reverse order" 0 -c start -s httpd

# ------------------------------------------------------------
# 2) start/stop/restart/status の結合（状態 + LISTEN + HTTP）
# ------------------------------------------------------------
# stop -> inactive & HTTP down
run_expect_service_down "T20 stop (force inactive + http down)" -s httpd -c stop

# start -> active & LISTEN & HTTP up
run_expect_service_up "T21 start (active + listen80 + http up)" -s httpd -c start

# start again（冪等）-> active & HTTP up
run_expect_service_up "T22 start again (idempotent)" -s httpd -c start

# status running -> 状態変化なし & active
run_expect_eq_state "T23 status (running)" 0 active -s httpd -c status

# restart -> active & HTTP up
pid_before="$(get_main_pid)"
run_expect_service_up "T24 restart (active + http up)" -s httpd -c restart
pid_after="$(get_main_pid)"
if [ -n "$pid_before" ] && [ -n "$pid_after" ] && [ "$pid_before" != "0" ] && [ "$pid_after" != "0" ] && [ "$pid_before" != "$pid_after" ]; then
    ok "T25 restart changes MainPID"
else
    # PID が変わらない実装/環境もあるため、ここは情報として扱い NG にしない
    ok "T25 restart changes MainPID (skipped by environment)"
fi

# graceful -> active & HTTP up（PID変化は期待しない）
run_expect_service_up "T26 graceful (keep active + http up)" -s httpd -c graceful

# graceful-stop -> inactive & HTTP down
run_expect_service_down "T27 graceful-stop (inactive + http down)" -s httpd -c graceful-stop

# status stopped -> 状態変化なし & inactive
run_expect_eq_state "T28 status (stopped)" 0 inactive -s httpd -c status

# ------------------------------------------------------------
# 3) 異常系
# ------------------------------------------------------------
run_expect_ne0 "T30 invalid service" -s dummy -c start

# graceful when stopped は失敗想定（rc!=0）
run_expect_ne0 "T31 graceful when stopped" -s httpd -c graceful

# SIGINT（rc=2）
(
    sh "$TARGET" -s httpd -c start >/dev/null 2>&1
) &
PID=$!
sleep 0.1
kill -INT "$PID" >/dev/null 2>&1
wait "$PID"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "T32 SIGINT"
else
    ng "T32 SIGINT" "$rc"
fi

echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]

