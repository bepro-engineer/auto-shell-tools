#!/bin/sh
# ------------------------------------------------------------------
# it_manage_service_tomcat.sh
# IT for manage_service.sh (Tomcat)
#
# 判定：
#   - 終了コード(rc)
#   - systemd 実状態（active / inactive）
#   - LISTEN 確認（ss）
#   - HTTP 疎通（curl）
#
# 方針：
#   - 疑似 systemctl は使わない（実 systemd）
#   - 疑似 curl は使わない（実 curl）
#   - 排他制御はテスト項目から除外
#
# 前提（httpd 版との差分）：
#   - 対象サービスは systemd 管理下の Tomcat
#   - graceful / graceful-stop は存在しない前提
#   - httpd -t に相当する標準の設定検証コマンドは持たない
#     （設定妥当性チェックは原則スコープ外）
#   - 必要な場合のみ、外部コマンドを CONFIG_TEST_CMD で指定可能
#
# 実行例（必須指定）：
#   TOMCAT_SERVICE="tomcat9" TOMCAT_PORT="8080" TOMCAT_PATH="/" \
#   sh it_manage_service_tomcat.sh
#
# 任意（設定検証コマンド）：
#   CONFIG_TEST_CMD="test -f /opt/tomcat/conf/server.xml"（例）
# ------------------------------------------------------------------

cd "$(dirname "$0")" || exit 1

TARGET="./manage_service.sh"

# ------------------------------------------------------------------
# 必須パラメータ（未指定なら停止）
# ------------------------------------------------------------------
# デフォルト（未指定ならこれで動く）
TOMCAT_SERVICE="${TOMCAT_SERVICE:-tomcat9}"
TOMCAT_PORT="${TOMCAT_PORT:-8080}"
TOMCAT_PATH="${TOMCAT_PATH:-/}"

# 任意：設定テストコマンド（rc=0 を期待）
CONFIG_TEST_CMD="${CONFIG_TEST_CMD:-}"

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
# root 権限で実行されていることを保証する
assert_root() {
    [ "$(id -u)" -eq 0 ] || fatal "root で実行すること"
}

# 指定したコマンドが実行可能であることを保証する
assert_cmd() {
    cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fatal "$cmd が存在しない"
}

# テスト実行に必要な前提条件（ファイル・権限・コマンド・環境変数・unit）を一括検証する
assert_prereq() {
    [ -f "$TARGET" ] || fatal "manage_service.sh が見つからない（bin 配下で実行しているか確認）"
    [ -f "../com/utils.shrc" ] || fatal "../com/utils.shrc が存在しない"
    [ -f "../com/logger.shrc" ] || fatal "../com/logger.shrc が存在しない"

    assert_root
    assert_cmd systemctl
    assert_cmd ss
    assert_cmd curl

    [ -n "$TOMCAT_SERVICE" ] || fatal "TOMCAT_SERVICE を指定すること（例: tomcat9）"
    [ -n "$TOMCAT_PORT" ] || fatal "TOMCAT_PORT を指定すること（例: 8080）"
    [ -n "$TOMCAT_PATH" ] || fatal "TOMCAT_PATH を指定すること（例: / または /examples）"

    # unit 存在確認
    systemctl list-unit-files 2>/dev/null | grep -q "^${TOMCAT_SERVICE}\.service" || fatal "${TOMCAT_SERVICE}.service が存在しない"
}

# ------------------------------------------------------------
# 状態取得
# ------------------------------------------------------------
# systemd から対象サービスの実状態（active / inactive など）を取得する
get_state() {
    systemctl is-active "$TOMCAT_SERVICE" 2>/dev/null
}

# systemd が管理している対象サービスの MainPID を取得する
get_main_pid() {
    systemctl show -p MainPID "$TOMCAT_SERVICE" 2>/dev/null | awk -F= '{print $2}'
}

# ------------------------------------------------------------
# Tomcat 実体検証
# ------------------------------------------------------------
# 指定したポート（TOMCAT_PORT）で LISTEN していることを確認する
assert_listen_port() {
    # LISTEN :${TOMCAT_PORT}
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -E "(:${TOMCAT_PORT}$|\]:${TOMCAT_PORT}$)" >/dev/null 2>&1
}

# HTTP が応答していることを確認する（200–399 を成功とみなす）
assert_http_up() {
    # 200-399 を「応答あり」とみなす（301/302 の環境差を許容）
    code="$(curl -sS --max-time 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${TOMCAT_PORT}${TOMCAT_PATH}" 2>/dev/null)"
    case "$code" in
        2??|3??) return 0 ;;
    esac
    return 1
}

# HTTP が応答しないことを確認する（接続失敗を期待）
assert_http_down() {
    curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:${TOMCAT_PORT}${TOMCAT_PATH}" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ]
}

# 設定検証コマンド（CONFIG_TEST_CMD）が指定されている場合のみ実行し、成功可否を返す
run_config_test_if_set() {
    [ -n "$CONFIG_TEST_CMD" ] || return 0
    # shellcheck disable=SC2086
    sh -c "$CONFIG_TEST_CMD" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ]
}

# ------------------------------------------------------------
# テスト実行ラッパ
# -----------------------------------------------------------
# 指定した終了コードと実行結果の終了コードが一致するかを検証するテスト用関数-
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

    assert_listen_port || { ng "$name" "$rc"; return 0; }
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
echo "INTEGRATION TEST : manage_service.sh (tomcat)"
echo "========================================"
echo "SERVICE : ${TOMCAT_SERVICE}"
echo "PORT    : ${TOMCAT_PORT}"
echo "PATH    : ${TOMCAT_PATH}"

# ------------------------------------------------------------
# 0) 任意：設定テスト
# ------------------------------------------------------------
if run_config_test_if_set; then
    ok "P00 config test (CONFIG_TEST_CMD)"
else
    # CONFIG_TEST_CMD 未指定はOK扱い
    if [ -n "$CONFIG_TEST_CMD" ]; then
        ng "P00 config test (CONFIG_TEST_CMD)" 1
    else
        ok "P00 config test (CONFIG_TEST_CMD not set)"
    fi
fi

# ------------------------------------------------------------
# 1) 引数バリデーションテスト
#   不正・不足・異常な引数に対して rc=2 で終了することを確認
# ------------------------------------------------------------

# 引数なし → エラー
run_expect_eq "T01 no args"               2

# -s のみ指定（-c 不足）→ エラー
run_expect_eq "T02 -s only"               2 -s "$TOMCAT_SERVICE"

# -c のみ指定（-s 不足）→ エラー
run_expect_eq "T03 -c only"               2 -c start

# -s が空文字 → エラー
run_expect_eq "T04 -s empty"              2 -s ""

# -c が空文字 → エラー
run_expect_eq "T05 -c empty"              2 -c ""

# -s 正常 / -c 空文字 → エラー
run_expect_eq "T06 -s tomcat -c empty"    2 -s "$TOMCAT_SERVICE" -c ""

# -s 空文字 / -c 正常 → エラー
run_expect_eq "T07 -s empty -c start"     2 -s "" -c start

# 未定義コマンド指定 → エラー
run_expect_eq "T08 invalid command"       2 -s "$TOMCAT_SERVICE" -c dummy

# 未定義オプション指定 → エラー
run_expect_eq "T09 invalid option"        2 -x

# ------------------------------------------------------------
# 正常系引数（順序非依存）
# ------------------------------------------------------------

# -s / -c の指定順が逆でも正常に解釈されることを確認
run_expect_eq "T10 reverse order" 0 -c start -s "$TOMCAT_SERVICE"

# ------------------------------------------------------------
# 2) サービス操作の結合テスト
#   stop / start / restart / status を実行し、
#   状態・LISTEN・HTTP の「実体」で確認する
# ------------------------------------------------------------

# [前提] 停止中でも起動中でもよい
# [操作] stop
# [確認] inactive / HTTP down
run_expect_service_down "T20 stop" -s "$TOMCAT_SERVICE" -c stop

# [前提] 停止中
# [操作] start
# [確認] active / LISTEN / HTTP up
run_expect_service_up   "T21 start" -s "$TOMCAT_SERVICE" -c start

# [前提] 起動中
# [操作] start を再実行
# [確認] active 維持 / HTTP up（起動の冪等性）
run_expect_service_up   "T22 start again (idempotent)" -s "$TOMCAT_SERVICE" -c start

# [前提] 起動中
# [操作] status
# [確認] 状態変化なし / active
run_expect_eq_state     "T23 status (running)" 0 active -s "$TOMCAT_SERVICE" -c status

# [前提] 起動中
# [操作] restart
# [確認] active / HTTP up
pid_before="$(get_main_pid)"
run_expect_service_up   "T24 restart" -s "$TOMCAT_SERVICE" -c restart

# ------------------------------------------------------------
# T25: restart 実装の挙動観測（参考情報）
#   - MainPID が変わるかどうかを確認する
#   - PID 変化の有無は仕様としては扱わない
#   - テストの合否には影響させない
# ------------------------------------------------------------
pid_after="$(get_main_pid)"
if [ -n "$pid_before" ] && [ -n "$pid_after" ] &&
   [ "$pid_before" != "0" ] && [ "$pid_after" != "0" ] &&
   [ "$pid_before" != "$pid_after" ]; then
    ok "T25 restart changes MainPID (observed)"
else
    ok "T25 restart keeps MainPID (observed)"
fi

# [前提] restart 後に起動中
# [操作] stop
# [確認] inactive / HTTP down
run_expect_service_down "T26 stop after restart" -s "$TOMCAT_SERVICE" -c stop

# [前提] 停止中
# [操作] status
# [確認] 状態変化なし / inactive
run_expect_eq_state     "T27 status (stopped)" 0 inactive -s "$TOMCAT_SERVICE" -c status

# ------------------------------------------------------------
# 3) 異常系テスト
#   想定外入力・外部割り込みに対して「正しく失敗する」ことを確認する
# ------------------------------------------------------------

# 存在しないサービス名を指定した場合に、正常終了しないことを確認
run_expect_ne0 "T30 invalid service" -s dummy -c start

# 実行中に SIGINT（Ctrl+C 相当）を受けた場合に rc=2 で終了することを確認
(
    sh "$TARGET" -s "$TOMCAT_SERVICE" -c start >/dev/null 2>&1
) &
PID=$!
sleep 0.1
kill -INT "$PID" >/dev/null 2>&1
wait "$PID"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "T31 SIGINT"
else
    ng "T31 SIGINT" "$rc"
fi

echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]

