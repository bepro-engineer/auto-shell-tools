#!/bin/sh
# ------------------------------------------------------------------
# スクリプト名　：disk_alert.sh
# 概要　　　　：ディスク使用率を監視し、しきい値超過を通知
# 説明　　　　：
#   - ディスク設定ファイルに記載された各ファイルシステムを対象に監視
#   - 使用率が警告・致命的閾値を超えた場合に記録・ログ出力
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# 初期処理：共通関数・ログ読み込み
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
setLANG utf-8
runAs root "$@"

# ------------------------------------------------------------------
# グローバル変数定義
# ------------------------------------------------------------------
scope="var"

readonly JOB_OK=0
readonly JOB_ER=2

host_id=$(hostname -s)
exec_time=$(date "+%Y-%m-%d %H:%M:%S")
threshold_file="${ETC_PATH}/${host_id}/disk_threshold.conf"
usage_file="${TMP_PATH}/disk_alert.df"
record_file="${TMP_PATH}/disk_alert.rep"
file_system=""  # ← loggerで使用される変数は先に空で宣言しておく

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

# 終了処理：ロック解除と一時ファイル削除
terminate() {
    releaseLock
    [ -f "$usage_file" ] && rm -f "$usage_file"
}

# 使用方法表示（テストモード対応）
usage() {
    echo "Usage: $0 [-f <df_output_file>] [-t <exec_time>]"
    echo "  -f : df出力ファイルを指定（テストモード用）"
    echo "  -t : 実行日時を指定（例：\"2025-08-03 01:00:00\"）"
    exit ${JOB_ER}
}

# 引数解析（getopts）
parseArgs() {
    while getopts "f:t:" opt; do
        case "$opt" in
            f) usage_file="$OPTARG" ;;
            t) exec_time="$OPTARG" ;;
            *) usage ;;
        esac
    done
}

# 閾値・記録ファイルのロード
loadThreshold() {
    [ ! -f "$threshold_file" ] && logOut "ERROR" "閾値ファイルがありません: $threshold_file" && exitLog ${JOB_ER}
    [ ! -f "$record_file" ] && touch "$record_file"
}

# df情報取得（引数が無いときのみ）
collectDiskUsage() {
    df -P | tail -n +2 > "$usage_file"
}

# ------------------------------------------------------------------
# pre-process（事前処理）
# ------------------------------------------------------------------
scope="pre"

parseArgs "$@"

# 処理日時の初期化
if [ -z "$exec_time" ]; then
    exec_time=$(date "+%Y-%m-%d %H:%M:%S")
fi

startLog
logOut "INFO" "Args: [-f $usage_file -t $exec_time]"

if acquireLock; then
    logOut "INFO" "Lock acquired"
else
    abort "Lock acquisition failed."
fi

trap "terminate" 0 1 2 3 15
loadThreshold

[ -z "$usage_file" ] && usage_file="${TMP_PATH}/disk_alert.df"
[ ! -f "$usage_file" ] && collectDiskUsage

# ------------------------------------------------------------------
# main-process（ディスクごとの処理）
# ------------------------------------------------------------------
scope="main"

grep -v '^\s*#' "$threshold_file" | while read fs warn_crit warn_thres crit_thres; do
    logOut "DEBUG" "Checking FS: $fs"

    usage_line=$(grep -w "$fs" "$usage_file")

    if [ -z "$usage_line" ]; then
        logOut "WARN" "Filesystem not found in df output: $fs"
        continue
    fi

    usage_now=$(echo "$usage_line" | awk 'NF >= 2 {print $(NF-1)}' | sed 's/%//')

    if [ -z "$usage_now" ]; then
        logOut "WARN" "Unknown filesystem: $fs"
        continue
    fi

    logOut "INFO" "Usage for $fs = ${usage_now}% / Warn=${warn_thres}% / Crit=${crit_thres}%"

    if [ "$usage_now" -ge "$warn_thres" ]; then
        echo "$fs ${usage_now}% $exec_time" >> "$record_file"
        logOut "WARN" "Usage exceeded: ${usage_now}% for $fs"
    else
        grep -vw "$fs" "$record_file" > "${record_file}.tmp" && mv "${record_file}.tmp" "$record_file"
        logOut "DEBUG" "Usage normal: $fs"
    fi

    count_exceed=$(grep -cw "$fs" "$record_file")
    logOut "INFO" "Exceed count for $fs: $count_exceed / Threshold: $warn_crit"

    if [ "$count_exceed" -ge "$warn_crit" ]; then
        # ------------------------------------------------------
        # logSystemのmessage.conf評価で必要な変数を事前にexport
        # ------------------------------------------------------
        export fs usage_now count_exceed warn_crit warn_thres crit_thres SCRIPT_NAME

        if [ "$usage_now" -ge "$crit_thres" ]; then
            logSystem "21003"  # 致命的使用率超過 → crit閾値をsrcに含める
        else
            logSystem "11003"  # 警告使用率超過 → warn閾値をsrcに含める
        fi
    fi
done

# ------------------------------------------------------------------
# post-process（終了処理）
# ------------------------------------------------------------------
scope="post"
exitLog ${JOB_OK}
