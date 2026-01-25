#!/bin/bash
# ------------------------------------------------------------------
# ファイル名　：monitor_tomcat_app_daemon.sh
# 概要　　　　：Tomcat コンテキスト監視 常駐デーモン
# 説明　　　　：
#   systemd の ExecStart から起動され、常駐で死活監視を行う。
#
#   重要：
#   ・本デーモンは「落ちたら exit」しない（StartLimit を踏むため）
#   ・アプリが落ちていたら ERROR を出し続ける
#   ・デーモン自身が落ちた場合のみ systemd が Restart=always で復旧する
#
# 使用方法　　：
#   bash monitor_tomcat_app_daemon.sh [-i <interval_sec>]
#
# 引数　　　　：
#   -i : 監視間隔秒（省略時 5）
#
# 前提　　　　：
#   systemd 側で以下の環境変数が設定されていること
#     BASE_URL 例：http://localhost:8080
#     APP_PATH 例：/docs
#
# 絶対ルール：
#   BASE_URL は加工・変換・判定しない（書き換えない）
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# 変数宣言
# ------------------------------------------------------------------
scope="var"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COM_DIR=$(cd "$SCRIPT_DIR/../com" 2>/dev/null && pwd)

. "$COM_DIR/utils.shrc"
. "$COM_DIR/logger.shrc"

setLANG utf-8
runAs root "$@"

BASE_URL="${BASE_URL}"
APP_PATH="${APP_PATH}"
INTERVAL=5

RC=0

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

# ------------------------------------------------------------------
# 関数名　　：usage
# 概要　　　：usage表示
# ------------------------------------------------------------------
usage() {
    cat << EOF
Usage:
  bash $0 [-i <interval_sec>]

Options:
  -i <interval_sec>
       監視間隔（秒）
       省略時は 5

Note:
  BASE_URL / APP_PATH は systemd の Environment から受け取る。
  BASE_URL は加工・変換・判定しない（書き換えない）。
EOF
}

# ------------------------------------------------------------------
# 関数名　　：parseArgs
# 概要　　　：引数解析
# ------------------------------------------------------------------
parseArgs() {
    while getopts "i:" opt; do
        case "$opt" in
            i)
                INTERVAL="$OPTARG"
                ;;
            *)
                usage
                exitLog 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------
# 関数名　　：validateEnv
# 概要　　　：環境変数チェック
# ------------------------------------------------------------------
validateEnv() {
    # 空/空白のみはNG
    if [ -z "${BASE_URL//[[:space:]]/}" ] || [ -z "${APP_PATH//[[:space:]]/}" ]; then
        logOut "ERROR" "Missing env. BASE_URL=[$BASE_URL] APP_PATH=[$APP_PATH]"
        exitLog 1
    fi

    # APP_PATH は「/から始まる」前提。ここでは補正しない（壊れてたら落とす）
    case "$APP_PATH" in
        /*)
            ;;
        *)
            logOut "ERROR" "Invalid APP_PATH format. APP_PATH must start with '/'. APP_PATH=[$APP_PATH]"
            exitLog 1
            ;;
    esac
}

# ------------------------------------------------------------------
# 関数名　　：checkApp
# 概要　　　：疎通確認
# 説明　　　：
#   HTTP ステータス 200 を正常とする。
#   200 以外は異常として ERROR を出す。
#
# 引数　　　：なし
# 戻り値　　：
#   0 : 正常
#   1 : 異常
# ------------------------------------------------------------------
checkApp() {
    local url
    local http_code
    local curl_rc

    url="${BASE_URL}${APP_PATH}"

    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "$url")"
    curl_rc=$?

    # 通信失敗（DNS失敗/接続不可/タイムアウト等）
    if [ "$curl_rc" -ne 0 ]; then
        logOut "ERROR" "App check failed (curl). url=[$url] curl_rc=[$curl_rc] http_code=[$http_code]"
        return 2
    fi

    # HTTP応答は取れたが、想定外ステータス
    # 仕様統一：200 または 302 を正常とする（現行実装に合わせる）
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        return 0
    fi

    logOut "ERROR" "App down. url=[$url] http_code=[$http_code]"
    return 1
}


# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

startLog
trap "logOut \"INFO\" \"SIGTERM received. stop requested.\"; exitLog 0" 15
trap "exitLog 1" 1 2 3

parseArgs "$@"
validateEnv

logOut "INFO" "Monitor daemon started. base=[$BASE_URL] path=[$APP_PATH] interval=[$INTERVAL]"

# ------------------------------------------------------------------
# main-process（最適化）
# 方針：
# - UP 時は状態変化時だけ INFO（ログ洪水防止）
# - DOWN 時は毎回 ERROR（「落ちていたら出し続ける」要件どおり）
# - checkApp の戻り値を使う（0=UP, 1=HTTP異常, 2=通信失敗）
# ------------------------------------------------------------------
scope="main"
prev_state="INIT"

while true
do
    checkApp
    rc=$?

    case "$rc" in
        0)
            state="UP"
            # 復旧時のみ INFO
            if [ "$prev_state" != "$state" ]; then
                logOut "INFO" "App recovered. url=[${BASE_URL}${APP_PATH}]"
            fi
            ;;
        1)
            state="DOWN_HTTP"
            # DOWN は毎回 ERROR（出し続ける）
            logOut "ERROR" "App down (http). url=[${BASE_URL}${APP_PATH}]"
            ;;
        2)
            state="DOWN_COMM"
            # DOWN は毎回 ERROR（出し続ける）
            logOut "ERROR" "App down (comm). url=[${BASE_URL}${APP_PATH}]"
            ;;
        *)
            state="DOWN_UNKNOWN"
            logOut "ERROR" "App down (unknown rc). url=[${BASE_URL}${APP_PATH}] rc=[$rc]"
            ;;
    esac

    prev_state="$state"
    sleep "$INTERVAL"
done

# ------------------------------------------------------------------
# 終了処理
# ------------------------------------------------------------------
scope="post"

exitLog 0
