#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# install_postgres.sh
# 
# Description:
#    PostgreSQL バージョン共存対応の導入／一覧／削除ツール
#    - RHEL8/9 対応
#    - PGDG リポジトリ自動登録（10〜16）
#    - logger.shrc ／ utils.shrc に準拠
#
# PATCH v1.6b (2025‑08‑04)
#   * dnf-plugins-core 事前導入
#   * makecache / install / initdb に進捗ログ
#   * ソケット競合確認強化
#   * **重複していた os_major 取得行を 1 行に統一** ← NEW
# ------------------------------------------------------------------
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  -           2025/08/04  Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/logger.shrc"
. "$(dirname "$0")/../com/utils.shrc"
setLANG     utf-8
runAs root "$@"

# ------------------------------------------------------------------
# 変数宣言
# ------------------------------------------------------------------
scope="var"

readonly JOB_OK=0
readonly JOB_WR=1
readonly JOB_ER=2
rc=${JOB_ER}

MODE=""
VERSION=""
PORT=""

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

usage() {
    cat << EOF
Usage:
  sh install_postgres.sh -m < install | erase | list > [-v <version>] [-p <port>]

Options:
  -m    処理モード（install, erase, list）※必須
  -v    PostgreSQLのメジャーバージョン番号（例: 15, 16）
  -p    使用するポート番号（デフォルト: 5432）
EOF
    exit ${JOB_ER}
}

terminate() {
    releaseLock
}

checkArgs() {
    while getopts "m:v:p:" opt; do
        case "$opt" in
            m) MODE="$OPTARG" ;;
            v) VERSION="$OPTARG" ;;
            p) PORT="$OPTARG" ;;
            *) usage ;;
        esac
    done

    case "$MODE" in
        list) : ;;
        install|erase) [ -z "$VERSION" ] && usage ;;
        *) usage ;;
    esac

    [ -z "$PORT" ] && PORT=5432

    if echo "$PORT" | grep -qE "[^0-9]"; then
        logOut "ERROR" "ポート番号は数値で指定してください。"
        exitLog ${JOB_ER}
    fi

    if [ -n "$VERSION" ] && [ "$MODE" != "list" ] && [ "$VERSION" -lt 14 ]; then
        logOut "ERROR" "PostgreSQL ${VERSION} 系はサポート対象外です (14 以上を指定)"
        exitLog ${JOB_ER}
    fi
}

# ------------------------------------------------------------------
# 関数名　　：getRepoUrl
# 概要　　　：PostgreSQLのリポジトリURLを取得する
# 説明　　　：
#   指定されたバージョンとRHELのバージョンに応じて、対応する
#   yumリポジトリのrpmパッケージURLを返却する。
# 
# 引数　　　：$1 = PostgreSQLバージョン
# 戻り値　　：標準出力でリポジトリURLを返す
# 使用箇所　：installPostgres
# ------------------------------------------------------------------
getRepoUrl() {
    local version="$1"
    local rhel_version
    rhel_version=$(grep -oP '(?<=release )\d+' /etc/redhat-release)

    echo "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${rhel_version}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
}

# ------------------------------------------------------------------
# 関数名　　：installPgRepo
# 概要　　　：PostgreSQL用リポジトリを確認・追加
# 説明　　　：
#   指定バージョンの PostgreSQL リポジトリが未登録であれば、
#   公式リポジトリを取得して自動で登録します。
#   既に有効であればスキップされます。
#
# 引数　　　：なし（グローバル変数 VERSION を参照）
# 戻り値　　：正常時 0、失敗時は exitLog で強制終了
# 使用箇所　：installPostgres()
# ------------------------------------------------------------------
installPgRepo() {
    logOut "INFO" "PostgreSQL ${VERSION} の yum リポジトリを確認します。"

    case "$VERSION" in
        10|11|12|13|14|15|16) ;;
        *)
            logOut "ERROR" "PostgreSQL ${VERSION} 系はサポート対象外です"
            exitLog ${JOB_ER}
            ;;
    esac

    el_version=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)

    # 不要レポジトリ削除
    rm -f /etc/yum.repos.d/pgdg*.repo

    # 必要なレポジトリのみ再生成
    repo_path="/etc/yum.repos.d/pgdg-redhat-all.repo"
    logOut "INFO" "pgdg${VERSION} の .repo ファイルを直接再生成します: ${repo_path}"

    cat <<EOF > "$repo_path"
[pgdg${VERSION}]
name=PostgreSQL ${VERSION} for RHEL/CentOS ${el_version} - x86_64
baseurl=https://download.postgresql.org/pub/repos/yum/${VERSION}/redhat/rhel-${el_version}-x86_64
enabled=1
gpgcheck=1
gpgkey=https://download.postgresql.org/pub/repos/yum/RPM-GPG-KEY-PGDG
EOF

    logOut "INFO" "dnf makecache を実行"
    dnf clean all
    dnf makecache --enablerepo=pgdg${VERSION} -y

    logOut "INFO" "module postgresql を無効化します"
    dnf -qy module disable postgresql || true

    if ! dnf list available | grep -q "postgresql${VERSION}-server"; then
        logOut "ERROR" "pgdg レポジトリ追加後も postgresql${VERSION}-server が見えません"
        exitLog ${JOB_ER}
    fi

    logOut "INFO" "PostgreSQL ${VERSION} の yum リポジトリ登録が完了しました。"
}

# ------------------------------------------------------------------
# 関数名　　：checkPortConflict
# 概要　　　：PostgreSQLポート競合の事前検出
# 説明　　　：
#   PostgreSQLインストール前に、指定ポートが既存インスタンスや
#   設定ファイルと競合していないかを確認する。
#   以下2点の競合パターンを検出：
#     - postgresql.conf ファイル内で既に使用されている
#     - 現在 LISTEN 中のプロセス（postgres）で使用中
#
# 引数　　　：なし（グローバル変数 PORT を使用）
# 戻り値　　：競合がなければ0、競合があれば exitLog で異常終了
# 使用箇所　：installPostgres 関数内のインストール前検査
# ------------------------------------------------------------------
checkPortConflict() {
    conf_files=$(find /var/lib/pgsql -type f -name "postgresql.conf" 2>/dev/null)
    for conf in $conf_files; do
        used_port=$(grep -E "^port\s*=" "$conf" | awk -F= '{gsub(/[[:space:]]/, "", $2); print $2}')
        [ -z "$used_port" ] && used_port="5432"
        if [ "$used_port" = "$PORT" ]; then
            logOut "ERROR" "指定ポート${PORT}は他バージョンの設定ファイルと競合しています（$conf）"
            exitLog ${JOB_ER}
        fi
    done

    if ss -ltnp 2>/dev/null | grep -q ":${PORT} .*postgres"; then
        logOut "ERROR" "指定ポート${PORT}は既に PostgreSQL プロセスが LISTEN しています。"
        exitLog ${JOB_ER}
    fi
}

# ------------------------------------------------------------------
# 関数名　　：installPostgres
# 概要　　　：PostgreSQLの指定バージョン・ポートへの自動インストール処理
# 説明　　　：
#   指定された PostgreSQL のバージョンとポートに対して、
#   pgdg レポジトリ追加、dnf によるパッケージインストール、initdb、
#   postgresql.conf のポート書き換え、systemd 起動、初期パスワード設定までを自動化。
#   主な処理内容：
#     - 同一バージョンの既インストールを検出してブロック
#     - 指定ポートの競合チェック（checkPortConflict）
#     - pgdg リポジトリの有効化とキャッシュ更新
#     - PostgreSQL 本体のインストールと initdb
#     - 設定ファイルのポート書き換えと systemctl 起動
#     - postgresユーザーの初期パスワード設定
#
# 引数　　　：なし（グローバル変数 VERSION, PORT を使用）
# 戻り値　　：正常終了なら rc=${JOB_OK}、エラー時は exitLog で強制終了
# 使用箇所　：mainプロセス（install 指定時）
# ------------------------------------------------------------------
installPostgres() {
    checkPortConflict

    # ------------------------------------------------------------------
    # PostgreSQL同一バージョンのインストールチェック
    # ------------------------------------------------------------------
    if rpm -q "postgresql${VERSION}-server" >/dev/null 2>&1; then

    logOut "WARNING" "PostgreSQL ${VERSION} は既にインストールされています。同一バージョンの再インストールは許可されていません。"
    exitLog ${JOB_ER}
fi

    if ! dnf list --quiet --disablerepo='*' --enablerepo="pgdg*" postgresql${VERSION}-server >/dev/null 2>&1; then
        installPgRepo
        logOut "INFO" "dnf makecache を実行してキャッシュを更新します。"
        dnf makecache --disablerepo='*' --enablerepo="pgdg*" -y
    fi

    dnf config-manager --set-enabled pgdg-common || true
    dnf config-manager --set-enabled pgdg${VERSION} || true
    dnf config-manager --set-enabled pgdg${VERSION}-source || true
    dnf config-manager --set-enabled pgdg${VERSION}-debug || true

     dnf config-manager --set-enabled pgdg${VERSION}

    repo_url=$(getRepoUrl "$VERSION")

    logOut "INFO" "(2/3) postgresql${VERSION}-server をダウンロード / インストール中…"
    if ! dnf -y install --disablerepo='*' --enablerepo="pgdg*" "postgresql${VERSION}-server"; then
        logOut "ERROR" "指定バージョンのパッケージが取得できません: postgresql${VERSION}-server"
        exitLog ${JOB_ER}
    fi

    logOut "INFO" "(3/3) initdb を実行中…"
    /usr/pgsql-${VERSION}/bin/postgresql-${VERSION}-setup initdb || exitLog ${JOB_ER}
    conf_path="/var/lib/pgsql/${VERSION}/data/postgresql.conf"
    sed -i "s/^#\?port = .*/port = ${PORT}/" "$conf_path"

    if ss -ltnp 2>/dev/null | grep -q ":${PORT} .*postgres"; then
        logOut "ERROR" "initdb 後にポート${PORT}が既に使用されています。処理を中止します。"
        exitLog ${JOB_ER}
    fi

    systemctl enable postgresql-${VERSION}
    systemctl start  postgresql-${VERSION}

    #su - po ${PORT} -c \"ALTER USER postgres WITH PASSWORD 'p8cduXDa';\"" || exitLog ${JOB_ER}
query="ALTER USER postgres WITH PASSWORD 'p8cduXDa';"
eval "su - postgres -c \"psql -p ${PORT} -c \\\"${query}\\\"\"" || exitLog ${JOB_ER}



    logOut "INFO" "PostgreSQL ${VERSION} をポート ${PORT} でインストール完了"
    rc=${JOB_OK}
}

# ------------------------------------------------------------------
# 関数名　　：erasePostgres
# 概要　　　：PostgreSQLの指定バージョンをアンインストールする
# 説明　　　：
#   systemd に登録されている指定バージョンの PostgreSQL を停止・無効化し、
#   dnf 経由で該当バージョンのすべてのパッケージを削除。
#   さらに PostgreSQL データディレクトリも削除する。
#   処理対象は /var/lib/pgsql/${VERSION}。
#   ※指定バージョンが未インストールであれば即時エラー終了。
#
# 引数　　　：なし（グローバル変数 VERSION を使用）
# 戻り値　　：正常終了なら rc=${JOB_OK}、エラー時は exitLog により終了
# 使用箇所　：mainプロセス（-m erase 指定時）
# ------------------------------------------------------------------
erasePostgres() {
    service="postgresql-${VERSION}"
    if ! systemctl list-unit-files | grep -q "${service}\.service"; then
        logOut "ERROR" "PostgreSQL ${VERSION} は導入されていません。"
        exitLog ${JOB_ER}
    fi
    systemctl stop "$service"
    systemctl disable "$service"
    dnf -y remove "postgresql${VERSION}-*" || true
    rm -rf "/var/lib/pgsql/${VERSION}"
    logOut "INFO" "PostgreSQL ${VERSION} を削除しました。"
    rc=${JOB_OK}
}

# ------------------------------------------------------------------
# 関数名　　：listPostgres
# 概要　　　：インストール済みPostgreSQLインスタンスの一覧表示
# 説明　　　：
#   /var/lib/pgsql 以下を探索し、各バージョンの postgresql.conf を検出。
#   検出された設定ファイルごとに以下の情報を抽出して一覧表示する：
#     - バージョン（パス構造から抽出）
#     - ポート番号（設定ファイル内の port ディレクティブ）
#   port が未設定の場合はデフォルトの 5432 とみなす。
#   設定ファイルが1つも見つからなかった場合は未導入と判断。
#
# 引数　　　：なし
# 戻り値　　：rc=${JOB_OK}
# 使用箇所　：mainプロセス（-m list 指定時）
# ------------------------------------------------------------------
listPostgres() {
    confs=$(find /var/lib/pgsql -type f -name "postgresql.conf" 2>/dev/null)
    if [ -z "$confs" ]; then
        logOut "INFO" "PostgreSQLは導入されていません。"
        rc=${JOB_OK}
        return
    fi
    echo "--- Installed PostgreSQL Instances ---"
    for conf in $confs; do
        ver=$(echo "$conf" | awk -F/ '{print $(NF-2)}')
        port=$(grep -E '^port[[:space:]]*=' "$conf" | awk -F= '{gsub(/[[:space:]]/, "", $2); print $2}')
        [ -z "$port" ] && port="5432"
        echo "Version: $ver => Port: $port"
    done
    rc=${JOB_OK}
}

# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

startLog
trap "terminate" 0 1 2 3 15
checkArgs "$@"

if acquireLock; then
    logOut "INFO" "Lock acquired."
else
    abort "Lock acquisition failed."
fi

# ------------------------------------------------------------------
# main-process
# ------------------------------------------------------------------
scope="main"

case "$MODE" in
    install) installPostgres ;;
    erase)   erasePostgres   ;;
    list)    listPostgres    ;;
    *) usage ;;
esac

# ------------------------------------------------------------------
# post-process
# ------------------------------------------------------------------
scope="post"

exitLog $rc

