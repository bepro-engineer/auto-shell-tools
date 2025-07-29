#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# rotateLog.sh
# ver.1.0.0  2025.07.25
#
# Usage:
#     sh rotateLog.sh -f <source_path> -t <target_dir> -g <generation> -m <compress_mode>
#
# Description:
#    ログファイルのローテーションと世代管理を行う汎用スクリプト
#    - 世代数を超えたファイルは自動削除
#    - オプションで圧縮（bzip2）対応
#    - 使用例：
#        sh rotateLog.sh -f /var/log/syslog -t /backup/logs -g 5 -m 1
#
#    ＜引数＞
#        -f : 対象ログファイルまたはディレクトリ
#        -t : バックアップ先ディレクトリ
#        -g : 保持する世代数（1以上の整数）
#        -m : 圧縮モード（0:非圧縮, 1:bzip2圧縮）
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  RL-0001    2025/07/25  Bepro       新規作成（logger対応・圧縮・世代削除）
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"

runAs       root "$@"
setLANG     utf-8
setLogLevel ${LOG_LEVEL:-info}

# ------------------------------------------------------------------
# グローバル変数
# ------------------------------------------------------------------
src_path=""
dst_dir=""
gen_cnt=""
mode=""
step="pre"
hostname=$(hostname -s)
suffix="-$(date '+%Y%m%d%H%M%S')"
pattern1='-20[0-9]{12}$'
pattern2='-20[0-9]{12}\.tar\.bz2$'

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------

checkArgs() {
    if [ -z "$src_path" ]; then
        logOut "ERROR" "オプション -f（対象ファイル）が指定されていません。"
        exitLog 2
    fi
    if [ ! -e "$src_path" ]; then
        logOut "ERROR" "対象ファイル [$src_path] が存在しません。"
        exitLog 2
    fi

    if [ -z "$dst_dir" ]; then
        logOut "ERROR" "オプション -t（出力先ディレクトリ）が指定されていません。"
        exitLog 2
    fi
    if [ ! -d "$dst_dir" ]; then
        logOut "ERROR" "出力先ディレクトリ [$dst_dir] が存在しません。"
        exitLog 2
    fi

    if [ -z "$gen_cnt" ]; then
        logOut "ERROR" "オプション -g（保持世代数）が指定されていません。"
        exitLog 2
    fi
    if echo "$gen_cnt" | grep -q '[^0-9]'; then
        logOut "ERROR" "保持世代数 [$gen_cnt] は正の整数で指定してください。"
        exitLog 2
    fi

    if echo "$mode" | grep -q '[^01]'; then
        logOut "ERROR" "圧縮モード [$mode] は 0 または 1 のみ有効です。"
        exitLog 2
    fi
}

checkTarget() {
    if [ -d "$1" ] || echo "$1" | grep -q -e "$pattern1" -e "$pattern2"; then
        return 0  # skip対象
    fi
    return 1
}

# ------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------

startLog
setLogMode ${LOG_MODE:-standard}

# 引数取得
while getopts f:t:g:m: opt; do
    case $opt in
        f) src_path=$OPTARG ;;
        t) dst_dir=$OPTARG ;;
        g) gen_cnt=$OPTARG ;;
        m) mode=$OPTARG ;;
        *) logOut "ERROR" "不正なオプションです。"; exitLog 2 ;;
    esac
done

logOut "INFO" "引数: -f $src_path -t $dst_dir -g $gen_cnt -m $mode"
mode=${mode:-0}
checkArgs

step="main"

[ -d "$src_path" ] && src_path="${src_path%/}/*"

cd "$dst_dir"

for file in $src_path; do
    if checkTarget "$file"; then
        continue
    fi
    logOut "DEBUG" "ローテーション対象: $(basename "$file")"

    if [ "$mode" -eq 0 ]; then
        cp -pf "$file" "${dst_dir%/}/$(basename "$file")${suffix}"
    else
        dst_file="${dst_dir%/}/$(basename "$file")${suffix}.tar.bz2"
        if ! sh "${BASE_PATH}/bin/compress.sh" -f "$file" -t "$dst_file" -m 0; then
            logError "圧縮失敗：[$file]"
            exitLog ${JOB_ER}
        fi

    fi

    cat /dev/null > "$file"

    # 世代削除処理
    escaped_name=$(echo "$(basename "$file")" | sed 's/[]\.|$(){}?+*^]/\\&/g')
    file_list=$(ls -tF | ls -rF | grep -E "^${escaped_name}${pattern1}|^${escaped_name}${pattern2}")
    file_cnt=$(echo "$file_list" | wc -l)

    if [ "$file_cnt" -gt "$gen_cnt" ]; then
        echo "$file_list" | tail -n $((file_cnt - gen_cnt)) | xargs rm -f
        logOut "INFO" "古い世代を削除しました：$(basename "$file")"
    fi
done

# ------------------------------------------------------------------
# 終了処理
# ------------------------------------------------------------------
step="post"
exitLog 0
