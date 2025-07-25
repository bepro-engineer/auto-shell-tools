#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# logger.sh ver.1.0.0 2025.02.20
#
# Usage:
#     sh backupFiles.sh -b [ 格納先ディレクトリ ]
#
# Description:
# - 指定されたファイル・ディレクトリをアーカイブ
# - 除外リストを考慮して圧縮
# - 7日以上前のバックアップを自動削除
# - 異常終了時の処理を `trap` で制御
#
# 設計書
#     none
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  PR-0001    2025/07/16 Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

# 共通クラスの読み込み
. $(dirname $0)/../com/logger.shrc
. $(dirname $0)/../com/utils.shrc

# ========================================
# 実行ユーザー確認（root限定）
# ========================================
runAsRoot

# ========================================
# 定数定義
# ========================================
readonly JOB_OK=0
readonly JOB_WR=1
readonly JOB_ER=2

# 変数定義
target_list="${ETC_PATH}/target.cfg"
ignore_list="${ETC_PATH}/ignore.cfg"
backup_dir=""
backup_file=""

# エラーメッセージ定義
err_msg01="バックアップ保存先が指定されていません。"
err_msg02="バックアップ保存先が存在しません。作成します。"
err_msg03="バックアップ保存先に書き込み権限がありません。"
err_msg04="ターゲットリストが存在しません。"
err_msg05="除外リストが存在しません。"
err_msg06="tar アーカイブ作成に失敗しました。"
err_msg07="古いバックアップの削除に失敗しました。"
err_msg08="異常終了のため、バックアップを削除します。"

# ========================================
# 関数定義
# ========================================

# 使用方法の表示
usage() {
    echo "Usage: $0 -b <backup_directory>"
    exit ${JOB_ER}
}

# 引数の妥当性確認
checkArg() {
    if [ -z "$backup_dir" ]; then
        logOut "ERROR" "${err_msg01}"
        exitLog ${JOB_ER}
    fi
    if [ ! -d "$backup_dir" ]; then
        logOut "WARNING" "${err_msg02} (${backup_dir})"
        mkdir -p "$backup_dir"
    fi
    if [ ! -w "$backup_dir" ]; then
        logOut "ERROR" "${err_msg03} (${backup_dir})"
        exitLog ${JOB_ER}
    fi
    if [ ! -f "$target_list" ]; then
        logOut "ERROR" "${err_msg04} (${target_list})"
        exitLog ${JOB_ER}
    fi
    if [ ! -f "$ignore_list" ]; then
        logOut "WARNING" "${err_msg05} (${ignore_list})"
    fi

    # 【追加】ターゲットリスト内のファイルが存在するか確認
    while read line; do
        if [ ! -e "$line" ]; then
            logOut "ERROR" "ターゲットファイルが見つかりません: ${line}"
            exitLog ${JOB_ER}
        fi
    done < "$target_list"
}

# 異常終了時のクリーンアップ処理
cleanup() {
    logOut "${err_msg08}" "ERROR"
    if [ -n "${backup_file}" && -f "${backup_file}" ]; then
        rm -f "${backup_file}"
        logOut "作成されたバックアップを削除しました: ${backup_file}" "WARNING"
    fi
    exitLog ${JOB_ER}
}

# バックアップ処理
executeBackup() {
    date_stamp="$(getCurrentDate)"
    echo "DEBUG: date_stamp=${date_stamp}"
    backup_file="${backup_dir}/backup_${date_stamp}.tar.gz"

    logOut "バックアップ開始: ${backup_file}" "INFO"

    # tar でアーカイブを作成
    logOut "INFO" "tarアーカイブ対象のリスト:"
    cat "${target_list}" | while read line; do
        logOut "INFO" "  - ${line}"
    done
    /bin/tar --exclude-from="${ignore_list}" -czf "${backup_file}" -T "${target_list}"

     rc=$?
    if [ $rc -ne $JOB_OK ]; then
        logOut "${err_msg06}" "ERROR"
        cleanup
    fi

    logOut "バックアップ完了: ${backup_file}" "INFO"
}

# 古いバックアップの削除
cleanOldBackups() {
    find "${backup_dir}" -type f -name "backup_*.tar.gz" -mtime +7 -exec rm {} + || logOut "${err_msg07}" "WARNING"
}

# ----------------------------------------------------------
# pre-process
# ----------------------------------------------------------
scope="pre"
startLog "backupFiles.sh バックアップ処理開始"

# ========================================
# 引数の処理
# ========================================
while getopts "b:" opt; do
    case $opt in
        b) backup_dir="$OPTARG" ;;
        *) usage ;;
    esac
done

checkArg

# `trap` 設定（異常終了時に cleanup() を呼び出し）
trap cleanup ERR

# ----------------------------------------------------------
# main-routine
# ----------------------------------------------------------
scope="main"
executeBackup
cleanOldBackups

# ----------------------------------------------------------
# post-process
# ----------------------------------------------------------
scope="post"
exitLog $JOB_OK