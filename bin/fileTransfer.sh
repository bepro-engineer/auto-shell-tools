#!/bin/sh
# fileTransfer.sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# 関数名　　：fileTransfer.sh（スクリプト本体）
# 概要　　　：ファイル送受信の状態管理付き転送処理
# 説明　　　：
#   指定されたファイルを送信側・受信側で管理する仕組みを一体化し、
#   .end/.fin ファイルによる状態遷移を制御しながらファイルの整合性を保証する。
#   処理モードは `-m send` または `-m recv` により切り替えられる。
#   送信時はMD5でハッシュ検証後に`.end`を出力、受信時は`.end`確認後に`.fin`を出力。
#   ロック制御によって多重起動を防止し、安全な排他処理を実現する。
#   また、不正なユーザーでの実行や引数不足、ファイル不整合時には即座にエラー終了する。
#
# 引数　　　：
#   -m <mode>        ："send" または "recv" を指定（処理モード）
#   -f <file_path>   ：処理対象のファイルパス
#   -t <target_dir>  ：出力先または受信先ディレクトリのパス
#
# 戻り値　　：
#   0（正常終了）、1（警告）、2（異常終了）※JOB_OK, JOB_WR, JOB_ERで制御
#
# 使用箇所　：
#   - システム間の中間ファイル転送
#   - バッチ処理での安全なファイル受け渡し
#   - 統合システムやETL的用途でのデータ連携ステップ
# ------------------------------------------------------------------
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  PR-0001    2025/07/30 Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# 共通クラスの読み込み
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
setLANG     utf-8
runAs root "$@"

# ------------------------------------------------------------------
# variables （変数の宣言領域）
# ------------------------------------------------------------------
scope="var"

# ========================================
# 定数定義
# ========================================
readonly JOB_OK=0
readonly JOB_WR=1
readonly JOB_ER=2

# ----------------------------------------------------------
# functions （関数を記述する領域）
# ----------------------------------------------------------
scope="func"

# ------------------------------------------------------------------
# 関数名　　：terminate
# 概要　　　：終了時のロック解除処理
# 戻り値　　：なし
# 使用箇所　：trapによる終了時呼び出し
# ------------------------------------------------------------------
terminate() {
    releaseLock
}

# ------------------------------------------------------------------
# 関数名　　：getFileStatus
# 概要　　　：ファイル転送状態を判定（INITIAL/LOADING/LOADED/COMPLETED）
# 引数　　　：$1 = 対象ファイルのパス
# 戻り値　　：状態文字列（INITIAL等）
# 使用箇所　：送信・受信処理判定時
# ------------------------------------------------------------------
getFileStatus() {
    status="UNEXPECTED"
    [ ! -f "$1" ] && [ ! -f "$1.end" ] && [ ! -f "$1.fin" ] && status="INITIAL"
    [   -f "$1" ] && [ ! -f "$1.end" ] && [ ! -f "$1.fin" ] && status="LOADING"
    [   -f "$1" ] && [   -f "$1.end" ] && [ ! -f "$1.fin" ] && status="LOADED"
    [   -f "$1" ] && [   -f "$1.end" ] && [   -f "$1.fin" ] && status="COMPLETED"
    echo "$status"
}

# ------------------------------------------------------------------
# 関数名　　：checkArgs
# 概要　　　：引数の妥当性確認（ファイル・ディレクトリ存在）
# 引数　　　：$1 = 入力ファイルパス、$2 = 出力ディレクトリパス
# 戻り値　　：なし（異常時はexit）
# 使用箇所　：main処理前
# ------------------------------------------------------------------
checkArgs() {
    if [ $# -lt 2 ]; then
        logOut "ERROR" "Insufficient number of arguments."
        exit ${JOB_ER}
    fi

    if echo "$1" | grep -q '[*?]'; then
        logOut "ERROR" "Wildcard characters are not allowed in file path: [$1]"
        exit ${JOB_ER}
    fi

    if [ ! -f "$1" ]; then
        logOut "ERROR" "Specified file does not exist: [$1]"
        exit ${JOB_ER}
    fi

    if [ ! -d "$2" ]; then
        logOut "ERROR" "Specified directory does not exist: [$2]"
        exit ${JOB_ER}
    fi
}

# ------------------------------------------------------------------
# 関数名　　：usage
# 概要　　　：使用方法を表示して終了
# 引数　　　：なし
# 戻り値　　：なし（常にexit）
# 使用箇所　：引数ミス時
# ------------------------------------------------------------------
usage() {
    echo "Usage: $0 -m <send|recv> -f <file_path> -t <target_dir>"
    echo "  -m mode        (send = send file, recv = receive file)"
    echo "  -f file path   (path to the source file)"
    echo "  -t target dir  (path to the destination directory)"
    exit ${JOB_ER}
}

# ------------------------------------------------------------------
# 引数解析（getopts）
# ------------------------------------------------------------------
mode=""
src_fp=""
dst_dir=""

while getopts "m:f:t:" opt; do
    case "$opt" in
        m) mode="$OPTARG" ;;
        f) src_fp="$OPTARG" ;;
        t) dst_dir="$OPTARG" ;;
        *) usage ;;
    esac
done

# 引数が一つもなければ usage 表示
if [ "$OPTIND" -eq 1 ]; then
    logOut "ERROR" "No arguments provided."
    usage
fi

if [ -z "$mode" ] || [ -z "$src_fp" ] || [ -z "$dst_dir" ]; then
    logOut "ERROR" "Missing required arguments."
    usage
fi

# モード値の妥当性チェック
if [ "$mode" != "send" ] && [ "$mode" != "recv" ]; then
    logOut "ERROR" "Invalid mode specified: [$mode]"
    usage
fi

# ------------------------------------------------------------------
# pre-process （事前処理ロジックを記述する領域）
# ------------------------------------------------------------------
scope="pre"

startLog
trap "terminate" 0 1 2 3 15

if ! acquireLock; then
    logOut "ERROR" "排他ロックを取得できませんでした。"
    exit ${JOB_ER}
fi

checkArgs "$src_fp" "$dst_dir"
dst_fp="${dst_dir}/${src_fp##*/}"

# ------------------------------------------------------------------
# main-process （メインロジックを記述する領域）
# ------------------------------------------------------------------
scope="main"

if [ "$mode" = "send" ]; then

    # =========================
    # モード: 送信（sender側）
    # =========================
    file_stat=$(getFileStatus "$dst_fp")
    logOut "INFO" "送信先ファイル [$dst_fp] の状態: [$file_stat]"

    if [ "$file_stat" = "UNEXPECTED" ]; then
        logOut "ERROR" "不正な状態のファイルが存在します。: [$dst_fp]"
        exit ${JOB_ER}
    fi

    if [ "$file_stat" = "COMPLETED" ]; then
        for f in "$dst_fp" "$dst_fp.end" "$dst_fp.fin"; do
            logOut "INFO" "既存ファイルを削除します: $f"
            rm -f "$f" || {
                logOut "ERROR" "ファイル削除に失敗しました: $f"
                exit ${JOB_ER}
            }
        done
        file_stat="INITIAL"
    fi

    if [ "$file_stat" = "LOADED" ]; then
        logOut "INFO" "受信側が未完了のため、送信スキップ: [$dst_fp.end]"
        exit ${JOB_OK}
    fi

    if [ "$file_stat" = "INITIAL" ] || [ "$file_stat" = "LOADING" ]; then
        cp -pf "$src_fp" "$dst_fp"
        if [ $? -ne 0 ]; then
            logOut "ERROR" "ファイルのコピーに失敗しました。"
            exit ${JOB_ER}
        fi

        src_hash=$(getMd5sum "$src_fp")
        dst_hash=$(getMd5sum "$dst_fp")

        if [ "$src_hash" != "$dst_hash" ]; then
            logOut "ERROR" "MD5値が一致しません。転送失敗 [$src_hash] != [$dst_hash]"
            exit ${JOB_ER}
        fi

        echo "$src_hash" > "${dst_fp}.end"
        logOut "INFO" "送信完了。MD5一致: [$src_hash]"
    fi

elif [ "$mode" = "recv" ]; then

    # =========================
    # モード: 受信（receiver側）
    # =========================
    file_stat=$(getFileStatus "$src_fp")
    logOut "INFO" "受信元ファイル [$src_fp] の状態: [$file_stat]"

    if [ "$file_stat" = "UNEXPECTED" ]; then
        logOut "ERROR" "不正な状態のファイルが存在します。: [$src_fp]"
        exit ${JOB_ER}
    fi

    if [ "$file_stat" = "COMPLETED" ]; then
        logOut "INFO" "受信済みです。 [$src_fp.fin]"
        exit ${JOB_OK}
    fi

    if [ "$file_stat" = "INITIAL" ] || [ "$file_stat" = "LOADING" ]; then
        logOut "INFO" "送信処理が未完了のため、受信スキップします。"
        exit ${JOB_OK}
    fi

    if [ "$file_stat" = "LOADED" ]; then
        cp -pf "$src_fp" "$dst_fp"
        if [ $? -ne 0 ]; then
            logOut "ERROR" "ファイルの受信に失敗しました。"
            exit ${JOB_ER}
        fi

        org_hash=$(cat "${src_fp}.end")
        new_hash=$(getMd5sum "$dst_fp")

        if [ "$org_hash" != "$new_hash" ]; then
            logOut "ERROR" "MD5検証失敗。 [$org_hash] != [$new_hash]"
            exit ${JOB_ER}
        fi

        touch "${src_fp}.fin"
        logOut "INFO" "受信完了。MD5一致: [$new_hash]"
    fi
fi

# ----------------------------------------------------------
# post-process （事後処理ロジックを記述する領域）
# ----------------------------------------------------------
scope="post"

logOut "INFO" "fileTransfer.sh を正常終了します。"
exitLog ${JOB_OK}
