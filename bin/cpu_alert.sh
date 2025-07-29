#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# 関数名　　：cpu_alert.sh
# 概要　　　：CPU使用率の監視とアラート出力
# 説明　　　：
#   CPU使用率を取得し、あらかじめ定義された閾値と比較する。
#   閾値を超えた回数を記録ファイル（cpu.rep）に保持し、一定回数を超過した場合に
#   通知メッセージをlogger経由でsyslogに出力する。
#   閾値内に戻った場合は記録ファイルをリセットすることで、常に最新状態を監視する。
#   サーバーの負荷傾向を記録・監視し、異常を早期に検知する目的で使用される。
#
# 引数　　　：なし（デバッグ用途として引数による強制実行も可能）
#
# 戻り値　　：
#   0 : 正常終了
#   1 : 異常終了（設定ファイル未存在など）
#
# 使用箇所　：cronや他の監視スクリプトから定期的に呼び出されることを想定
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  PR-0001    2025/07/16 Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期化処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
setLANG utf-8

# ------------------------------------------------------------------
# variables
# ------------------------------------------------------------------
scope="var"

host_id=`hostname -s`
conf_path="$ETC_PATH/$host_id/cpu_threshold.conf"
rep_path="$TMP_PATH/cpu_alert.rep"
now_time=`date "+%Y-%m-%d %H:%M:%S"`

# ------------------------------------------------------------------
# functions
# ------------------------------------------------------------------
scope="func"

# 処理中断時のクリーンアップ処理
terminate() {
    releaseLock
}

# 閾値ファイル・記録ファイルの存在確認
# param1: 閾値設定ファイル
# param2: 記録ファイル
validateFiles() {
    [ ! -f "$1" ] && logOut "ERROR" "Missing config: $1" && exitLog ${JOB_ER}
    [ ! -f "$2" ] && touch "$2"
}

# 引数数の検証（0 または 2 のみ許容）
validateArgs() {
    [ "$1" -ne 0 ] && [ "$1" -ne 2 ] && logOut "ERROR" "Argument count invalid." && exitLog ${JOB_ER}
}

# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

startLog
logOut "INFO" "Received args: [$@]"

if acquireLock; then
    logOut "INFO" "Lock status: OK"
else
    abort "Lock acquisition failed."
fi

trap "terminate" 0 1 2 3 15

validateFiles "$conf_path" "$rep_path"
validateArgs $#

# ------------------------------------------------------------------
# main-process
# ------------------------------------------------------------------
scope="main"

if [ $# -eq 0 ]; then
    cpu_usage=`getCpuUtilization`
else
    cpu_usage=$1
    now_time=$2
fi

read threshold_count warn_limit critical_limit < <(grep -v '^\s*#' "$conf_path" | head -n 1 | awk '{gsub(/%/, "", $2); gsub(/%/, "", $3); print $1, $2, $3}')

cpu_usage_int=`echo "$cpu_usage" | awk '{printf("%d", $1)}'`

logOut "INFO" "Threshold(WARN): ${warn_limit} %"
logOut "INFO" "Current Usage   : ${cpu_usage_int} %"
logOut "DEBUG" "Execution Time  : ${now_time}"

if [ "$cpu_usage_int" -ge "$warn_limit" ]; then
    echo "${cpu_usage_int}% $now_time" >> "$rep_path"
    logOut "WARN" "CPU usage exceeded: ${cpu_usage_int}%"
else
    if [ -s "$rep_path" ]; then
        > "$rep_path"
        logOut "INFO" "Reset alert history: $rep_path"
    fi
    logOut "DEBUG" "Usage within limits."
fi

count_exceed=`wc -l < "$rep_path" | tr -d ' '`
logOut "INFO" "Exceed count: ${count_exceed}"

if [ "$count_exceed" -ge "$threshold_count" ]; then
    if [ "$cpu_usage_int" -ge "$critical_limit" ]; then
        logSystem "21004"
    else
        logSystem "11004"
    fi
fi

# ------------------------------------------------------------------
# post-process
# ------------------------------------------------------------------
scope="post"

exitLog ${JOB_OK}
