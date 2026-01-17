#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# manage_app.sh
# ver.1.2.0  2026.01.15
#
# Usage:
#   Single:
#     sh manage_app.sh -c <command> -u <user> -p <password> [-b <base_url>] -a <context_path>
#
#   File:
#     sh manage_app.sh -c <command> -u <user> -p <password> [-b <base_url>] -f <file>
#
# Command:
#   list|status|start|stop|restart
#
# File format:
#   - 1 line 1 context_path (e.g. /docs)
#   - ignore empty lines
#   - ignore comment lines starting with #
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

# ------------------------------------------------------------------
# 変数宣言
# ------------------------------------------------------------------
scope="var"

# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
setLANG utf-8
runAs root "$@"

readonly JOB_OK=0
readonly JOB_WR=1
readonly JOB_ER=2

RC=0
BASE_URL="http://localhost:8080"
APP_PATH=""
APP_LIST_FILE=""
CMD=""
MANAGER_USER=""
MANAGER_PASS=""
MANAGER_TEXT_PATH="/manager/text"

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

# ------------------------------------------------------------------
# 関数名　　：usage
# 概要　　　：使い方表示
# 説明　　　：
#   本スクリプトのオプションとコマンドを表示する。
#
# 引数　　　：なし
# 戻り値　　：なし
# 使用箇所　：引数不備、エラー時
# ------------------------------------------------------------------
usage() {
    cat << EOF
--------------------------------------
Usage:
  Single:
    sh manage_app.sh -c <command> -u <user> -p <password> [-b <base_url>] -a <context_path>

  File:
    sh manage_app.sh -c <command> -u <user> -p <password> [-b <base_url>] -f <file>

Options:
  -c command      : list|status|start|stop|restart
  -u user         : Tomcat Manager user（manager-script 必須）
  -p password     : Tomcat Manager password
  -b base_url     : Tomcat base URL（default: http://localhost:8080）
  -a context_path : context path（例：/docs）
  -f file         : 1行1パスのファイル（#コメント、空行は無視）

Example:
  sh manage_tomcat_app.sh -b http://localhost:8080 -u admin -p admin123 -c list
  sh manage_tomcat_app.sh -b http://localhost:8080 -u admin -p admin123 -a /docs -c stop
  sh manage_tomcat_app.sh -b http://localhost:8080 -u admin -p admin123 -f /opt/tomcat9/conf/apps_online.lst -c start
--------------------------------------
EOF
}

# ------------------------------------------------------------------
# 関数名　　：terminate
# 概要　　　：シグナル終了処理
# 説明　　　：
#   trap により捕捉したシグナルで終了する場合に、エラー終了としてログを残し終了する。
#
# 引数　　　：なし
# 戻り値　　：なし（exit）
# 使用箇所　：trap
# ------------------------------------------------------------------
terminate() {
    RC=${JOB_ER}
    logOut "ERROR" "Terminated by signal."
    exitLog ${RC}
}

# ------------------------------------------------------------------
# 関数名　　：callManagerText
# 概要　　　：Tomcat Manager(text) 呼び出し
# 説明　　　：
#   Tomcat Manager(text) に対して Basic 認証付きで curl を実行し、レスポンス本文を返却する。
#
# 引数　　　：1) url
# 戻り値　　：0=成功 / 2=失敗
# 使用箇所　：各コマンド処理
# ------------------------------------------------------------------
callManagerText() {
    local url="$1"
    local out=""
    local curl_rc=0

    out=$(curl -sS -u "${MANAGER_USER}:${MANAGER_PASS}" "$url")
    curl_rc=$?

    if [ $curl_rc -ne 0 ]; then
        logOut "ERROR" "curl failed. rc=[$curl_rc] url=[$url]"
        return 2
    fi

    echo "$out"
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：getAppList
# 概要　　　：アプリ一覧取得
# 説明　　　：
#   /manager/text/list を実行してアプリ一覧を取得する。
#
# 引数　　　：なし
# 戻り値　　：0=成功 / 2=失敗
# 使用箇所　：list/status
# ------------------------------------------------------------------
getAppList() {
    callManagerText "${BASE_URL}${MANAGER_TEXT_PATH}/list"
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：getAppLine
# 概要　　　：指定アプリ行抽出
# 説明　　　：
#   list出力から指定パスの行（/path:running:0:name）を抽出する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=見つかった / 1=見つからない / 2=失敗
# 使用箇所　：status
# ------------------------------------------------------------------
getAppLine() {
    local app_path="$1"
    local list_out=""

    list_out=$(getAppList) || return 2

    echo "$list_out" | awk -v p="${app_path}:" '
        $0 ~ "^OK" { next }
        index($0, p) == 1 { print; found=1 }
        END { if (!found) exit 1 }
    '
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：getAppState
# 概要　　　：指定アプリの状態取得
# 説明　　　：
#   list出力の該当行から running / stopped を抽出して返す。
#   見つからない場合は "notfound" を返す。
#
# 引数　　　：1) app_path
# 戻り値　　：0=成功 / 1=対象なし / 2=失敗
# 出力　　　：running|stopped|notfound
# 使用箇所　：startApp/stopApp の事前判定
# ------------------------------------------------------------------
getAppState() {
    local app_path="$1"
    local line=""
    local rc_local=0
    local state=""

    line=$(getAppLine "$app_path")
    rc_local=$?

    if [ $rc_local -eq 0 ]; then
        state=$(echo "$line" | awk -F: '{print $2}')
        if [ -z "$state" ]; then
            echo "unknown"
            return 2
        fi
        echo "$state"
        return 0
    fi

    if [ $rc_local -eq 1 ]; then
        echo "notfound"
        return 1
    fi

    echo "unknown"
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：displayAppStatus
# 概要　　　：ステータス表示
# 説明　　　：
#   指定アプリのステータスをログ出力する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=成功 / 1=対象なし / 2=失敗
# 使用箇所　：status/restart後確認
# ------------------------------------------------------------------
displayAppStatus() {
    local app_path="$1"
    local line=""
    local rc_local=0

    line=$(getAppLine "$app_path")
    rc_local=$?

    if [ $rc_local -eq 0 ]; then
        logOut "INFO" "APP STATUS: ${line}"
        return 0
    fi

    if [ $rc_local -eq 1 ]; then
        logOut "WARNING" "APP not found in list: [$app_path]"
        return 1
    fi

    logOut "ERROR" "Failed to get app status: [$app_path]"
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：startApp
# 概要　　　：アプリ起動
# 説明　　　：
#   /manager/text/start を実行する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=成功 / 2=失敗
# 使用箇所　：start/restart
# ------------------------------------------------------------------
startApp() {
    local app_path="$1"
    local state=""
    local state_rc=0
    local out=""

    state=$(getAppState "$app_path")
    state_rc=$?

    if [ $state_rc -eq 0 ] && [ "$state" = "running" ]; then
        logOut "WARNING" "Already running: [$app_path]"
        return 1
    fi

    out=$(callManagerText "${BASE_URL}${MANAGER_TEXT_PATH}/start?path=${app_path}") || return 2

    if echo "$out" | grep -q "^OK"; then
        logOut "INFO" "Started: [$app_path]"
        return 0
    fi

    logOut "ERROR" "Start failed: [$app_path] resp=[$out]"
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：stopApp
# 概要　　　：アプリ停止
# 説明　　　：
#   /manager/text/stop を実行する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=成功 / 2=失敗
# 使用箇所　：stop/restart
# ------------------------------------------------------------------
stopApp() {
    local app_path="$1"
    local state=""
    local state_rc=0
    local out=""

    state=$(getAppState "$app_path")
    state_rc=$?

    if [ $state_rc -eq 1 ] || [ "$state" = "stopped" ]; then
        logOut "WARNING" "Already stopped (or not found): [$app_path]"
        return 1
    fi

    if [ $state_rc -eq 2 ]; then
        logOut "ERROR" "Failed to get current state: [$app_path]"
        return 2
    fi

    out=$(callManagerText "${BASE_URL}${MANAGER_TEXT_PATH}/stop?path=${app_path}") || return 2

    if echo "$out" | grep -q "^OK"; then
        logOut "INFO" "Stopped: [$app_path]"
        return 0
    fi

    logOut "ERROR" "Stop failed: [$app_path] resp=[$out]"
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：restartApp
# 概要　　　：アプリ再起動
# 説明　　　：
#   stop -> start を実行する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=成功 / 2=失敗
# 使用箇所　：restart
# ------------------------------------------------------------------
restartApp() {
    local app_path="$1"

    stopApp "$app_path"
    rc_stop=$?
    if [ $rc_stop -eq 2 ]; then
        return 2
    fi

    sleep 1

    startApp "$app_path"
    rc_start=$?
    if [ $rc_start -eq 2 ]; then
        return 2
    fi

    return 0
}

# ------------------------------------------------------------------
# 関数名　　：normalizePath
# 概要　　　：コンテキストパスの正規化
# 説明　　　：
#   指定されたコンテキストパスが "/" で始まっていない場合、
#   先頭に "/" を付与して正規化する。
#   すでに "/" で始まっている場合はそのまま返す。
#   引数が未指定（空文字）の場合は空文字を返す。
#
# 引数　　　：1) コンテキストパス
#               例: docs, /docs
# 戻り値　　：常に 0
# 出力　　　：正規化後のコンテキストパス
# 使用箇所　：-a オプション指定時および
#               アプリ一覧ファイル読み込み時のパス補正
# ------------------------------------------------------------------
normalizePath() {
    local p="$1"
    if [ -z "$p" ]; then
        echo ""
        return 0
    fi

    case "$p" in
        /*) echo "$p" ;;
        *)  echo "/${p}" ;;
    esac
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：processFile
# 概要　　　：アプリ一覧ファイルを読み込み、コマンドを順次実行
# 説明　　　：
#   指定されたファイルを1行ずつ読み込み、各行に記載された
#   コンテキストパスに対して指定コマンドを実行する。
#   空行および "#" で始まるコメント行は処理対象外とする。
#   各行のコンテキストパスは normalizePath() により正規化したうえで処理する。
#
#   各アプリの実行結果を集約し、
#   ・ERROR(2) が1件でも発生した場合は最終戻り値を ERROR
#   ・ERROR が無く WARNING(1) が発生した場合は WARNING
#   ・すべて正常の場合は OK(0)
#   を返す。
#
# 引数　　　：1) アプリ一覧ファイルパス
#               2) 実行コマンド（status / start / stop / restart）
# 戻り値　　：0=正常 / 1=警告あり / 2=エラーあり
# 使用箇所　：-f オプション指定時の一括アプリ操作処理
# ------------------------------------------------------------------
processFile() {
    local file="$1"
    local cmd="$2"
    local line=""
    local p=""
    local rc_local=0
    local rc_total=0

    if [ ! -f "$file" ]; then
        logOut "ERROR" "File not found: [$file]"
        return 2
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # コメント・空行は無視
        case "$line" in
            "" ) continue ;;
            \#* ) continue ;;
        esac

        p=$(normalizePath "$line")

        logOut "INFO" "Processing: cmd=[$cmd] path=[$p]"

        case "$cmd" in
            status)  displayAppStatus "$p"; rc_local=$? ;;
            start)   startApp "$p";        rc_local=$? ;;
            stop)    stopApp "$p";         rc_local=$? ;;
            restart) restartApp "$p";      rc_local=$? ;;
        esac

        # ERROR(2) が1つでもあれば最終は ERROR
        if [ $rc_local -eq 2 ]; then
            rc_total=2
        fi

        # WARNING(1) は rc_total が 0 のときだけ反映（ERROR優先）
        if [ $rc_local -eq 1 ] && [ $rc_total -eq 0 ]; then
            rc_total=1
        fi
    done < "$file"

    return $rc_total
}

# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

while getopts "b:a:f:c:u:p:" opt; do
    case "$opt" in
        b) BASE_URL="$OPTARG" ;;
        a) APP_PATH="$OPTARG" ;;
        f) APP_LIST_FILE="$OPTARG" ;;
        c) CMD="$OPTARG" ;;
        u) MANAGER_USER="$OPTARG" ;;
        p) MANAGER_PASS="$OPTARG" ;;
        *) usage; exitLog ${JOB_ER} ;;
    esac
done

startLog
logOut "INFO" "Args: [-b $BASE_URL -a $APP_PATH -f $APP_LIST_FILE -c $CMD -u $MANAGER_USER -p (hidden)]"
trap "terminate" 1 2 3 15

if [ -z "$CMD" ]; then
    logOut "ERROR" "command が未指定です。（-c）"
    usage
    exitLog ${JOB_ER}
fi

if [ -z "$MANAGER_USER" ] || [ -z "$MANAGER_PASS" ]; then
    logOut "ERROR" "Tomcat Manager の user/password が未指定です。（-u と -p）"
    usage
    exitLog ${JOB_ER}
fi

case "$CMD" in
    list|status|start|stop|restart) : ;;
    *)
        logOut "ERROR" "Invalid command: [$CMD]"
        usage
        exitLog ${JOB_ER}
        ;;
esac

# list以外は対象必須（-a か -f のどちらか）
if [ "$CMD" != "list" ]; then
    if [ -z "$APP_PATH" ] && [ -z "$APP_LIST_FILE" ]; then
        logOut "ERROR" "対象が未指定です。（-a もしくは -f）"
        usage
        exitLog ${JOB_ER}
    fi
fi

# -a と -f の同時指定は禁止（事故防止）
if [ -n "$APP_PATH" ] && [ -n "$APP_LIST_FILE" ]; then
    logOut "ERROR" "-a と -f を同時に指定する運用は許可しない。どちらか一方に統一してください。"
    usage
    exitLog ${JOB_ER}
fi

# 単体パス正規化
if [ -n "$APP_PATH" ]; then
    APP_PATH=$(normalizePath "$APP_PATH")
fi

# ------------------------------------------------------------------
# main-process
# ------------------------------------------------------------------
scope="main"

case "$CMD" in
    list)
        logOut "INFO" "Listing applications..."
        out=$(getAppList)
        RC=$?
        if [ $RC -eq 0 ]; then
            echo "$out"
        fi
        ;;
    status)
        if [ -n "$APP_LIST_FILE" ]; then
            processFile "$APP_LIST_FILE" "status"
            RC=$?
        else
            displayAppStatus "$APP_PATH"
            RC=$?
        fi
        ;;
    start)
        if [ -n "$APP_LIST_FILE" ]; then
            processFile "$APP_LIST_FILE" "start"
            RC=$?
        else
            startApp "$APP_PATH"
            RC=$?
        fi
        ;;
    stop)
        if [ -n "$APP_LIST_FILE" ]; then
            processFile "$APP_LIST_FILE" "stop"
            RC=$?
        else
            stopApp "$APP_PATH"
            RC=$?
        fi
        ;;
    restart)
        if [ -n "$APP_LIST_FILE" ]; then
            processFile "$APP_LIST_FILE" "restart"
            RC=$?
        else
            restartApp "$APP_PATH"
            RC=$?
        fi
        ;;
esac

# ------------------------------------------------------------------
# 終了処理
# ------------------------------------------------------------------
scope="post"

exitLog $RC

