#!/bin/sh
# ------------------------------------------------------------------
# 関数名　　：dirTransfer.sh
# 概要　　　：ディレクトリ単位の信頼性の高い転送（コピー／移動）
# 説明　　　：
#   rsyncを使用して一時ディレクトリへ完全転送し、完了後にrenameでアトミックに入れ替える。
#   - コピー（mode=0）または移動（mode=1）に対応。
#   - 転送先に同名ディレクトリが存在する場合は削除して上書き。
#   - 親子ディレクトリ誤設定による破壊的動作を防ぐ安全設計。
#
# 引数　　　：
#   -d <source_dir>   ：転送元ディレクトリ
#   -t <target_dir>   ：転送先のベースディレクトリ（直下に配置される）
#   -m <mode>         ：0=copy, 1=move（数字で指定）
#
# 戻り値　　：0=成功, 2=異常
# 使用箇所　：ファイル連携、バックアップ、ディレクトリ同期等
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
# 関数名　　：usage
# 概要　　　：使用方法の表示
# 説明　　　：
#   引数が不足または不正な場合に呼び出され、実行を終了させる。
# 引数　　　：なし
# 戻り値　　：なし（exit 2）
# 使用箇所　：引数パース後のチェック
# ------------------------------------------------------------------
usage() {
    echo "Usage: $0 -f <source_dir> -t <target_dir> -m <0|1>"
    echo "  -d source directory"
    echo "  -t destination directory"
    echo "  -m mode: 0 = copy, 1 = move"
    exit ${JOB_ER}
}

# ------------------------------------------------------------------
# checkArgs
# 概要　　　：引数の妥当性を検証
# 説明　　　：
#   ディレクトリ存在確認、ワイルドカード排除、親子関係の検出など
# 引数　　　：$1 = src_dir, $2 = dst_dir, $3 = mode
# 戻り値　　：なし（エラー時 exit）
# 使用箇所　：main前の検証ステップ
# ------------------------------------------------------------------
checkArgs() {
    if [ $# -lt 3 ]; then
        logOut "ERROR" "Insufficient arguments."
        usage
    fi

    if echo "$1" | grep -q '[*?]' || echo "$2" | grep -q '[*?]'; then
        logOut "ERROR" "Wildcard characters are not allowed in path."
        exit ${JOB_ER}
    fi

    if [ ! -d "$1" ]; then
        logOut "ERROR" "Source directory does not exist: $1"
        exit ${JOB_ER}
    fi

    if [ ! -d "$2" ]; then
        logOut "ERROR" "Target directory does not exist: $2"
        exit ${JOB_ER}
    fi

    if echo "$3" | grep -q '[^01]'; then
        logOut "ERROR" "Mode must be 0 (copy) or 1 (move): $3"
        exit ${JOB_ER}
    fi

    src_tmp="${1%/}"
    src_parent="${src_tmp%/*}"
    dst_chk="${2#${src_tmp}}"

    if [ -z "$dst_chk" ] || [ "$2" != "$dst_chk" ] || [ "${2%/}" = "$src_parent" ]; then
        logOut "ERROR" "Invalid parent-child directory relationship."
        exit ${JOB_ER}
    fi
}

# ------------------------------------------------------------------
# pre-process （事前処理ロジックを記述する領域）
# ------------------------------------------------------------------
scope="pre"

src_dir=""
dst_dir=""
mode=""

while getopts d:t:m: opt; do
    case "$opt" in
        d) src_dir="$OPTARG" ;;
        t) dst_dir="$OPTARG" ;;
        m) mode="$OPTARG" ;;
        *) usage ;;
    esac
done

if [ "$OPTIND" -eq 1 ]; then
    logOut "ERROR" "No arguments provided."
    usage
fi

logOut "DEBUG" "src=$src_dir, dst=$dst_dir, mode=$mode"
checkArgs "$src_dir" "$dst_dir" "$mode"

# ------------------------------------------------------------------
# main-process （メインロジックを記述する領域）
# ------------------------------------------------------------------
scope="main"

src_base="${src_dir%/}"
dst_base="${dst_dir%/}/${src_base##*/}"
tmp_dir="${dst_base}.tmpdir"

logOut "INFO" "Starting rsync to temporary directory: $tmp_dir"
rsync --checksum --delete -av "$src_base/" "$tmp_dir/"
if [ $? -ne 0 ]; then
    logOut "ERROR" "rsync failed."
    exit ${JOB_ER}
fi

if [ -d "$dst_base" ]; then
    logOut "INFO" "Removing existing destination: $dst_base"
    rm -rf "$dst_base/"
fi

logOut "INFO" "Renaming $tmp_dir to $dst_base"
mv -f "$tmp_dir" "$dst_base"

if [ "$mode" -eq 1 ]; then
    logOut "INFO" "Removing source directory after move: $src_base"
    rm -rf "$src_base/"
fi

# ----------------------------------------------------------
# post-process （事後処理ロジックを記述する領域）
# ----------------------------------------------------------
scope="post"

logOut "INFO" "dirTransfer.sh completed successfully."
exitLog ${JOB_OK}
