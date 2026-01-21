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
# テスト前提条件として、対象アプリを「必ず running 状態」に揃えるための準備用関数
ensure_running() {
    # 1回目：stoppedなら 0 / runningなら 1 / 失敗なら 2
    sh "$TARGET" -b "$BASE_URL" -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" >/dev/null 2>&1
    # 2回目：running を確定させる（running なら必ず 1 になる）
    sh "$TARGET" -b "$BASE_URL" -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" >/dev/null 2>&1
    return 0
}

# テスト前提条件として、対象アプリを「必ず stopped 状態」に揃えるための準備用関数
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
# file 指定テスト用の一時ディレクトリと入力ファイル群を作成する準備処理
TMP_DIR="$(mktemp -d 2>/dev/null)"
[ -n "$TMP_DIR" ] || exit 1
trap 'rm -rf "$TMP_DIR"' 0 1 2 3 15

# -f（file指定）テスト用：アプリパス一覧ファイル群（空／コメントのみ／警告系／エラー系／空白混在）
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

# ------------------------------------------------------------
# 1) 引数バリデーションテスト
#    不正・不足・不正形式の引数に対して rc=2 で終了することを確認
# ------------------------------------------------------------

# 引数なし → エラー
run_expect_eq "T01 no args"               2

# -c のみ指定（認証情報不足）→ エラー
run_expect_eq "T02 -c only"               2 -c list

# -u のみ指定 → エラー
run_expect_eq "T03 -u only"               2 -u "$USER_NAME"

# -p のみ指定 → エラー
run_expect_eq "T04 -p only"               2 -p "$USER_PASS"

# -c list + -u のみ指定（パスワード不足）→ エラー
run_expect_eq "T05 -c list -u only"       2 -c list -u "$USER_NAME"

# -c list + -p のみ指定（ユーザー不足）→ エラー
run_expect_eq "T06 -c list -p only"       2 -c list -p "$USER_PASS"

# 未定義コマンド指定 → エラー
run_expect_eq "T07 invalid command"       2 -c badcmd -u "$USER_NAME" -p "$USER_PASS"

# status で -a / -f 未指定 → エラー
run_expect_eq "T08 status without path"   2 -c status -u "$USER_NAME" -p "$USER_PASS"

# -a と -f を同時指定 → エラー
run_expect_eq "T09 -a and -f together"    2 -c status -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH" -f "$F_EMPTY"

# -f 指定ファイルが存在しない → エラー
run_expect_eq "T10 file not found"         2 -c status -u "$USER_NAME" -p "$USER_PASS" -f "${TMP_DIR}/no_such_file.lst"

# ------------------------------------------------------------
# 2) list コマンド正常系テスト
#    正常な認証情報で list を実行した場合に rc=0 で終了することを確認
# ------------------------------------------------------------

# list 正常実行 → rc=0
run_expect_eq "T20 list"                  0 -c list -u "$USER_NAME" -p "$USER_PASS"

# ------------------------------------------------------------
# 3) status コマンドの結合テスト（実 Tomcat）
#    前提状態 → 操作 → 結果（rc）を確認
# ------------------------------------------------------------

# [前提] アプリは存在する
# [操作] status を実行
# [確認] rc=0（存在する）
run_expect_eq "T30 status on existing app" 0 -c status -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは存在しない
# [操作] status を実行
# [確認] rc=1（存在しない）
run_expect_eq "T31 status on notfound app"  1 -c status -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# ------------------------------------------------------------
# 4) start コマンドの結合テスト（状態別）
#    前提状態 → 操作 → 結果（rc）を確認
# ------------------------------------------------------------

# [前提] アプリは停止中
# [操作] start を実行
# [確認] rc=0（起動成功）
ensure_stopped
run_expect_eq "T40 start on stopped app"   0 -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは起動中
# [操作] start を再実行
# [確認] rc=1（既に起動中：冪等性）
ensure_running
run_expect_eq "T41 start on running app"   1 -c start -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは存在しない
# [操作] start を実行
# [確認] rc=2（起動失敗）
run_expect_eq "T42 start on notfound app"  2 -c start -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# [前提] アプリは停止中
# [操作] 先頭スラッシュなしのパスで start を実行
# [確認] rc=0（パス正規化が機能している）
ensure_stopped
run_expect_eq "T43 start without leading slash" 0 -c start -u "$USER_NAME" -p "$USER_PASS" -a "docs"

# ------------------------------------------------------------
# 5) stop コマンドの結合テスト（状態別）
#    前提状態 → 操作 → 結果（rc）を確認
# ------------------------------------------------------------

# [前提] アプリは起動中
# [操作] stop を実行
# [確認] rc=0（停止成功）
ensure_running
run_expect_eq "T50 stop on running app"    0 -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは停止中
# [操作] stop を再実行
# [確認] rc=1（既に停止中：冪等性）
ensure_stopped
run_expect_eq "T51 stop on stopped app"    1 -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは存在しない
# [操作] stop を実行
# [確認] rc=1（notfound は停止扱い）
run_expect_eq "T52 stop on notfound app"   1 -c stop -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# ------------------------------------------------------------
# 6) restart コマンドの結合テスト（状態別）
#    前提状態 → 操作 → 結果（rc）を確認
# ------------------------------------------------------------

# [前提] アプリは起動中
# [操作] restart を実行
# [確認] rc=0（再起動成功）
ensure_running
run_expect_eq "T60 restart on running app"  0 -c restart -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは停止中
# [操作] restart を実行
# [確認] rc=0（stop は 1 でも start が成功すれば成功）
ensure_stopped
run_expect_eq "T61 restart on stopped app"  0 -c restart -u "$USER_NAME" -p "$USER_PASS" -a "$APP_PATH"

# [前提] アプリは存在しない
# [操作] restart を実行
# [確認] rc=2（start 失敗）
run_expect_eq "T62 restart on notfound app" 2 -c restart -u "$USER_NAME" -p "$USER_PASS" -a "$NOAPP_PATH"

# ------------------------------------------------------------
# 7) file（-f）指定時の結合テスト
#    前提状態 → 操作 → 結果（rc）を確認
# ------------------------------------------------------------

# [前提] ファイルは空
# [操作] status を実行
# [確認] rc=0（対象なしでも正常終了）
run_expect_eq "T70 file empty"              0 -c status -u "$USER_NAME" -p "$USER_PASS" -f "$F_EMPTY"

# [前提] ファイルはコメント行のみ
# [操作] status を実行
# [確認] rc=0（コメントは無視され正常終了）
run_expect_eq "T71 file comment only"       0 -c status -u "$USER_NAME" -p "$USER_PASS" -f "$F_COMMENT"

# [前提] 対象アプリはすべて起動中
# [操作] start を実行（already running のみ）
# [確認] rc=1（WARNING のみ混在）
ensure_running
run_expect_eq "T72 file start warning mixed" 1 -c start -u "$USER_NAME" -p "$USER_PASS" -f "$F_WARN_START"

# [前提] 対象アプリに notfound を含む
# [操作] start を実行
# [確認] rc=2（ERROR が混在）
ensure_running
run_expect_eq "T73 file start error mixed"   2 -c start -u "$USER_NAME" -p "$USER_PASS" -f "$F_ERR_START"

# [前提] 対象アプリはすべて停止中
# [操作] stop を実行（already stopped のみ）
# [確認] rc=1（WARNING のみ混在）
ensure_stopped
run_expect_eq "T74 file stop warning mixed"  1 -c stop -u "$USER_NAME" -p "$USER_PASS" -f "$F_WARN_STOP"

# [前提] 対象アプリに notfound を含む
# [操作] stop を実行
# [確認] rc=1（notfound は停止扱い）
ensure_stopped
run_expect_eq "T75 file stop notfound mixed" 1 -c stop -u "$USER_NAME" -p "$USER_PASS" -f "$F_ERR_STOP"

# [前提] パスに前後空白が混在
# [操作] start を実行
# [確認] rc=1（正規化され already running 扱い）
ensure_running
run_expect_eq "T76 file mixed spaces start"  1 -c start -u "$USER_NAME" -p "$USER_PASS" -f "$F_MIX_SPACE"

# ------------------------------------------------------------
# 8) 通信・認証の結合テスト
#    前提状態 → 操作 → 結果（rc）を確認
# ------------------------------------------------------------

# [前提] 接続先が存在しない（接続不可）
# [操作] list を実行
# [確認] rc=2（curl 接続失敗）
run_expect_eq "T80 connect failed"          2 -b "http://127.0.0.1:9" -c list -u "$USER_NAME" -p "$USER_PASS"

# [前提] 認証情報が不正
# [操作] list を実行
# [確認] rc=0（HTTP ステータスは見ず、curl の終了コードのみで判定）
run_expect_eq "T81 auth failed"             0 -c list -u "$USER_NAME" -p "__wrong_pass__"

# ------------------------------------------------------------------
# 結果
# ------------------------------------------------------------------
echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && exit 0
exit 1

