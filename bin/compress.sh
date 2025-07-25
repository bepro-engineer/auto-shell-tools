#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# compress.sh
# ver.1.3.0  2025.07.25
#
# Usage:
#     sh compress.sh -s <src_path> -d <dst_file> -m <mode>
#
# Description:
#    任意のファイル／ディレクトリをzstd形式で圧縮する汎用スクリプト
#    - モード: 圧縮後に元データを削除（1）または保持（0）
#    - ログ出力対応（logger.shrc 準拠）
#
#    使用例：
#        sh compress.sh -f /var/log/hoge.log -t /tmp/hoge.zst -m 1
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  〇〇〇〇〇  20xx/xx/xx  Bepro       初版
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
# 圧縮レベル指定（デフォルト: 9）
ZSTD_LEVEL=${ZSTD_LEVEL:-9}
# Initialization
src_path=""
dst_file=""
mode=""

# ----------------------------------------------------------
# functions
# ----------------------------------------------------------
terminate() {
    if [ -f "$status_file" ]; then
        rm -f "$status_file"
    fi
}

# ----------------------------------------------------------
# Check the validity of the argument.
# ----------------------------------------------------------
# param 1  src_file or directory
# param 2  dst_file
# param 3  mode 0:do nothing 1:remove
# return   N/A
# ----------------------------------------------------------
checkArgs() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        logOut "ERROR" "Incorrect number of arguments."
        exitLog 2
    fi
    logOut "DEBUG" "arg1 is [ $1 ]."
    if [ ! -e "$1" ]; then
        logOut "ERROR" "Not found such file or directory [ $1 ]."
        exitLog 2
    fi
    logOut "DEBUG" "arg2 is [ $2 ]."
    if echo "$2" | grep -q '/$'; then
        logOut "ERROR" "[ $2 ] directory is set as an output file."
        exitLog 2
    fi
    if [ ! -e "${2%/*}" ]; then
        logOut "ERROR" "Not found such file or directory [ ${2%/*} ]."
        exitLog 2
    fi
    if [ -f "$2" ]; then
        rm -rf "$2"
        logOut "INFO" "Removed the [ $2 ] because the same name dst file exist."
    fi
    # Check mode.
    logOut "DEBUG" "arg3 is [ $3 ]."
    if echo "$3" | grep -Eq "[^01]"; then
        logOut "ERROR" "An unexpected value [ $3 ]."
        exitLog 2
    fi
    # Check directory parent-child relationship.
    if [ "$3" -eq 1 ] && echo "$2" | grep -q "$1"; then
        logOut "ERROR" "Correlation error of a parameter."
        exitLog 2
    fi
}

# ----------------------------------------------------------
# how to use.
# ----------------------------------------------------------
# return   N/A
# ----------------------------------------------------------
usage() {

  cat <<EOUSAGE
    -----------------------------------------------------------------
    Usage: $0 -s <src_path> -d <dst_file> -m <mode>

       Options:
         -s src_path   : 圧縮対象のファイルまたはディレクトリ（必須）
         -d dst_file   : 出力先のファイル名（必須・.zst拡張子が推奨）
         -m mode       : モード（0=保持 ／ 1=削除）

    -----------------------------------------------------------------
EOUSAGE
}

# ----------------------------------------------------------
# pre-process
# ----------------------------------------------------------
step="pre"

# Get the value from the argument.
while getopts s:d:m: opts; do
    case $opts in
        s)
            src_path=$OPTARG
            ;;
        d)
            dst_file=$OPTARG
            ;;
        m)
            mode=$OPTARG
            ;;
        *)
            logOut "ERROR" "Illegal option."
            usage
            exitLog 2
            ;;
    esac
done

startLog
logOut "INFO" "args: [ $* ]"

trap "terminate" 0 1 2 3 15

mode=${mode:-"0"}

# Check the validity of the argument.
checkArgs "$src_path" "$dst_file" "$mode"

case "$os" in
    AIX)
        TAR="/usr/bin/tar"
        ;;
    Linux|FreeBSD)
        TAR="/bin/tar"
        ;;
    *)
        TAR="$(command -v tar)"
        ;;
esac

# ----------------------------------------------------------
# main-routine
# ----------------------------------------------------------
step="main"

# Change current directory.
cd "${src_path%/*}" || exit 1

# 一時ファイル作成
status_file="$TMP_PATH/compress.status.$$"
tmp_tar="$TMP_PATH/tmp_compress_$$.tar"

# tarで一時ファイルに書き出し
$TAR cf "$tmp_tar" "./${src_path##*/}"
tar_rc=$?

# zstdで圧縮（tar成功時のみ）
if [ "$tar_rc" -eq 0 ]; then
    zstd -${ZSTD_LEVEL} -T0 -o "$dst_file" "$tmp_tar"
    zstd_rc=$?
    rm -f "$tmp_tar"
else
    zstd_rc=1
fi

# 成否判定
if [ "$tar_rc" -eq 0 ] && [ "$zstd_rc" -eq 0 ]; then
    logOut "INFO" "Succeeded in compression [ $dst_file ]."
else
    logOut "ERROR" "Failed to compression [ $dst_file ]."
    rm -f "$dst_file"
    exitLog 2
fi

# モードに応じて元ファイル削除
if [ "$mode" -eq "1" ]; then
    rm -rf "$src_path"
fi

# ----------------------------------------------------------
# post-process
# ----------------------------------------------------------
step="post"
exitLog 0
