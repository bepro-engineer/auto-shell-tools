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
    if [ -z "$BASE_URL" ] || [ -z "$APP_PATH" ]; then
        logOut "ERROR" "Missing env. BASE_URL=[$BASE_URL] APP_PATH=[$APP_PATH]"
        exitLog 1
    fi
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
    local http_code=""

    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${APP_PATH}")

    case "$http_code" in
        200|302)
            logOut "INFO" "App up. url=[${BASE_URL}${APP_PATH}] http_code=[$http_code]"
            return 0
            ;;
        *)
            logOut "ERROR" "App down. url=[${BASE_URL}${APP_PATH}] http_code=[$http_code]"
            return 1
            ;;
    esac
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
# main-process
# ------------------------------------------------------------------
scope="main"

while true
do
    checkApp
    sleep "$INTERVAL"
done

# ------------------------------------------------------------------
# 終了処理
# ------------------------------------------------------------------
scope="post"

exitLog 0
