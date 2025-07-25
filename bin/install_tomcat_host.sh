#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# ver.1.0.0 2025.07.25
#
# Usage:
#     sh install_tomcat_host.sh [-p port] [-m mode]
#
# Description:
#     Web Layer（Tomcat）構築コマンドおよび設定コマンド
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  ---------  2025/07/25  Bepro        新規作成
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
BASE_PATH="${BASE_PATH:-/home/bepro/projects/scripts}"
ETC_PATH="${BASE_PATH}/etc/tomcat"
LOG_PATH="${BASE_PATH}/log"
TMP_PATH="${BASE_PATH}/tmp"

TOMCAT_VER="${TOMCAT_VER:-10.1.43}"
JDK_MAJOR="${JDK_MAJOR:-17}"
INSTALL_DIR="${INSTALL_DIR:-/opt/tomcat}"
SERVICE_NAME="${SERVICE_NAME:-tomcat}"
TOMCAT_USER="${TOMCAT_USER:-tomcat}"
TOMCAT_TAR="${TMP_PATH}/apache-tomcat-${TOMCAT_VER}.tar.gz"
TOMCAT_URL="${TOMCAT_URL:-https://dlcdn.apache.org/tomcat/tomcat-10/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz}"

rc=0

# ----------------------------------------------------------
# functions （関数を記述する領域）
# ----------------------------------------------------------
scope="func"

# ----------------------------------------------------------
# Executes the processing at the end..
# ----------------------------------------------------------
# return N/A
# ----------------------------------------------------------
terminate() {
  erase
}

# ----------------------------------------------------------
# 引数チェックの関数
# ----------------------------------------------------------
checkArgs() {
    # ポートが指定されていない場合はデフォルトで8080を設定
    if [ -z "$PORT" ]; then
        PORT=8080
    fi

    # ポート番号が有効な数字かどうか確認
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: 無効なポート番号が指定されました。数字のみを指定してください。"
        exit 1
    fi

    # -m 引数が空の場合、ポートのみ指定されている場合はスキップ
    if [ -n "$MODE" ]; then
        # MODEの値が正しいか確認（"erase"の確認）
        if [[ "$MODE" != "erase" ]]; then
            echo "ERROR: 無効なMODE値が指定されました。使用可能なMODEは 'erase' です。"
            exit 1
        fi
    fi
}

#====================================================
# Step 2: 削除モード（erase）
#====================================================
erase() {
    logOut "INFO" "Tomcat関連の削除処理を開始します。"

    systemctl stop    "${SERVICE_NAME}" 2>/dev/null
    systemctl disable "${SERVICE_NAME}" 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service" \
            "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
    systemctl daemon-reload

    pkill -9 -f 'org.apache.catalina' 2>/dev/null || true

    rm -rf "${INSTALL_DIR}"
    userdel -r "${TOMCAT_USER}" 2>/dev/null || true

    logOut "INFO" "Java(OpenJDK) を削除します。"
    rpm -qa | grep -E '^java-[0-9]+-openjdk' | xargs -r dnf remove -y

    logOut "INFO" "TomcatとJavaの削除が完了しました。"
    exitLog 0
}

# ===================================================
# PIDのゾンビプロセスを防ぐ関数
# ===================================================
clear_zombie_pid() {
    # PIDファイルが存在する場合、そのPIDを強制終了
    if [ -f ${INSTALL_DIR}/temp/tomcat.pid ]; then
        kill -9 $(cat ${INSTALL_DIR}/temp/tomcat.pid) || true
    fi

    # javaプロセスが残っていた場合、そのプロセスを強制終了
    pgrep -f "java" && kill -9 $(pgrep -f "java") || true
}

# ------------------------------------------------------------------
# pre-process （事前処理ロジックを記述する領域）
# ------------------------------------------------------------------
scope="pre"

startLog

trap "terminate" 1 2 3 15

#====================================================
# 初期変数定義（デフォルト値）
#====================================================
MODE=""
PORT=""
while getopts "m:p:" OPT; do
    case $OPT in
        m) MODE="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
    esac
done

checkArgs $@

CONF_FILE="/etc/tomcat-install.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# ------------------------------------------------------------------
# main-process （メインロジックを記述する領域）
# ------------------------------------------------------------------
scope="main"

if [ "${MODE}" = "erase" ]; then
    erase
    exit 0  # <-- 明示的にここで終了させる
fi

#====================================================
# Step 0: 既存インストールの確認
#====================================================
if [ -d "${INSTALL_DIR}" ] && [ "${MODE}" != "erase" ]; then
    logOut "WARNING" "既にTomcatはインストールされています。[ ${INSTALL_DIR} ]"
    exitLog 0
fi

#====================================================
# Step 1: Javaインストール／バージョン確認
#====================================================
need_java_install=false
if command -v java &>/dev/null; then
    major=$(java -XshowSettings:properties -version 2>&1 \
             | awk '/java.version =/ {split($3,v,"."); print (v[1]=="1")?v[2]:v[1]}')
    if [ "$major" -lt 11 ]; then
        need_java_install=true
        logOut "INFO" "現在 Java${major}  → Tomcat10 には 11+ が必要なためアップグレードします。"
    else
        logOut "INFO" "Java${major} は要件を満たしています。"
    fi
else
    need_java_install=true
    logOut "INFO" "Java が未インストールのため、OpenJDK${JDK_MAJOR} を導入します。"
fi

if $need_java_install; then
    dnf install -y java-${JDK_MAJOR}-openjdk java-${JDK_MAJOR}-openjdk-devel || {
        logOut "ERROR" "Java(OpenJDK) のインストールに失敗しました。"
        exitLog ${JOB_ER}
    }
    java_path=$(alternatives --list | awk '/java-'"${JDK_MAJOR}"'-openjdk.*\/bin\/java/ {print $3; exit}')
    if [ -n "$java_path" ]; then
        alternatives --set java "$java_path"
        logOut "INFO" "Java${JDK_MAJOR} を既定に設定しました。"
    else
        logOut "ERROR" "alternatives に Java が登録されていません。"
        exitLog ${JOB_ER}
    fi
fi

#====================================================
# Step 2: Tomcatアーカイブ取得
#====================================================
logOut "INFO" "Tomcat ${TOMCAT_VER} をダウンロードします。"
mkdir -p "${TMP_PATH}"
[ -f "${TOMCAT_TAR}" ] && rm -f "${TOMCAT_TAR}"
curl -f -L -o "$TOMCAT_TAR" "$TOMCAT_URL"
rc=$?
if [ $rc -ne 0 ]; then
    logOut "ERROR" "Tomcat アーカイブのダウンロードに失敗しました。curlの終了コード: $rc"
    exitLog ${JOB_ER}
fi
logOut "INFO" "Tomcat を正常にダウンロードしました。[ ${TOMCAT_TAR} ]"

#====================================================
# Step 3: 展開
#====================================================
[ -d "${INSTALL_DIR}" ] && rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
tar -xzf "${TOMCAT_TAR}" -C "${INSTALL_DIR}" --strip-components=1
if [ $? -ne 0 ]; then
    logOut "ERROR" "Tomcat アーカイブの展開に失敗しました。"
    exitLog ${JOB_ER}
fi

#====================================================
# Step 4: ユーザー作成
#====================================================
if ! id "${TOMCAT_USER}" &>/dev/null; then
    useradd -r -m -U -d "${INSTALL_DIR}" -s /bin/false "${TOMCAT_USER}"
    if [ $? -ne 0 ]; then
        logOut "ERROR" "Tomcatユーザーの作成に失敗しました。"
        exitLog ${JOB_ER}
    fi
    logOut "INFO" "Tomcatユーザーを作成しました。[ ${TOMCAT_USER} ]"
else
    logOut "INFO" "Tomcatユーザーは既に存在します。[ ${TOMCAT_USER} ]"
fi

#====================================================
# Step 5: 所有権設定
#====================================================
chown -R "${TOMCAT_USER}:${TOMCAT_USER}" "${INSTALL_DIR}"
logOut "INFO" "Tomcatディレクトリの所有権を設定しました。"

#====================================================
# Step 6: ポート抽出
#====================================================
if [ -z "$PORT" ]; then
    # ポート番号が指定されていない場合、server.xmlから現在のポートを抽出
    PORT=$(awk -F'[="]' '/<Connector/ && /protocol="HTTP\/1.1"/ {for(i=1;i<=NF;i++) if($i=="port") {print $(i+2); exit}}' "${INSTALL_DIR}/conf/server.xml")
    
    if [ -z "$PORT" ]; then
        # 抽出できなかった場合のログ
        logOut "WARNING" "server.xml からポート番号の抽出に失敗しました。デフォルトの 8080 を使用します。"
        PORT=8080  # 抽出できなければ8080をデフォルト
    else
        logOut "INFO" "server.xml よりポート ${PORT} を抽出しました。"
    fi
else
    # ポート番号が指定されている場合、そのまま使用
    logOut "INFO" "指定されたポート番号を使用します。[ ${PORT} ]"
fi

# ポート番号を server.xml に反映
if [ -n "$PORT" ]; then
    # server.xml 内の <Connector port="8080" を指定されたポート番号に変更
    sed -i "s|<Connector port=\"8080\"|<Connector port=\"$PORT\"|" "${INSTALL_DIR}/conf/server.xml"
    logOut "INFO" "server.xml のポート番号を ${PORT} に設定しました。"
fi

# ===================================================
# Step 7: systemdサービスユニットの作成
# ===================================================
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
JAVA_HOME_PATH=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

# 最初にゾンビPIDを確認・削除
clear_zombie_pid

# systemdサービスユニットを作成
cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
User=${TOMCAT_USER}
Group=${TOMCAT_USER}

Environment="JAVA_HOME=${JAVA_HOME_PATH}"
Environment="CATALINA_PID=${INSTALL_DIR}/temp/tomcat.pid"
Environment="CATALINA_HOME=${INSTALL_DIR}"
Environment="CATALINA_BASE=${INSTALL_DIR}"
ExecStart=${INSTALL_DIR}/bin/startup.sh
ExecStop=${INSTALL_DIR}/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
EOF

# エラーチェック
if [ $? -ne 0 ]; then
    logOut "ERROR" "Tomcatのサービスユニット作成に失敗しました。"
    exitLog ${JOB_ER}
fi

logOut "INFO" "Tomcat systemd ユニットファイルを作成しました。[ ${SERVICE_FILE} ]"

#====================================================
# Step 8: systemd起動＆確認
#====================================================
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

if [ $? -ne 0 ]; then
    logOut "ERROR" "Tomcatサービスの起動に失敗しました。"
    exitLog ${JOB_ER}
fi

sleep 3
if ! ss -ltnp | grep ":${PORT}" | grep java >/dev/null; then
    logOut "ERROR" "Tomcatがポート${PORT}で待機していません。起動に失敗した可能性があります。"
    exitLog ${JOB_ER}
fi

logOut "INFO" "Tomcatサービスを起動しました。[ ポート${PORT} LISTEN 確認済み ]"
# ----------------------------------------------------------
# post-process （事後処理ロジックを記述する領域）
# ----------------------------------------------------------
scope="post"

logOut "INFO" "Tomcat自動インストールスクリプトを正常終了します。"
exitLog ${rc}
