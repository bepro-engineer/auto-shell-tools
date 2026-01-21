#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# monitor_tomcat_app.sh
# ver.1.0.0 2026.01.21
#
# Usage:
# sh monitor_tomcat_app.sh -c <command> [-b <base_url>] [-u <user> -p <password>] [-a <context_path> | -f <file>]
#
# Command:
# list|status|show|start|stop
#
# File format:
# - 1 line 1 context_path (e.g. /docs)
# - ignore empty lines
# - ignore comment lines starting with #
#
# Note:
# - start は常駐監視プロセスを起動する
# - stop/status は -a か -f で対象指定する
# - show は即時確認のみで常駐しない
# - Tomcat Manager 到達不可またはアプリ停止検知時は ERROR を出力し restart を試行する
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

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

CMD=""
BASE_URL="http://localhost:8080"
MANAGER_USER=""
MANAGER_PASS=""
APP_PATH=""
APP_FILE=""

CHECK_INTERVAL_SEC=1
MANAGER_TIMEOUT_SEC=3
TOMCAT_BOOT_WAIT_SEC=5

PID_ROOT="$(cd "$(dirname "$0")/.." && pwd)/tmp/monitor_tomcat_app"
PID_DIR=""
META_DIR=""

MANAGE_SCRIPT="$SCRIPT_DIR/manage_tomcat_app.sh"
TOMCAT_UNIT="tomcat9.service"

RC=0

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

# ------------------------------------------------------------------
# 関数名　　：usage
# 概要　　　：usage表示
# 説明　　　：
#   引数指定方法を表示する。
#
# 引数　　　：なし
# 戻り値　　：なし
# 使用箇所　：引数不備時
# ------------------------------------------------------------------
usage() {
    cat << EOF
--------------------------------------
Usage:
sh monitor_tomcat_app.sh -c <command> [-b <base_url>] [-u <user> -p <password>] [-a <context_path> | -f <file>]

Command:
list|status|show|start|stop

Options:
-c command : list|status|show|start|stop
-b base_url : Tomcat base URL (default: http://localhost:8080)
-u user : Tomcat Manager user (start/showで必須)
-p password : Tomcat Manager password (start/showで必須)
-a context_path : context path (例: /docs)
-f file : 1行1パスのファイル (#コメント、空行は無視)

Example:
sh monitor_tomcat_app.sh -c list -b http://localhost:8080
sh monitor_tomcat_app.sh -c list -b http://localhost:8081
sh monitor_tomcat_app.sh -c start -b http://localhost:8080 -u admin -p admin123 -a /docs
sh monitor_tomcat_app.sh -c start -b http://localhost:8080 -u admin -p admin123 -f /opt/tomcat9/conf/apps_online.lst
sh monitor_tomcat_app.sh -c start -b http://localhost:8081 -u admin -p admin123 -f /opt/tomcat9/conf/apps_batch.lst
sh monitor_tomcat_app.sh -c status -b http://localhost:8080 -a /docs
sh monitor_tomcat_app.sh -c show -b http://localhost:8080 -u admin -p admin123 -a /docs
sh monitor_tomcat_app.sh -c stop -b http://localhost:8080 -a /docs
--------------------------------------
EOF
}

baseToKey() {
    local base_url="$1"
    echo "$base_url" \
        | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
        | sed 's#[/:]#_#g' \
        | sed 's#[^0-9A-Za-z_.-]#_#g'
}

setRunDirs() {
    local base_key
    base_key=$(baseToKey "$BASE_URL")
    PID_DIR="${PID_ROOT}/${base_key}"
    META_DIR="${PID_DIR}/meta"
}

# ------------------------------------------------------------------
# 関数名　　：isAppKnown
# 概要　　　：アプリ存在確認
# 説明　　　：
#   Tomcat Manager の list に指定パスが存在するか確認する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=exists / 1=notfound / 2=error
# 使用箇所　：start/show/daemon
# ------------------------------------------------------------------
isAppKnown() {
    local app_path="$1"
    curl -sS --max-time ${MANAGER_TIMEOUT_SEC} \
        -u "${MANAGER_USER}:${MANAGER_PASS}" \
        "${BASE_URL}/manager/text/list" 2>/dev/null \
        | awk -v p="${app_path}:" '
            $0 ~ "^OK" { next }
            index($0, p) == 1 { found=1 }
            END { if (found) exit 0; else exit 1 }
        '
    if [ $? -eq 0 ]; then
        return 0
    fi
    if [ $? -eq 1 ]; then
        return 1
    fi
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：validateTargetExists
# 概要　　　：対象存在チェック
# 説明　　　：
#   対象が存在しない場合は ERROR を出して NG とする。
#
# 引数　　　：1) app_path
# 戻り値　　：0=OK / 2=NG
# 使用箇所　：start/show/daemon
# ------------------------------------------------------------------
validateTargetExists() {
    local app_path="$1"
    isAppKnown "$app_path"
    if [ $? -eq 0 ]; then
        return 0
    fi
    logOut "ERROR" "Target not found in Tomcat. path=[$app_path]"
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：terminate
# 概要　　　：終了処理
# 説明　　　：
#   trap により呼ばれる終了処理。
#
# 引数　　　：なし
# 戻り値　　：なし
# 使用箇所　：trap
# ------------------------------------------------------------------
terminate() {
    logOut "ERROR" "Terminated. command=[$CMD] path=[$APP_PATH] file=[$APP_FILE]"
    exitLog 2
}

# ------------------------------------------------------------------
# 関数名　　：initDirs
# 概要　　　：作業ディレクトリ作成
# 説明　　　：
#   PID/META ディレクトリを作成する。
#
# 引数　　　：なし
# 戻り値　　：0=OK / 1=NG
# 使用箇所　：初期化
# ------------------------------------------------------------------
initDirs() {
    mkdir -p "$PID_DIR" "$META_DIR" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        logOut "ERROR" "Failed to create dirs. pid_dir=[$PID_DIR] meta_dir=[$META_DIR]"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：normalizePath
# 概要　　　：コンテキストパス正規化
# 説明　　　：
#   "/" で始まらない場合は先頭に "/" を付与する。
#
# 引数　　　：1) context_path
# 戻り値　　：0
# 使用箇所　：-a/-f の取り込み
# ------------------------------------------------------------------
normalizePath() {
    case "$1" in
        /*) echo "$1" ;;
        *) echo "/$1" ;;
    esac
}

# ------------------------------------------------------------------
# 関数名　　：pathToKey
# 概要　　　：context_path をキー化
# 説明　　　：
#   context_path をファイル名に使える形式へ変換する。
#   例: /docs -> docs, /a/b -> a__b
#
# 引数　　　：1) context_path
# 戻り値　　：key
# 使用箇所　：PID/META ファイル名
# ------------------------------------------------------------------
pathToKey() {
    echo "$1" | sed 's#^/##' | sed 's#/#__#g'
}

# ------------------------------------------------------------------
# 関数名　　：keyToPath
# 概要　　　：キーを context_path に戻す
# 説明　　　：
#   key を context_path へ戻す。
#   例: docs -> /docs, a__b -> /a/b
#
# 引数　　　：1) key
# 戻り値　　：context_path
# 使用箇所　：list表示
# ------------------------------------------------------------------
keyToPath() {
    echo "/$1" | sed 's#__#/#g'
}

# ------------------------------------------------------------------
# 関数名　　：getPidFile
# 概要　　　：PIDファイルパス取得
# 説明　　　：
#   対象 context_path の PID ファイルパスを返す。
#
# 引数　　　：1) context_path
# 戻り値　　：pid_file
# 使用箇所　：start/stop/status
# ------------------------------------------------------------------
getPidFile() {
    local key
    key=$(pathToKey "$1")
    echo "$PID_DIR/${key}.pid"
}

# ------------------------------------------------------------------
# 関数名　　：getMetaFile
# 概要　　　：METAファイルパス取得
# 説明　　　：
#   対象 context_path の META ファイルパスを返す。
#
# 引数　　　：1) context_path
# 戻り値　　：meta_file
# 使用箇所　：start/status/list
# ------------------------------------------------------------------
getMetaFile() {
    local key
    key=$(pathToKey "$1")
    echo "$META_DIR/${key}.meta"
}

# ------------------------------------------------------------------
# 関数名　　：isPidAlive
# 概要　　　：PID生存確認
# 説明　　　：
#   kill -0 により PID の存在を確認する。
#
# 引数　　　：1) pid
# 戻り値　　：0=alive / 1=dead
# 使用箇所　：status/stop/start
# ------------------------------------------------------------------
isPidAlive() {
    if [ -z "$1" ]; then
        return 1
    fi
    kill -0 "$1" >/dev/null 2>&1
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：readTargets
# 概要　　　：監視対象取得
# 説明　　　：
#   -a または -f から監視対象 context_path を取得する。
#
# 引数　　　：なし
# 戻り値　　：0=OK / 2=NG
# 出力　　　：1行1context_path
# 使用箇所　：start/stop/status/show
# ------------------------------------------------------------------
readTargets() {
    if [ -n "$APP_PATH" ]; then
        normalizePath "$APP_PATH"
        return 0
    fi

    if [ -n "$APP_FILE" ]; then
        if [ ! -f "$APP_FILE" ]; then
            logOut "ERROR" "Target file not found. file=[$APP_FILE]"
            return 2
        fi

        while IFS= read -r line || [ -n "$line" ]; do
            line=$(trimLine "$line")
            if [ -z "$line" ]; then
                continue
            fi
            case "$line" in
                \#*) continue ;;
            esac
            normalizePath "$line"
        done < "$APP_FILE"
        return 0
    fi

    logOut "ERROR" "Missing target. specify -a or -f."
    return 2
}

# ------------------------------------------------------------------
# 関数名　　：isManagerReachable
# 概要　　　：Tomcat Manager 到達確認
# 説明　　　：
#   /manager/text/list へアクセスできるか確認する。
#
# 引数　　　：なし
# 戻り値　　：0=reachable / 1=unreachable
# 使用箇所　：監視処理
# ------------------------------------------------------------------
isManagerReachable() {
    curl -sS --max-time ${MANAGER_TIMEOUT_SEC} \
        -u "${MANAGER_USER}:${MANAGER_PASS}" \
        "${BASE_URL}/manager/text/list" >/dev/null 2>&1
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：startTomcat
# 概要　　　：Tomcat 起動
# 説明　　　：
#   systemctl start で Tomcat を起動する。
#
# 引数　　　：なし
# 戻り値　　：0=OK / 1=NG
# 使用箇所　：Tomcat 停止検知時
# ------------------------------------------------------------------
startTomcat() {
    systemctl start "$TOMCAT_UNIT" >/dev/null 2>&1
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：getAppState
# 概要　　　：アプリ状態取得
# 説明　　　：
#   /manager/text/list の出力から指定アプリの state を抽出する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=OK / 1=notfound / 2=error
# 出力　　　：state (running 等)
# 使用箇所　：show/監視処理
# ------------------------------------------------------------------
getAppState() {
    local app_path="$1"
    local out=""
    local line=""
    local state=""

    out=$(curl -sS --max-time ${MANAGER_TIMEOUT_SEC} -u "${MANAGER_USER}:${MANAGER_PASS}" "${BASE_URL}/manager/text/list" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "unknown"
        return 2
    fi

    line=$(echo "$out" | awk -v p="${app_path}:" '
        $0 ~ "^OK" { next }
        index($0, p) == 1 { print; found=1 }
        END { if (!found) exit 1 }
    ')
    if [ $? -eq 1 ]; then
        echo "notfound"
        return 1
    fi

    state=$(echo "$line" | awk -F: '{print $2}' | tr -d '\r' | tr -d ' ')
    if [ -z "$state" ]; then
        echo "unknown"
        return 2
    fi

    echo "$state"
    return 0
}
# ------------------------------------------------------------------
# 関数名　　：restartApp
# 概要　　　：アプリ再起動
# 説明　　　：
#   manage_tomcat_app.sh を用いて対象アプリを restart する。
#   失敗時は manage 側の出力を必ず ERROR ログに残す。
#
# 引数　　　：1) app_path
# 戻り値　　：0=OK / 1=NG
# 使用箇所　：監視処理
# ------------------------------------------------------------------
restartApp() {
    local app_path="$1"
    local out

    out=$(sh "$MANAGE_SCRIPT" -b "$BASE_URL" -u "$MANAGER_USER" -p "$MANAGER_PASS" -a "$app_path" -c restart 2>&1)
    if [ $? -ne 0 ]; then
        logOut "ERROR" "restart failed. path=[$app_path] detail=[$out]"
        return 1
    fi

    logOut "INFO" "restart succeeded. path=[$app_path] detail=[$out]"
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：writeMeta
# 概要　　　：META書き込み
# 説明　　　：
#   常駐監視の情報を META ファイルに保存する。
#
# 引数　　　：1) app_path
# 戻り値　　：0=OK / 1=NG
# 使用箇所　：daemon起動時
# ------------------------------------------------------------------
writeMeta() {
    local meta_file
    meta_file=$(getMetaFile "$1")
    {
        echo "base_url=$BASE_URL"
        echo "app_path=$1"
        echo "start_time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "pid=$$"
    } > "$meta_file" 2>/dev/null
    return $?
}

# ------------------------------------------------------------------
# 関数名　　：readMeta
# 概要　　　：META読み込み
# 説明　　　：
#   META ファイルから base_url と start_time を取得する。
#   出力はタブ区切りとする。
#
# 引数　　　：1) app_path
# 戻り値　　：0=OK / 1=NG
# 出力　　　：base_url<TAB>start_time
# 使用箇所　：status/list
# ------------------------------------------------------------------
readMeta() {
    local meta_file
    local base_url
    local start_time

    meta_file=$(getMetaFile "$1")
    if [ ! -f "$meta_file" ]; then
        return 1
    fi

    base_url=$(grep '^base_url=' "$meta_file" 2>/dev/null | head -n 1 | sed 's/^base_url=//')
    start_time=$(grep '^start_time=' "$meta_file" 2>/dev/null | head -n 1 | sed 's/^start_time=//')

    printf "%s\t%s\n" "$base_url" "$start_time"
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：cmdList
# 概要　　　：常駐監視一覧表示
# 説明　　　：
#   PID_DIR の pid を列挙し、対象 context_path と pid と meta を表示する。
#
# 引数　　　：なし
# 戻り値　　：0
# 使用箇所　：-c list
# ------------------------------------------------------------------
cmdList() {
    local f
    local key
    local path
    local pid
    local pid_file
    local meta_line
    local base_url
    local start_time
    local state

    if [ ! -d "$PID_DIR" ]; then
        return 0
    fi

    for f in "$PID_DIR"/*.pid; do
        if [ ! -f "$f" ]; then
            continue
        fi

        key=$(basename "$f" .pid)
        path=$(keyToPath "$key")
        pid_file=$(getPidFile "$path")
        pid=$(cat "$pid_file" 2>/dev/null)

        if isPidAlive "$pid"; then
            state="running"
        else
            state="stale"
        fi

        meta_line=$(readMeta "$path")
        if [ $? -eq 0 ]; then
            base_url=$(printf "%s" "$meta_line" | cut -f 1)
            start_time=$(printf "%s" "$meta_line" | cut -f 2-)
            echo "$path pid=$pid state=$state base_url=$base_url start_time=$start_time"
        else
            echo "$path pid=$pid state=$state"
        fi
    done

    return 0
}

# ------------------------------------------------------------------
# 関数名　　：validateArgs
# 概要　　　：引数チェック
# 説明　　　：
#   コマンドごとに必須引数と排他制御を行う。
#
# 引数　　　：なし
# 戻り値　　：0=OK / 2=NG
# 使用箇所　：pre-process
# ------------------------------------------------------------------
validateArgs() {
    if [ -z "$CMD" ]; then
        logOut "ERROR" "Missing -c <command>."
        usage
        return 2
    fi

    case "$CMD" in
        list|status|show|start|stop) ;;
        *)
            logOut "ERROR" "Invalid command. -c [$CMD]"
            usage
            return 2
            ;;
    esac

    if [ "$CMD" = "list" ]; then
        return 0
    fi

    if [ -n "$APP_PATH" ] && [ -n "$APP_FILE" ]; then
        logOut "ERROR" "Target options are mutually exclusive. use -a OR -f."
        usage
        return 2
    fi

    if [ "$CMD" = "start" ] || [ "$CMD" = "show" ]; then
        if [ -z "$MANAGER_USER" ] || [ -z "$MANAGER_PASS" ]; then
            logOut "ERROR" "Missing -u or -p."
            usage
            return 2
        fi
        if [ -z "$BASE_URL" ]; then
            logOut "ERROR" "Missing -b."
            usage
            return 2
        fi
        if [ ! -f "$MANAGE_SCRIPT" ]; then
            logOut "ERROR" "manage script not found. path=[$MANAGE_SCRIPT]"
            return 2
        fi
    fi

    readTargets >/dev/null
    if [ $? -ne 0 ]; then
        usage
        return 2
    fi

    return 0
}

# ------------------------------------------------------------------
# 関数名　　：daemonMain
# 概要　　　：常駐監視本体
# 説明　　　：
#   1対象1常駐で監視する。
#   監視対象が stopped など running 以外になった場合は ERROR を出して restart を試行する。
#   その後、状態が running に回復した瞬間に INFO を出す（回復ログ）。
#
# 引数　　　：1) app_path
# 戻り値　　：なし（無限ループ）
# 使用箇所　：start（内部起動）
# ------------------------------------------------------------------
daemonMain() {
    local app_path="$1"
    local pid_file
    local state=""
    local state_rc=0
    local prev_state="unknown"

    isManagerReachable
    if [ $? -ne 0 ]; then
        logOut "ERROR" "Tomcat manager unreachable at daemon start. path=[$app_path]"
    else
        validateTargetExists "$app_path"
        if [ $? -ne 0 ]; then
            exit 2
        fi
    fi

    pid_file=$(getPidFile "$app_path")

    echo "$$" > "$pid_file"
    if [ $? -ne 0 ]; then
        logOut "ERROR" "Failed to write pid file. file=[$pid_file] path=[$app_path]"
        exit 2
    fi

    writeMeta "$app_path"
    if [ $? -ne 0 ]; then
        logOut "ERROR" "Failed to write meta. path=[$app_path]"
        exit 2
    fi

    while :; do
        isManagerReachable
        if [ $? -ne 0 ]; then
            logOut "ERROR" "Tomcat manager unreachable. try start unit=[$TOMCAT_UNIT] path=[$app_path]"
            prev_state="tomcat_down"

            startTomcat
            if [ $? -ne 0 ]; then
                logOut "ERROR" "Tomcat start failed. unit=[$TOMCAT_UNIT] path=[$app_path]"
                sleep "$CHECK_INTERVAL_SEC"
                continue
            fi

            sleep "$TOMCAT_BOOT_WAIT_SEC"
            sleep "$CHECK_INTERVAL_SEC"
            continue
        fi

        isAppKnown "$app_path"
        if [ $? -ne 0 ]; then
            logOut "ERROR" "Target disappeared. path=[$app_path]"
            prev_state="notfound"
            sleep "$CHECK_INTERVAL_SEC"
            continue
        fi

        state=$(getAppState "$app_path")
        state_rc=$?

        if [ $state_rc -eq 0 ] && [ "$state" = "running" ]; then
            if [ "$prev_state" != "running" ]; then
                logOut "INFO" "App recovered. path=[$app_path] prev=[$prev_state] curr=[running]"
            fi
            prev_state="running"
            sleep "$CHECK_INTERVAL_SEC"
            continue
        fi

        logOut "ERROR" "App down. path=[$app_path] state=[$state] -> restart"
        prev_state="$state"

        restartApp "$app_path"
        if [ $? -ne 0 ]; then
            logOut "ERROR" "App restart failed. path=[$app_path]"
        fi

        sleep "$TOMCAT_BOOT_WAIT_SEC"

        state=$(getAppState "$app_path")
        state_rc=$?

        if [ $state_rc -eq 0 ] && [ "$state" = "running" ]; then
            prev_state="running"
            logOut "INFO" "App recovered. path=[$app_path] curr=[running]"
        else
            prev_state="$state"
            logOut "ERROR" "App not recovered yet. path=[$app_path] curr=[$state] rc=[$state_rc]"
        fi

        sleep "$CHECK_INTERVAL_SEC"
    done
}

# ------------------------------------------------------------------
# 関数名　　：cmdStatus
# 概要　　　：常駐監視状態表示
# 説明　　　：
#   指定対象の常駐監視が動作しているかを表示する。
#
# 引数　　　：なし
# 戻り値　　：0
# 使用箇所　：-c status
# ------------------------------------------------------------------
cmdStatus() {
    readTargets | while IFS= read -r p; do
        pid_file=$(getPidFile "$p")
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null)
            if isPidAlive "$pid"; then
                meta=$(readMeta "$p")
                if [ $? -eq 0 ]; then
                    echo "$p running pid=$pid $meta"
                else
                    echo "$p running pid=$pid"
                fi
            else
                echo "$p stopped"
            fi
        else
            echo "$p stopped"
        fi
    done
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：cmdShow
# 概要　　　：即時状態確認
# 説明　　　：
#   Tomcat到達性とアプリ状態を表示する。
#
# 引数　　　：なし
# 戻り値　　：0
# 使用箇所　：-c show
# ------------------------------------------------------------------
cmdShow() {
    isManagerReachable
    if [ $? -ne 0 ]; then
        echo "TOMCAT unreachable"
        return 0
    fi

    echo "TOMCAT reachable"

    readTargets | while IFS= read -r p; do
        isAppKnown "$p"
        if [ $? -ne 0 ]; then
            echo "$p notfound"
            continue
        fi
        state=$(getAppState "$p")
        echo "$p $state"
    done
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：cmdStart
# 概要　　　：常駐監視開始
# 説明　　　：
#   対象ごとに常駐監視プロセスを起動する。
#   常駐は MODE=daemon により同一スクリプトを再実行して実現する。
#
# 引数　　　：なし
# 戻り値　　：0
# 使用箇所　：-c start
# ------------------------------------------------------------------
cmdStart() {
    readTargets | while IFS= read -r p; do
        pid_file=$(getPidFile "$p")

        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null)
            if isPidAlive "$pid"; then
                echo "$p already running pid=$pid"
                continue
            fi
        fi

        if validateTargetExists "$p"; then
            nohup env MODE=daemon sh "$0" -c start -b "$BASE_URL" -u "$MANAGER_USER" -p "$MANAGER_PASS" -a "$p" >/dev/null 2>&1 &


            echo "$p started"
        else
            echo "$p skipped (not found)"
        fi
    done
    return 0
}


# ------------------------------------------------------------------
# 関数名　　：cmdStop
# 概要　　　：常駐監視停止
# 説明　　　：
#   対象の PID を停止し、PID/META を削除する。
#
# 引数　　　：なし
# 戻り値　　：0
# 使用箇所　：-c stop
# ------------------------------------------------------------------
cmdStop() {
    readTargets | while IFS= read -r p; do
        pid_file=$(getPidFile "$p")
        meta_file=$(getMetaFile "$p")

        if [ ! -f "$pid_file" ]; then
            echo "$p not running"
            continue
        fi

        pid=$(cat "$pid_file" 2>/dev/null)
        if isPidAlive "$pid"; then
            kill "$pid" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo "$p stop failed pid=$pid"
                continue
            fi
            echo "$p stopped pid=$pid"
        else
            echo "$p stopped"
        fi

        rm -f "$pid_file" "$meta_file" >/dev/null 2>&1
    done

    return 0
}

# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

startLog
trap "terminate" 1 2 3 15

while getopts "c:b:u:p:a:f:" opt; do
    case "$opt" in
        c) CMD="$OPTARG" ;;
        b) BASE_URL="$OPTARG" ;;
        u) MANAGER_USER="$OPTARG" ;;
        p) MANAGER_PASS="$OPTARG" ;;
        a) APP_PATH="$OPTARG" ;;
        f) APP_FILE="$OPTARG" ;;
        *) usage; exitLog 2 ;;
    esac
done

setRunDirs

initDirs
if [ $? -ne 0 ]; then
    exitLog 2
fi

validateArgs
if [ $? -ne 0 ]; then
    exitLog 2
fi

# ------------------------------------------------------------------
# main-process
# ------------------------------------------------------------------
scope="main"

if [ "$MODE" = "daemon" ]; then
    APP_PATH=$(normalizePath "$APP_PATH")
    daemonMain "$APP_PATH"
    exit 0
fi

case "$CMD" in
    list)
        cmdList
        RC=$?
        ;;
    status)
        cmdStatus
        RC=$?
        ;;
    show)
        cmdShow
        RC=$?
        ;;
    start)
        cmdStart
        RC=$?
        ;;
    stop)
        cmdStop
        RC=$?
        ;;
    *)
        usage
        RC=2
        ;;
esac

# ------------------------------------------------------------------
# 終了処理
# ------------------------------------------------------------------
scope="post"

exitLog $RC
