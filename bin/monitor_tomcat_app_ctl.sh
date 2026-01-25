#!/bin/bash
# ------------------------------------------------------------------
# ファイル名　：monitor_tomcat_app_ctl.sh
# 概要　　　　：Tomcat コンテキスト監視 systemd ユニット操作窓口
# 説明　　　　：
#   systemd のテンプレートユニット
#     monitor_tomcat_app_online@.service（8080系）
#     monitor_tomcat_app_batch@.service（8081系）
#   に対して start / stop / status を行う操作スクリプト。
#
#   絶対ルール：
#     BASE_URL は絶対に加工・変換・書き換えしない。
#     8080/8081 の判定は「操作対象ユニットを選ぶ」目的にだけ使う。
#
# 使用方法　　：
#   bash monitor_tomcat_app_ctl.sh -b <base_url> -a <context> -c <start|stop|status>
#
# 例　　　　　：
#   bash monitor_tomcat_app_ctl.sh -b http://localhost:8080 -a /docs -c start
#   bash monitor_tomcat_app_ctl.sh -b http://localhost:8080 -a /docs -c status
#   bash monitor_tomcat_app_ctl.sh -b http://localhost:8080 -a /docs -c stop
#
#   bash monitor_tomcat_app_ctl.sh -b http://localhost:8081 -a jobs -c start
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

BASE_URL=""
CONTEXT_NAME=""
CMD=""

UNIT_PREFIX=""
UNIT=""

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
  bash $0 -b <base_url> -a <context> -c <start|stop|status>

Options:
  -b <base_url>
       Tomcat 識別用 URL（例：http://localhost:8080 または http://localhost:8081）
       BASE_URL は加工しない（書き換えない）。

  -a <context>
       コンテキスト名（例：docs）
       /docs が指定された場合は内部で docs に正規化する。

  -c <start|stop|status>
       systemd ユニット操作

Example:
  bash $0 -b http://localhost:8080 -a /docs -c start
  bash $0 -b http://localhost:8080 -a /docs -c status
  bash $0 -b http://localhost:8080 -a /docs -c stop
EOF
}

# ------------------------------------------------------------------
# 関数名　　：parseArgs
# 概要　　　：引数解析
# ------------------------------------------------------------------
parseArgs() {
    while getopts "b:a:c:" opt; do
        case "$opt" in
            b)
                BASE_URL="$OPTARG"
                ;;
            a)
                CONTEXT_NAME="${OPTARG#/}"
                ;;
            c)
                CMD="$OPTARG"
                ;;
            *)
                usage
                exitLog 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------
# 関数名　　：validateArgs
# 概要　　　：必須引数チェック
# ------------------------------------------------------------------
validateArgs() {
    # 引数が一つも無い場合は usage を出して終了
    if [ $# -eq 0 ]; then
        usage
        exitLog 1
    fi

    if [ -z "$BASE_URL" ] || [ -z "$CONTEXT_NAME" ] || [ -z "$CMD" ]; then
        logOut "ERROR" "Missing required arguments. base=[$BASE_URL] context=[$CONTEXT_NAME] cmd=[$CMD]"
        usage
        exitLog 1
    fi

    case "$CMD" in
        start|stop|status)
            ;;
        *)
            logOut "ERROR" "Invalid command. cmd=[$CMD]"
            usage
            exitLog 1
            ;;
    esac
}

# ------------------------------------------------------------------
# 関数名　　：resolveUnit
# 概要　　　：BASE_URL のポートから操作対象ユニットを決定
# 説明　　　：
#   8080 → online テンプレート
#   8081 → batch  テンプレート
#   ※ BASE_URL は書き換えない。判定に使うだけ。
# ------------------------------------------------------------------
resolveUnit() {
    case "$BASE_URL" in
        *:8080*)
            UNIT_PREFIX="monitor_tomcat_app_online@"
            ;;
        *:8081*)
            UNIT_PREFIX="monitor_tomcat_app_batch@"
            ;;
        *)
            logOut "ERROR" "Unsupported base url (port). base=[$BASE_URL] (expected :8080 or :8081)"
            exitLog 1
            ;;
    esac

    UNIT="${UNIT_PREFIX}${CONTEXT_NAME}.service"
}

# ------------------------------------------------------------------
# 関数名　　：execSystemctl
# 概要　　　：systemctl 実行
# ------------------------------------------------------------------
execSystemctl() {
    case "$CMD" in
        status)
            systemctl status "$UNIT" --no-pager
            return $?
            ;;
        *)
            systemctl "$CMD" "$UNIT"
            return $?
            ;;
    esac
}

# ------------------------------------------------------------------
# 関数名　　：checkContextExists
# 概要　　　：監視対象 Tomcat コンテキストの事前存在チェック
# 説明　　　：
#   systemd unit を start する前に、BASE_URL + "/"+CONTEXT_NAME へ HTTP アクセスを行い、
#   対象コンテキストが実在するかを確認する。
#   存在しない場合は、unit を起動せず異常終了する。
#
#   正常判定は HTTP ステータス 200 / 302 とする。
#   curl の通信失敗（DNS/接続不可/タイムアウト等）も異常終了する。
#
# 引数　　　：なし（BASE_URL / CONTEXT_NAME を内部参照）
# 戻り値　　：0  正常（監視開始可能）
#             exitLog 2 により異常終了（監視開始不可）
# 使用箇所　：main-process（CMD=start の直前）
# ------------------------------------------------------------------
checkContextExists() {
    local url
    local http_code
    local curl_rc

    url="${BASE_URL}/${CONTEXT_NAME}"

    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "$url")"
    curl_rc=$?

    if [ "$curl_rc" -ne 0 ]; then
        logOut "ERROR" "Context precheck failed (curl error). url=[$url] curl_rc=[$curl_rc] http_code=[$http_code]"
        exitLog 2
    fi

    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        logOut "INFO" "Context precheck OK. url=[$url] http_code=[$http_code]"
        return 0
    fi

    logOut "ERROR" "Context not found. url=[$url] http_code=[$http_code]"
    exitLog 2
}

# ------------------------------------------------------------------
# 関数名　　：isUnitActive
# 概要　　　：systemd ユニット起動状態判定
# 説明　　　：
#   systemctl is-active を用いて、対象ユニットが active かを判定する。
#   active の場合は 0、それ以外は 1 を返す。
#
# 引数　　　：なし（UNIT を内部参照）
# 戻り値　　：0 : active
#             1 : active 以外
# 使用箇所　：main-process（start/stop/restart 前処理）
# ------------------------------------------------------------------
isUnitActive() {
    systemctl is-active --quiet "$UNIT"
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：checkUnitExists
# 概要　　　：systemd ユニットの存在チェック
# 説明　　　：
#   systemctl show の LoadState を確認し、not-found の場合は異常終了する。
#
# 引数　　　：なし（UNIT を内部参照）
# 戻り値　　：0 : 存在する
#             exitLog 2 : 存在しない
# 使用箇所　：main-process（start/stop/status の直前）
# ------------------------------------------------------------------
checkUnitExists() {
    local load_state

    load_state="$(systemctl show "$UNIT" -p LoadState --value 2>/dev/null)"

    if [ "$load_state" = "not-found" ] || [ -z "$load_state" ]; then
        logOut "ERROR" "Unit not found. unit=[$UNIT]"
        exitLog 2
    fi

    return 0
}

# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

startLog
trap "exitLog 1" 1 2 3 15

parseArgs "$@"
validateArgs "$@"
resolveUnit

# ------------------------------------------------------------------
# main-process
# ------------------------------------------------------------------
scope="main"

logOut "INFO" "Execute unit control. cmd=[$CMD] unit=[$UNIT] base=[$BASE_URL] context=[$CONTEXT_NAME]"

case "$CMD" in
    start)
        checkUnitExists
        if isUnitActive; then
            logOut "INFO" "Already running. unit=[$UNIT]"
            exitLog 0
        fi
        checkContextExists
        ;;
    stop)
        checkUnitExists
        if ! isUnitActive; then
            logOut "INFO" "Already stopped. unit=[$UNIT]"
            exitLog 0
        fi
        ;;
    status)
        checkUnitExists
        ;;
    restart)
        checkUnitExists
        checkContextExists
        ;;
esac

execSystemctl
RC=$?

# ------------------------------------------------------------------
# 終了処理
# ------------------------------------------------------------------
scope="post"

exitLog $RC
