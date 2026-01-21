#!/bin/sh
# ------------------------------------------------------------------
# ファイル名　：it_manage_tomcat_app_full.sh
# 概要　　　　：manage_tomcat_app.sh 結合テスト（実Tomcat/実curl）
# 説明　　　　：
#   - 疑似curl（mock）は使わない
#   - 実Tomcat Manager(text API) を叩く
#   - 判定は「終了コード(rc)のみ」
#   - stdout/stderr/ログ内容は判定に使わない（※ログは見たければ手動で実行）
#
# 重要　　　　：
#   - start/stop は状態により rc が変わる（manage_tomcat_app.sh 実装仕様）
#       start : 0=開始成功 / 1=既にrunning / 2=失敗（notfound含む）
#       stop  : 0=停止成功 / 1=既にstopped または notfound / 2=失敗
#       restart : 0=成功 / 2=失敗（start が 2 の場合など）
#
# 実行　　　　：
#   BASE_URL / USER_NAME / USER_PASS / APP_PATH を必要に応じて上書きして実行
#   例）
#     BASE_URL="http://localhost:8080" USER_NAME="admin" USER_PASS="admin123" APP_PATH="/docs" sh it_manage_tomcat_app_full.sh
# ------------------------------------------------------------------

cd "$(dirname "$0")" || exit 1
TARGET="./manage_tomcat_app.sh"

# ------------------------------------------------------------------
# テスト対象環境（環境変数で上書き可能）
# ------------------------------------------------------------------
BASE_URL="${BASE_URL:-http://localhost:8080}"
USER_NAME="${USER_NAME:-admin}"
USER_PASS="${USER_PASS:-admin123}"
APP_PATH="${APP_PATH:-/docs}"

# notfound用
NOAPP_PATH="/__no_such_app__"

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

# ------------------------------------------------------------------
# run_expect_eq
#   $1 : テスト名
#   $2 : 期待rc
#   $3.. : manage_tomcat_app.sh に渡す引数（-b は自動付与）
# ------------------------------------------------------------------
run_expect_eq() {
    name="$1"
    expect="$2"
    shift 2

    sh "$TARGET" -b "$BASE_URL" "$@" >/dev/null 2>&1
    rc=$?

    if [ "$rc" -eq "$expect" ]; then
        ok "$name"
    else
        ng "$name" "$rc"
    fi
}

# ------------------------------------------------------------------
# 状態作り（rcの揺れを潰すための前処理）
#   ※ここは「テストではなく準備」扱い
# ------------------------------------------------------------------
ensure_running() {
    # 1回目：stoppedなら 0 / runningなら 1 / 失敗なら 2
    sh "$TARGET" -b "$BASE_URL" -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" >/dev/null 2>&1
    # 2回目：running を確定させる（running なら必ず 1 になる）
    sh "$TARGET" -b "$BASE_URL" -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" >/dev/null 2>&1
    return 0
}

ensure_stopped() {
    # 1回目：runningなら 0 / stopped(notfound含む)なら 1 / 失敗なら 2
    sh "$TARGET" -b "$BASE_URL" -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" >/dev/null 2>&1
    # 2回目：stopped を確定させる（stopped なら必ず 1 になる）
    sh "$TARGET" -b "$BASE_URL" -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" >/dev/null 2>&1
    return 0
}

# ------------------------------------------------------------------
# 一時ファイル作成（file系テスト用）
# ------------------------------------------------------------------
TMP_DIR="$(mktemp -d 2>/dev/null)"
[ -n "$TMP_DIR" ] || exit 1
trap 'rm -rf "$TMP_DIR"' 0 1 2 3 15

F_EMPTY="${TMP_DIR}/apps_empty.lst"
F_COMMENT="${TMP_DIR}/apps_comment.lst"
F_WARN_START="${TMP_DIR}/apps_warn_start.lst"
F_ERR_START="${TMP_DIR}/apps_err_start.lst"
F_WARN_STOP="${TMP_DIR}/apps_warn_stop.lst"
F_ERR_STOP="${TMP_DIR}/apps_err_stop.lst"
F_MIX_SPACE="${TMP_DIR}/apps_mix_space.lst"

: > "$F_EMPTY"
cat > "$F_COMMENT" <<EOF
# comment only
# another comment

EOF

# 先に running を作っておく（WARNING(1) を確実に出すため）
ensure_running

# start：既にrunningのパスを並べる → 各行が rc=1 → 合計 rc=1
cat > "$F_WARN_START" <<EOF
# start warning mixed (already running)
${APP_PATH}
${APP_PATH}
EOF

# start：notfound を混ぜる → rc_total は 2
cat > "$F_ERR_START" <<EOF
# start error mixed (notfound included)
${APP_PATH}
${NOAPP_PATH}
EOF

# stop：先に stopped を作っておく（WARNING(1) を確実に出すため）
ensure_stopped

# stop：既にstoppedのパスを並べる → 各行が rc=1 → 合計 rc=1
cat > "$F_WARN_STOP" <<EOF
# stop warning mixed (already stopped)
${APP_PATH}
${APP_PATH}
EOF

# stop：notfound を混ぜる → 各行の notfound は rc=1（stopApp仕様）なので rc_total は 1 になる
# ただし、ここは「ERROR(2) が混在しない」ケース。ERROR混在は restart/start で作る。
cat > "$F_ERR_STOP" <<EOF
# stop mixed with notfound (still WARNING total)
${APP_PATH}
${NOAPP_PATH}
EOF

# 空白や前後スペースの混在（normalizePath/trim 想定の確認）
cat > "$F_MIX_SPACE" <<EOF
# mixed spaces
  ${APP_PATH}  
${APP_PATH}
EOF

# ------------------------------------------------------------------
# ヘッダ
# ------------------------------------------------------------------
echo "========================================"
echo "INTEGRATION TEST : manage_tomcat_app.sh (full)"
echo "========================================"

# ==================================================================
# 1) 引数・オプションの異常系（Tomcat不要）
# ==================================================================
run_expect_eq "T01 no args" 2
run_expect_eq "T02 -c only" 2 -c list
run_expect_eq "T03 -u only" 2 -u "$USER_NAME"
run_expect_eq "T04 -p only" 2 -p "$USER_PASS"
run_expect_eq "T05 -c list -u only" 2 -c list -u "$USER_NAME"
run_expect_eq "T06 -c list -p only" 2 -c list -p "$USER_PASS"
run_expect_eq "T07 invalid command" 2 -c badcmd -u "$USER_NAME" -p "$USER_PASS"
run_expect_eq "T08 status without -a/-f" 2 -c status -u "$USER_NAME" -p "$USER_PASS"
run_expect_eq "T09 -a and -f together" 2 -c status -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" -f "$F_EMPTY"
run_expect_eq "T10 file not found" 2 -c status -u "$USER_NAME" -p "$USER_PASS" -f "${TMP_DIR}/no_such_file.lst"

# ==================================================================
# 2) list（実Tomcat）
# ==================================================================
run_expect_eq "T20 list" 0 -c list -u "$USER_NAME" -p "$USER_PASS"

# ==================================================================
# 3) status（実Tomcat）
#   ※このスクリプト仕様では「存在すれば 0 / 無ければ 1」
# ==================================================================
run_expect_eq "T30 status exists" 0 -c status -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"
run_expect_eq "T31 status notfound" 1 -c status -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# ==================================================================
# 4) start（状態別）
# ==================================================================
# stopped を作る → start は 0 を期待
ensure_stopped
run_expect_eq "T40 start from stopped" 0 -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# running を作る → start は 1 を期待（Already running）
ensure_running
run_expect_eq "T41 start when running" 1 -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# notfound → start は 2（Start failed）
run_expect_eq "T42 start notfound" 2 -c start -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# normalizePath（先頭 / なしでも動くか）
ensure_stopped
run_expect_eq "T43 start path without leading slash" 0 -c start -u "$USER_NAME" -p "$USER_PASS" -a "docs"

# ==================================================================
# 5) stop（状態別）
# ==================================================================
# running を作る → stop は 0 を期待
ensure_running
run_expect_eq "T50 stop from running" 0 -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# stopped を作る → stop は 1 を期待（Already stopped or notfound）
ensure_stopped
run_expect_eq "T51 stop when stopped" 1 -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# notfound → stop は 1（stopApp仕様）
run_expect_eq "T52 stop notfound" 1 -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# ==================================================================
# 6) restart（状態別）
# ==================================================================
# running → restart は 0 を期待
ensure_running
run_expect_eq "T60 restart when running" 0 -c restart -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# stopped → restart は 0 を期待（stop=1でもOK、start=0なら成功）
ensure_stopped
run_expect_eq "T61 restart when stopped" 0 -c restart -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# notfound → restart は 2（start が 2 になる）
run_expect_eq "T62 restart notfound" 2 -c restart -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# ==================================================================
# 7) file（processFile）
# ==================================================================
run_expect_eq "T70 file empty" 0 -c status -u "$USER_NAME" -p "$USER_PASS" -f "$F_EMPTY"
run_expect_eq "T71 file comment only" 0 -c status -u "$USER_NAME" -p "$USER_PASS" -f "$F_COMMENT"

# start：WARNING(1) 混在（already running のみ）
ensure_running
run_expect_eq "T72 file start warning mixed" 1 -c start -u "$USER_NAME" -p "$USER_PASS" -f "$F_WARN_START"

# start：ERROR(2) 混在（notfound を含める）
ensure_running
run_expect_eq "T73 file start error mixed" 2 -c start -u "$USER_NAME" -p "$USER_PASS" -f "$F_ERR_START"

# stop：WARNING(1) 混在（already stopped のみ）
ensure_stopped
run_expect_eq "T74 file stop warning mixed" 1 -c stop -u "$USER_NAME" -p "$USER_PASS" -f "$F_WARN_STOP"

# stop：notfound 混在（stopは 1 扱い）
ensure_stopped
run_expect_eq "T75 file stop notfound mixed" 1 -c stop -u "$USER_NAME" -p "$USER_PASS" -f "$F_ERR_STOP"

# 空白混在（パスの前後空白が混ざっても落ちないか）
ensure_running
run_expect_eq "T76 file mixed spaces start" 1 -c start -u "$USER_NAME" -p "$USER_PASS" -f "$F_MIX_SPACE"

# ==================================================================
# 8) 通信・認証
# ==================================================================
# 接続不可 → curl rc!=0 → 2
run_expect_eq "T80 curl failed (connect)" 2 -b "http://127.0.0.1:9" -c list -u "$USER_NAME" -p "$USER_PASS"

# 認証失敗について：
#   manage_tomcat_app.sh は curl の HTTP ステータスを見ていない（curl rc のみ）
#   そのため 401/403 でも curl rc は 0 になり得る。
#   ここは「現状仕様に合わせた期待値」で固定する。
run_expect_eq "T81 auth failed (current behavior)" 0 -c list -u "$USER_NAME" -p "__wrong_pass__"

# ------------------------------------------------------------------
# 結果
# ------------------------------------------------------------------
echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && exit 0
exit 1

