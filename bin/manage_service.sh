#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# manage_service.sh
# ver.1.1.0  2025.07.24
#
# Usage:
#     sh manage_service.sh -s <service_name> -c <command>
#
# Description:
#    任意の systemd サービスを制御する汎用スクリプト（getopts対応）
#    - ログ出力に対応（logger.shrc 準拠）
#    - 使用例：
#        sh manage_service.sh -s httpd -c start
#        sh manage_service.sh -s sshd -c status
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  〇〇〇〇〇    2025/07/24  Bepro       getopts対応／ファイル名変更
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/logger.shrc"
. "$(dirname "$0")/../com/utils.shrc"
setLANG     utf-8

# ------------------------------------------------------------------
# variables （変数の宣言領域）
# ------------------------------------------------------------------
scope="var"

rc=0
SERVICE_NAME=""
CMD=""

# ----------------------------------------------------------
# functions （関数を記述する領域）
# ----------------------------------------------------------
scope="func"

# 使い方表示
showUsage() {
    cat << EOF
--------------------------------------
Usage:
  sh manage_service.sh -s <service_name> -c <command>

Options:
  -s service_name : 対象の systemd サービス名
  -c command      : 実行する操作（start|stop|restart|graceful|graceful-stop|status）

Commands:
  start           - Start the service
  stop            - Stop the service
  restart         - Restart the service
  graceful        - Reload the service (if supported)
  graceful-stop   - Graceful stop (fallback to stop)
  status          - Show service status
--------------------------------------
Example:
  sh manage_service.sh -s httpd -c start
  sh manage_service.sh -s sshd -c status
EOF
}

# サービスの起動状態を確認
isServiceRunning() {
    systemctl is-active --quiet "$1"
    return $?
}

# サービスの状態を表示
displayStatus() {
    local service="$1"
    if isServiceRunning "$service"; then
        logOut "INFO" "$service is running."
    else
        logOut "INFO" "$service is not running."
    fi
}

# ------------------------------------------------------------------
# pre-process （事前処理ロジックを記述する領域）
# ------------------------------------------------------------------
scope="pre"

# getopts
while getopts "s:c:" opt; do
    case "$opt" in
        s) SERVICE_NAME="$OPTARG" ;;
        c) CMD="$OPTARG" ;;
        *) showUsage; exit 2 ;;
    esac
done

startLog
logOut "INFO" "Args: [-s $SERVICE_NAME -c $CMD]"
trap ":" 0 1 2 3 15

# 入力チェック
if [ -z "$SERVICE_NAME" ] || [ -z "$CMD" ]; then
    logOut "ERROR" "引数が不足しています。"
    showUsage
    exitLog 2
fi

# ------------------------------------------------------------------
# main-process （メインロジックを記述する領域）
# ------------------------------------------------------------------
scope="main"

case "$CMD" in
    start)
        if isServiceRunning "$SERVICE_NAME"; then
            logOut "WARNING" "$SERVICE_NAME is already running."
        else
            logOut "INFO" "Starting $SERVICE_NAME..."
            systemctl start "$SERVICE_NAME"
        fi
        ;;
    stop)
        if ! isServiceRunning "$SERVICE_NAME"; then
            logOut "WARNING" "$SERVICE_NAME is already stopped."
        else
            logOut "INFO" "Stopping $SERVICE_NAME..."
            systemctl stop "$SERVICE_NAME"
        fi
        ;;
    restart)
        logOut "INFO" "Restarting $SERVICE_NAME..."
        systemctl restart "$SERVICE_NAME"
        ;;
    graceful)
        logOut "INFO" "Reloading $SERVICE_NAME..."
        systemctl reload "$SERVICE_NAME"
        ;;
    graceful-stop)
        logOut "INFO" "Graceful stop not supported. Falling back to stop..."
        systemctl stop "$SERVICE_NAME"
        ;;
    status)
        displayStatus "$SERVICE_NAME"
        ;;
    *)
        logOut "ERROR" "Invalid command: [$CMD]"
        showUsage
        exitLog 2
        ;;
esac

sleep 1

if [ "$CMD" != "status" ]; then
    displayStatus "$SERVICE_NAME"
fi

# ----------------------------------------------------------
# post-process （事後処理ロジックを記述する領域）
# ----------------------------------------------------------
scope="post"

exitLog $rc
