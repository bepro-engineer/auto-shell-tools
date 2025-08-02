#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# スクリプト名　：resource_alert.sh
# 概要　　　　：CPUまたはメモリ使用率を監視し、しきい値超過を通知
# 説明　　　　：
#   本スクリプトは、システムリソースのうち CPU またはメモリを対象として、
#   使用率を取得し、事前に設定された WARN/CRITICAL しきい値と比較します。
#   閾値を超過した回数を記録し、指定回数以上となった場合にログ通知を行います。
#   対象リソースは `-m cpu` または `-m mem` により明示的に指定します。
#   関連設定は /etc 配下の threshold.conf、記録は tmp 配下の repファイルに出力されます。
#   使用率の取得には `top`（CPU）および `free`（MEM）コマンドを使用します。
#   ログは logSystem 関数を介して user.warn / user.err として一元出力されます。
#
# 使用方法　　：sh resource_alert.sh -m cpu
# 　　　　　　：sh resource_alert.sh -m mem
#
# 依存関係　　：logger.shrc / utils.shrc / cpu_threshold.conf / mem_threshold.conf
#
# 注意事項　　：
#   - 引数は必ず -m オプションで指定すること（getopts必須）
#   - 使用率は内部で自動取得され、外部引数では上書きできない
#   - 閾値ファイル形式は「回数 警告% 致命%」の順で1行目に定義される
#   - ログIDはリソース別に固定：CPU=11004/21004、MEM=11003/21003
#   - スクリプトはロック機構を持ち、同時実行を排除する
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  SYS-00001   2025/07/30  Bepro       新規作成（CPU/MEM統合）
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
setLANG utf-8
runAs root "$@"

# ------------------------------------------------------------------
# 変数定義
# ------------------------------------------------------------------
scope="var"

readonly JOB_OK=0
readonly JOB_ER=2

host_id=$(hostname -s)
exec_time=$(date "+%Y-%m-%d %H:%M:%S")

type=""
threshold_file=""
record_file=""
usage_val=""
usage_int=""

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

# 終了処理（ロック解除）
terminate() {
    releaseLock
}

# 使用方法表示
usage() {

  cat <<EOUSAGE
  -----------------------------------------------------------------
  Usage: $0 -m <type>

     Options:
       -m type      : Specify resource type to monitor (cpu or mem)

  Example:
     $0 -m cpu
     $0 -m mem
  -----------------------------------------------------------------
EOUSAGE

  exit ${JOB_ER}
}

# 引数解析（getopts）
parseArgs() {
    while getopts "m:" opt; do
        case "$opt" in
            m)
                type="$OPTARG"
                ;;
            *)
                usage; exit ${JOB_ER} 
                ;;
        esac
    done

    # -m 未指定または不正値ならエラー
    if [ -z "$type" ] || ! echo "$type" | grep -qE '^(cpu|mem)$'; then
        logOut "ERROR" "Invalid or missing -m argument."
        usage
    fi
}

# CPU使用率取得（整数%）
getCpuUtilization() {
    top -bn1 | grep "Cpu(s)" | \
        awk -F'id,' '{ split($1, vs, ","); v=vs[length(vs)]; sub("%", "", v); printf("%.0f", 100 - v) }'
}

# メモリ使用率取得（整数%）
getMemUtilization() {
    free | awk '/Mem:/ { printf("%.0f", ( ($2 - $7) / $2 ) * 100 ) }'
}

# 閾値・記録ファイルのロード
loadThreshold() {
    threshold_file="$ETC_PATH/$host_id/${type}_threshold.conf"
    record_file="$TMP_PATH/${type}_alert.rep"

    [ ! -f "$threshold_file" ] && logOut "ERROR" "Missing threshold file: $threshold_file" && exitLog ${JOB_ER}
    [ ! -f "$record_file" ] && touch "$record_file"

    read threshold_count warn_limit critical_limit < <(
        grep -v '^\s*#' "$threshold_file" | head -n 1 | awk '{gsub(/%/, "", $2); gsub(/%/, "", $3); print $1, $2, $3}'
    )
}

# ------------------------------------------------------------------
# pre-process（事前処理）
# ------------------------------------------------------------------
scope="pre"

parseArgs "$@"
startLog
logOut "INFO" "Args: -m $type"

if acquireLock; then
    logOut "INFO" "Lock acquired"
else
    abort "Lock acquisition failed."
fi

trap "terminate" 0 1 2 3 15
loadThreshold

# ------------------------------------------------------------------
# main-process（メイン処理）
# ------------------------------------------------------------------
scope="main"

if [ "$type" = "cpu" ]; then
    usage_raw_val=$(getCpuUtilization)
else
    usage_raw_val=$(getMemUtilization)
fi

usage_val_int=$(echo "$usage_raw_val" | awk '{printf("%d", $1)}')
threshold=$warn_limit

logOut "INFO"  "Threshold        : ${threshold} %"
logOut "INFO"  "Current Usage    : ${usage_val_int} %"
logOut "DEBUG" "Execution Time   : ${exec_time}"

# 使用率が閾値以上なら記録
if [ "$usage_val_int" -ge "$threshold" ]; then
    echo "${usage_val_int}% $exec_time" >> "$record_file"
    logOut "WARN" "Usage exceeded: ${usage_val_int}%"
else
    if [ -s "$record_file" ]; then
        > "$record_file"
        logOut "INFO" "Reset alert history: $record_file"
    fi
    logOut "DEBUG" "Usage within normal range."
fi

# 超過カウント取得
count_exceed=$(wc -l < "$record_file" | tr -d ' ')
# 超過カウント取得
count_exceed=$(wc -l < "$record_file" | tr -d ' ')

logOut "DEBUG" "threshold_count=$threshold_count"
logOut "DEBUG" "count_exceed=$count_exceed"
logOut "DEBUG" "record_file content:"
cat "$record_file" >&2

logOut "INFO" "Exceed count: $count_exceed"

# 致命的判定とログ出力（対象別）
if [ "$count_exceed" -ge "$threshold_count" ]; then
    if [ "$type" = "cpu" ]; then
        [ "$usage_val_int" -ge "$critical_limit" ] && logSystem "21001" || logSystem "11001"
    else
        [ "$usage_val_int" -ge "$critical_limit" ] && logSystem "21002" || logSystem "11002"
    fi
fi

# ------------------------------------------------------------------
# post-process（終了処理）
# ------------------------------------------------------------------
scope="post"
exitLog ${JOB_OK}
