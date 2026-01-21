#!/bin/sh
# ut_manage_tomcat_app.sh
# UT for manage_tomcat_app.sh (Tomcat Manager text API)
# 判定：終了コード(rc)のみ
# 方針：実Tomcatは叩かない（curl を PATH 差し替えで mock）

cd "$(dirname "$0")" || exit 1

TARGET="./manage_tomcat_app.sh"

PASS=0
FAIL=0

TMP_DIR=""
MOCK_BIN=""

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

setup_mock() {
    TMP_DIR="$(mktemp -d 2>/dev/null)"
    [ -n "$TMP_DIR" ] || fatal "mktemp に失敗"

    MOCK_BIN="${TMP_DIR}/mockbin"
    mkdir -p "$MOCK_BIN" || fatal "mockbin 作成に失敗"

    cat > "${MOCK_BIN}/curl" <<'MOCK'
#!/bin/sh
# mock curl for manage_tomcat_app.sh

# 返却制御
# - MOCK_CURL_RC      : curl の終了コード（未指定なら 0）
# - MOCK_SLEEP_SEC    : 指定秒 sleep（SIGINT テスト用）
# - MOCK_LIST_OUT     : /manager/text/list の本文
# - MOCK_START_OUT    : /manager/text/start の本文
# - MOCK_STOP_OUT     : /manager/text/stop の本文

rc="${MOCK_CURL_RC:-0}"

# SIGINT 用にわざと待つ
if [ -n "${MOCK_SLEEP_SEC:-}" ]; then
    sleep "${MOCK_SLEEP_SEC}" >/dev/null 2>&1
fi

# rc != 0 の場合は即失敗（本文は不要）
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

# 最後の引数を URL とみなす（manage_tomcat_app.sh は curl ... "$url" の形）
url="${!#}"

case "$url" in
    */manager/text/list*)
        printf "%s\n" "${MOCK_LIST_OUT:-OK}"
        exit 0
        ;;
    */manager/text/start*|*/manager/text/start\?path=*)
        printf "%s\n" "${MOCK_START_OUT:-OK}"
        exit 0
        ;;
    */manager/text/stop*|*/manager/text/stop\?path=*)
        printf "%s\n" "${MOCK_STOP_OUT:-OK}"
        exit 0
        ;;
    *)
        # 想定外 URL
        printf "%s\n" "${MOCK_OTHER_OUT:-OK}"
        exit 0
        ;;
esac
MOCK

    chmod +x "${MOCK_BIN}/curl" || fatal "mock curl の chmod に失敗"
}

teardown_mock() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" >/dev/null 2>&1
    fi
}

run_expect_eq() {
    name="$1"
    expect="$2"
    shift 2

    # shellcheck disable=SC2039
    PATH="${MOCK_BIN}:$PATH" \
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

    PATH="${MOCK_BIN}:$PATH" \
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
[ -f "$TARGET" ] || fatal "manage_tomcat_app.sh が見つからない（bin 配下で実行しているか確認）"

# com 配置前提（manage_tomcat_app.sh は ../com を読む）
[ -f "../com/utils.shrc" ] || fatal "../com/utils.shrc が存在しない（ディレクトリ構造が崩れている）"
[ -f "../com/logger.shrc" ] || fatal "../com/logger.shrc が存在しない（ディレクトリ構造が崩れている）"

# root 実行前提（runAs で落ちると rc が揺れる）
[ "$(id -u)" -eq 0 ] || fatal "root で実行すること"

setup_mock

echo "========================================"
echo "UNIT TEST : manage_tomcat_app.sh (tomcat)"
echo "========================================"

# ============================================================
# ① 引数テスト（実装事実：usage -> exitLog JOB_ER=2）
# ============================================================
run_expect_eq "T01 no args"                    2
run_expect_eq "T02 -c only"                    2 -c list
run_expect_eq "T03 -u only"                    2 -u admin
run_expect_eq "T04 -p only"                    2 -p admin123
run_expect_eq "T05 -c list -u only"            2 -c list -u admin
run_expect_eq "T06 -c list -p only"            2 -c list -p admin123
run_expect_eq "T07 invalid command"            2 -c dummy -u admin -p admin123

# list 以外は対象必須
run_expect_eq "T08 status without -a/-f"       2 -c status -u admin -p admin123

# -a と -f 同時指定は禁止
apps_file_a_and_f="${TMP_DIR}/apps_a_and_f.lst"
echo "/docs" > "$apps_file_a_and_f"
run_expect_eq "T09 -a and -f"                  2 -c status -u admin -p admin123 -a /docs -f "$apps_file_a_and_f"

# ============================================================
# ② 正常系（Single）
# ============================================================
# list
MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
run_expect_eq "T10 list" 0 -c list -u admin -p admin123

# status
MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
run_expect_eq "T20 status running" 0 -c status -u admin -p admin123 -a /docs

MOCK_LIST_OUT="OK\n/docs:stopped:0:docs" \
run_expect_eq "T21 status stopped" 0 -c status -u admin -p admin123 -a /docs

# notfound は displayAppStatus の実装事実として WARNING(1)
MOCK_LIST_OUT="OK\n/apps:running:0:apps" \
run_expect_eq "T22 status notfound" 1 -c status -u admin -p admin123 -a /docs

# start
# stopped -> start OK -> rc=0
MOCK_LIST_OUT="OK\n/docs:stopped:0:docs" \
MOCK_START_OUT="OK - Started" \
run_expect_eq "T30 start (stopped)" 0 -c start -u admin -p admin123 -a /docs

# running -> WARNING(1)
MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
run_expect_eq "T31 start (running)" 1 -c start -u admin -p admin123 -a /docs

# notfound -> start を叩きに行く -> OK なら 0
MOCK_LIST_OUT="OK\n/apps:running:0:apps" \
MOCK_START_OUT="OK - Started" \
run_expect_eq "T32 start (notfound)" 0 -c start -u admin -p admin123 -a /docs

# stop
# running -> stop OK -> 0
MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
MOCK_STOP_OUT="OK - Stopped" \
run_expect_eq "T40 stop (running)" 0 -c stop -u admin -p admin123 -a /docs

# stopped -> WARNING(1)
MOCK_LIST_OUT="OK\n/docs:stopped:0:docs" \
run_expect_eq "T41 stop (stopped)" 1 -c stop -u admin -p admin123 -a /docs

# notfound -> WARNING(1)
MOCK_LIST_OUT="OK\n/apps:running:0:apps" \
run_expect_eq "T42 stop (notfound)" 1 -c stop -u admin -p admin123 -a /docs

# restart
# running -> stop OK -> start OK -> 0
MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
MOCK_STOP_OUT="OK - Stopped" \
MOCK_START_OUT="OK - Started" \
run_expect_eq "T50 restart (running)" 0 -c restart -u admin -p admin123 -a /docs

# stopped -> stop WARNING(1) でも継続 -> start OK -> 0
MOCK_LIST_OUT="OK\n/docs:stopped:0:docs" \
MOCK_START_OUT="OK - Started" \
run_expect_eq "T51 restart (stopped)" 0 -c restart -u admin -p admin123 -a /docs

# notfound -> stop WARNING(1) -> start OK -> 0
MOCK_LIST_OUT="OK\n/apps:running:0:apps" \
MOCK_START_OUT="OK - Started" \
run_expect_eq "T52 restart (notfound)" 0 -c restart -u admin -p admin123 -a /docs

# ============================================================
# ③ 正常系（File）
# ============================================================
# 空行／コメントのみ
apps_file_empty="${TMP_DIR}/apps_empty.lst"
{
    echo ""
    echo "#comment"
    } > "$apps_file_empty"

MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
run_expect_eq "T60 file empty/comment" 0 -c status -u admin -p admin123 -f "$apps_file_empty"

# WARNING 混在（start で running が混ざると startApp が 1）
apps_file_warn="${TMP_DIR}/apps_warn.lst"
{
    echo "docs"
    echo "#comment"
    echo "apps"
} > "$apps_file_warn"

MOCK_LIST_OUT="OK\n/docs:running:0:docs\n/apps:stopped:0:apps" \
MOCK_START_OUT="OK - Started" \
run_expect_eq "T61 file warning mixed" 1 -c start -u admin -p admin123 -f "$apps_file_warn"

# ERROR 混在（start 応答が OK でない -> startApp が 2）
apps_file_err="${TMP_DIR}/apps_err.lst"
echo "apps" > "$apps_file_err"

MOCK_LIST_OUT="OK\n/apps:stopped:0:apps" \
MOCK_START_OUT="FAIL - something" \
run_expect_eq "T62 file error mixed" 2 -c start -u admin -p admin123 -f "$apps_file_err"

# ============================================================
# ④ 異常系
# ============================================================
# Tomcat Manager 接続失敗（curl rc!=0 -> callManagerText が 2）
MOCK_CURL_RC=7 \
run_expect_eq "T70 curl failed" 2 -c list -u admin -p admin123

# 認証失敗は、実装上 curl rc!=0 でないと検出できない（-f 未使用のため）
MOCK_CURL_RC=22 \
run_expect_eq "T71 auth failed (curl rc!=0)" 2 -c list -u admin -p admin123

# SIGINT（trap -> terminate -> rc=2）
(
    PATH="${MOCK_BIN}:$PATH" \
    MOCK_SLEEP_SEC=5 \
    MOCK_LIST_OUT="OK\n/docs:running:0:docs" \
    sh "$TARGET" -c list -u admin -p admin123 >/dev/null 2>&1
) &
PID=$!
sleep 0.1
kill -INT "$PID" >/dev/null 2>&1
wait "$PID"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "T72 SIGINT"
else
    ng "T72 SIGINT" "$rc"
fi

echo "----------------------------------------"
echo "RESULT : PASS=$PASS FAIL=$FAIL"
echo "----------------------------------------"

teardown_mock

[ "$FAIL" -eq 0 ]


