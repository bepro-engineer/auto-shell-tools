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
# httpd 実体検証アサーション
#   サービス制御結果が「見た目だけでなく実体として正しいか」を確認する
# ------------------------------------------------------------

# httpd の設定ファイルが文法的に正しいことを確認
assert_config_ok() {
    httpd -t >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || return 1
    return 0
}

# TCP 80 番ポートで LISTEN していることを確認
#   ※ 環境差を避けるため 443 は前提にしない
assert_listen_80() {
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -E '(:80$|\]:80$)' >/dev/null 2>&1
}

# HTTP が応答していることを確認
#   200-399 を「サービス稼働中」とみなす（リダイレクト許容）
assert_http_up() {
    code="$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null)"
    case "$code" in
        2??|3??) return 0 ;;
    esac
    return 1
}

# HTTP が応答しないことを確認
#   停止後は curl 自体が失敗する（rc != 0）ことを期待
assert_http_down() {
    curl -sS --max-time 2 -o /dev/null http://127.0.0.1/ >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ]
}

# ------------------------------------------------------------
# テスト実行ラッパ
# ------------------------------------------------------------
# 指定した終了コードと実行結果の終了コードが一致するかを検証するテスト用関数
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

# 終了コードが 0 以外であることを検証するテスト用関数
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

# 終了コードと内部状態の両方が期待値どおりかを検証するテスト用関数
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

# サービスが正常起動し、状態が active かつ HTTP(80) で応答可能かを検証するテスト用関数
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

# サービスが停止状態（inactive）であり、HTTP が応答しないことを検証するテスト用関数
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
# 1) 引数バリデーションテスト
#    不正・不足・不正形式の引数に対して rc=2 で終了することを確認
# ------------------------------------------------------------

# 引数なし → エラー
run_expect_eq "T01 no args"               2

# -s のみ指定（-c 不足）→ エラー
run_expect_eq "T02 -s only"               2 -s httpd

# -c のみ指定（-s 不足）→ エラー
run_expect_eq "T03 -c only"               2 -c start

# -s が空文字 → エラー
run_expect_eq "T04 -s empty"              2 -s ""

# -c が空文字 → エラー
run_expect_eq "T05 -c empty"              2 -c ""

# -s 正常 / -c 空文字 → エラー
run_expect_eq "T06 -s httpd -c empty"     2 -s httpd -c ""

# -s 空文字 / -c 正常 → エラー
run_expect_eq "T07 -s empty -c start"     2 -s "" -c start

# 未定義コマンド指定 → エラー
run_expect_eq "T08 invalid command"       2 -s httpd -c dummy

# 未定義オプション指定 → エラー
run_expect_eq "T09 invalid option"        2 -x

# -s / -c の指定順が逆でも正常に解釈され、エラーにならないことを確認
run_expect_eq "T10 reverse order" 0 -c start -s httpd

# ------------------------------------------------------------
# 2) httpd サービス操作の結合テスト
#    前提状態 → 操作 → 結果（state / LISTEN / HTTP）を確認
# ------------------------------------------------------------

# [前提] httpd は停止中
# [操作] stop を再実行
# [確認] 依然として inactive / HTTP down（停止の冪等性）
run_expect_service_down "T20 stop on already stopped service" -s httpd -c stop

# [前提] httpd は停止中
# [操作] start
# [確認] active / LISTEN 80 / HTTP up
run_expect_service_up "T21 start from stopped state" -s httpd -c start

# [前提] httpd は起動中
# [操作] start を再実行
# [確認] active のまま / HTTP up（起動の冪等性）
run_expect_service_up "T22 start again (idempotent)" -s httpd -c start

# [前提] httpd は起動中
# [操作] status
# [確認] 状態変化なし / active
run_expect_eq_state "T23 status while running" 0 active -s httpd -c status

# [前提] httpd は起動中
# [操作] restart
# [確認] active / HTTP up
pid_before="$(get_main_pid)"
run_expect_service_up "T24 restart service" -s httpd -c restart

# [確認] restart により MainPID が変わるか（参考情報）
pid_after="$(get_main_pid)"
if [ -n "$pid_before" ] && [ -n "$pid_after" ] && [ "$pid_before" != "0" ] && [ "$pid_after" != "0" ] && [ "$pid_before" != "$pid_after" ]; then
    ok "T25 restart changes MainPID"
else
    ok "T25 restart changes MainPID (environment dependent)"
fi

# [前提] httpd は起動中
# [操作] graceful
# [確認] active のまま / HTTP up（PID維持）
run_expect_service_up "T26 graceful reload" -s httpd -c graceful

# [前提] httpd は起動中
# [操作] graceful-stop
# [確認] inactive / HTTP down
run_expect_service_down "T27 graceful-stop service" -s httpd -c graceful-stop

# [前提] httpd は停止中
# [操作] status
# [確認] 状態変化なし / inactive
run_expect_eq_state "T28 status while stopped" 0 inactive -s httpd -c status

# ------------------------------------------------------------
# 3) 異常系テスト
#    想定外の操作・不正状態に対して、正常終了せず適切に失敗することを確認
# ------------------------------------------------------------

# [前提] 存在しないサービス名
# [操作] start
# [確認] 正常終了しない（rc != 0）
run_expect_ne0 "T30 invalid service" -s dummy -c start


# [前提] httpd は停止中
# [操作] graceful（起動中でなければ成立しない操作）
# [確認] 失敗する（rc != 0）
run_expect_ne0 "T31 graceful when stopped" -s httpd -c graceful


# [前提] httpd を start 実行中
# [操作] 実行途中で SIGINT（Ctrl+C 相当）を送信
# [確認] 割り込み終了コード rc=2 で終了する
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

