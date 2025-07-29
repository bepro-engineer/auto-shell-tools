#!/bin/sh
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# ver.1.0.0 2025.07.19
#
# Usage:
#     sh install_apache_host.sh [-d domain] [-e email] [-m mode]
#
# Description:
#    Web Layer構築コマンド及び設定コマンド
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  〇〇〇〇〇  2025/07/19  Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/logger.shrc"
. "$(dirname "$0")/../com/utils.shrc"
setLANG     utf-8

# ========================================
# 定数定義
# ========================================
readonly JOB_OK=0
readonly JOB_WR=1
readonly JOB_ER=2

# ------------------------------------------------------------------
# variables （変数の宣言領域）
# ------------------------------------------------------------------
scope="var"

DOMAIN=""
EMAIL=""
date=$(date "+%Y-%m-%d")
hostname=`hostname -s`
rc=${JOB_OK}
conf_dir="/etc/httpd/conf/"
conf_d_dir="/etc/httpd/conf.d/"
conf_module_d_dir="/etc/httpd/conf.modules.d/"
httpd_conf="httpd.conf"
mpm_conf="mpm.conf"
target_mpm="LoadModule mpm_prefork_module modules\/mod_mpm_prefork\.so"
untarget_mpm="LoadModule mpm_worker_module modules\/mod_mpm_worker\.so"
limits_conf_dir="/etc/systemd/system/httpd.service.d/"
IF01_MSG="モジュールのインストールに成功しました。"
IF02_MSG="処理に成功しました。"
WR01_MSG="モジュールが既に導入されています。処理を中止します。"
WR02_MSG="処理に失敗しました。"
ER01_MSG="モジュールのインストールに失敗しました。"
ER02_MSG="処理に失敗しました。"

# ----------------------------------------------------------
# VirtualHost設定 Java連携時の接続子
# ----------------------------------------------------------
VHOST1=""
VHOST2=""

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
  :
}

# ----------------------------------------------------------
# devider.
# ----------------------------------------------------------
# return N/A
# ----------------------------------------------------------
line (){
  echo -e "\\n    ------------"
  echo -e "    ▼ ${1}"
}

# ----------------------------------------------------------
# how to use.
# ----------------------------------------------------------
# return   N/A
# ----------------------------------------------------------
usage() {

  cat <<EOUSAGE
    -----------------------------------------------------------------
    Usage: $0 -d <domain> -e <email>

       Options:
         -d domain     : Specify the target domain (e.g., example.com)
         -e email      : Specify the contact email for Let's Encrypt

    -----------------------------------------------------------------
EOUSAGE
}

# ----------------------------------------------------------
# 引数チェック
# ----------------------------------------------------------
# param 1  protocol : Please enter the communication protocol [ https | http ].
# return   N/A
# ----------------------------------------------------------
checkArgs() {

logOut "引数:[ ${1} ${2} ]"
  if [ $# -lt 2 ]; then
    logOut "DEBUG" "引数が正しくありません。[ $@ ]"
    exitLog ${JOB_ER}
  fi
 
}

#====================================================
# 関数名：erase
# 説明  ：HTTPDとLet's Encrypt関連を含むすべてのアンインストール処理
#====================================================
erase() {

    if isProcessAlive "httpd"; then
        logOut "DEBUG" "HTTPDのプロセスを停止します。"
        systemctl stop httpd
    fi

    logOut "DEBUG" "HTTPDをアンインストールします。"
    dnf -y remove $(rpm -qa | grep -E '^httpd|mod_ssl')
    if [ $? -ne 0 ]; then
        rc=`expr ${rc} + ${JOB_ER}` 
        return ${rc}   
    fi

    if [ -d /etc/httpd ]; then
        logOut "DEBUG" "/etc/httpd 配下の設定ファイルを削除します。"
        find /etc/httpd -type f -exec rm -f {} \;
    fi

    if [ -d /etc/systemd/system/httpd.service.d ]; then
        logOut "DEBUG" "/etc/systemd/system/httpd.service.d を削除します。"
        rm -f /etc/systemd/system/httpd.service.d/override.conf
        rm -rf /etc/systemd/system/httpd.service.d
    fi

    #===========================
    # systemd キャッシュを完全リセット
    #===========================
    logOut "DEBUG" "systemd キャッシュを完全リセットします。"
    systemctl stop httpd 2>/dev/null
    systemctl disable httpd 2>/dev/null
    systemctl reset-failed httpd 2>/dev/null
    systemctl daemon-reexec
    systemctl daemon-reload

    #===========================
    # Let's Encrypt の削除処理
    #===========================
    if command -v certbot >/dev/null 2>&1; then
        logOut "DEBUG" "Let's Encrypt (certbot) が導入されているため、関連リソースを削除します。"
        removeLetsEncryptCert
    else
        logOut "DEBUG" "certbot が導入されていないため、Let's Encrypt の削除処理はスキップします。"
    fi
}

# ----------------------------------------------------------
# Edit the settings in the config file.
# ----------------------------------------------------------
# return N/A
# ----------------------------------------------------------
editHttpdConf (){

  sed -i -e "s/#ServerName www\.example\.com:80/ServerName localhost:80\nServerTokens Prod/" "${conf_dir}${httpd_conf}"
  sleep 1
}


# ----------------------------------------------------------
# Edit the settings in the icc config file.
# ----------------------------------------------------------
# return N/A
# ----------------------------------------------------------
editConfHttp2Https (){

  sed -i -e "s/.*Header edit Location ^http https/#&/g" "${conf_dir}${httpd_conf}"
  sleep 1
}

# ----------------------------------------------------------
# Edit the settings in the limits.conf.
# ----------------------------------------------------------
# return N/A
# ----------------------------------------------------------
editLimitsConf () {
    # prefork, worker, event のうち使用するMPMをコメント化
    sed -i -E 's|^[[:space:]]*#*LoadModule mpm_prefork_module.*|#LoadModule mpm_prefork_module modules/mod_mpm_prefork.so|' "${conf_module_d_dir}00-mpm.conf"
    sed -i -E 's|^[[:space:]]*#*LoadModule mpm_worker_module.*|#LoadModule mpm_worker_module modules/mod_mpm_worker.so|' "${conf_module_d_dir}00-mpm.conf"
    #sed -i -E 's|^[[:space:]]*#*LoadModule mpm_event_module.*|#LoadModule mpm_event_module modules/mod_mpm_event.so|' "${conf_module_d_dir}00-mpm.conf"

}

#====================================================
# 関数名：installLetsEncryptCert
# 説明  ：Let's Encrypt を用いたSSL証明書の取得とApacheへの組み込み
#====================================================
installLetsEncryptCert() {
    local DOMAIN="$1"
    local EMAIL="$2"
    local conf_file="/etc/httpd/conf/httpd.conf"
    local temp_marker="# === BEGIN TEMP VHOST FOR CERTBOT ==="
    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        logOut "ERROR" "ドメイン名とメールアドレスは必須です。" >&2
        return 1
    fi

    # certbotのインストール
    if ! command -v certbot >/dev/null 2>&1; then
        logOut "INFO" "certbot をインストールします。"
        dnf install -y epel-release
        dnf install -y certbot python3-certbot-apache
    fi

    # ポート80と443を確認して未開放なら追加、reloadは1回だけ
    local changed=0
    if ! firewall-cmd --list-ports | grep -q '80/tcp'; then
        logOut "INFO" "ポート80を一時的に開放します。"
        firewall-cmd --permanent --add-port=80/tcp
        changed=1
    fi
    if ! firewall-cmd --list-ports | grep -q '443/tcp'; then
        logOut "INFO" "ポート443を一時的に開放します。"
        firewall-cmd --permanent --add-port=443/tcp
        changed=1
    fi
    if [ "$changed" -eq 1 ]; then
        firewall-cmd --reload
    fi

    # certbotが要求する仮のVirtualHost（*:80）を追加
    logOut "INFO" "Apache に一時的な VirtualHost を追加します（port 80）"
    cat << EOF >> "$conf_file"
${temp_marker}
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html
</VirtualHost>
# === END TEMP VHOST FOR CERTBOT ===
EOF

    # Apache構文チェックと再起動
    systemctl restart httpd
    if ! httpd -t; then
        logOut "ERROR" "Apache 設定にエラーがあります（VirtualHost追加後）"
        return 1
    fi

    # certbotで証明書取得
    logOut "INFO" "Let's Encrypt で証明書を取得します：$DOMAIN"
    if ! certbot --apache -n --agree-tos --email "$EMAIL" -d "$DOMAIN"; then
        logOut "ERROR" "certbot による証明書取得に失敗しました。"
        return 1
    fi

    # 証明書の存在確認
    if [ ! -s "$cert_path" ]; then
        logOut "ERROR" "証明書ファイルが存在しないか空です：$cert_path"
        return 1
    fi

    # 仮VirtualHostの削除
    logOut "INFO" "一時的に追加した VirtualHost を削除します"
    sed -i "/${temp_marker}/,/^# === END TEMP VHOST FOR CERTBOT ===/d" "$conf_file"

    systemctl restart httpd

    # certbotの自動更新有効化
    logOut "INFO" "証明書の自動更新を有効化します。"
    systemctl enable certbot-renew.timer
}

#====================================================
# 関数名：removeHttpdAndLetsEncrypt
# 説明  ：Apache（httpd）とLet's Encrypt証明書、関連設定・パッケージを完全に削除
#====================================================
removeLetsEncryptCert() {
    # Apache関連パッケージを削除
    logOut "INFO" "Apache (httpd) を削除します。"
    dnf remove -y httpd httpd-tools mod_ssl

    # certbot と関連パッケージを削除
    logOut "INFO" "certbot と関連パッケージを削除します。"
    dnf remove -y certbot python3-certbot-apache

    # Let's Encrypt の証明書・キャッシュ・ログを削除
    logOut "INFO" "Let's Encrypt の証明書と設定を削除します。"
    rm -rf /etc/letsencrypt
    rm -rf /var/lib/letsencrypt
    rm -rf /var/log/letsencrypt

    # Apacheの conf.d ディレクトリにあるバーチャルホスト設定を削除
    logOut "INFO" "Apache 設定から残っているバーチャルホスト設定を削除します。"
    rm -f /etc/httpd/conf.d/*.conf

    # certbot の自動更新タイマー（systemd）を無効化して削除
    logOut "INFO" "certbot 関連の systemd タイマーを無効化・削除します。"
    systemctl disable --now certbot-renew.timer 2>/dev/null
    systemctl stop certbot-renew.timer 2>/dev/null
    rm -f /etc/systemd/system/timers.target.wants/certbot-renew.timer

    # ファイアウォールのポート開放を元に戻す
   # logOut "INFO" "ファイアウォール設定をクリーンアップします（ポート80/443削除）"
   # firewall-cmd --remove-port=80/tcp --permanent
   # firewall-cmd --remove-port=443/tcp --permanent
   # firewall-cmd --reload

    logOut "INFO" "削除が完了しました。"
}

# ------------------------------------------------------------------
# pre-process （事前処理ロジックを記述する領域）
# ------------------------------------------------------------------
scope="pre"

#setLogMode ${LOG_MODE:-overwrite}
startLog

trap "terminate" 1 2 3 15

checkArgs $@

# Get the value from the argument.
while getopts d:e:m: OPT; do
    case $OPT in
        d) DOMAIN="$OPTARG" ;;
        e) EMAIL="$OPTARG" ;;
        m) MODE="$OPTARG" ;;
        *) echo "Usage: $0 [-d domain] [-e email] [-m mode]" >&2; exit 1 ;;
    esac
done
# ------------------------------------------------------------------
# main-process （メインロジックを記述する領域）
# ------------------------------------------------------------------
scope="main"

if [ "${MODE}" == "erase" ]; then
  if ! erase ; then
    logOut "INFO" "HTTPD設定の消去${WR02_MSG} 既に削除されています。 [ Httpd ]"
    exitLog ${ERROR}
  fi
    logOut "INFO" "HTTPD設定の消去${IF02_MSG} [ Httpd ]"
fi
sleep 3

if [ -n "${DOMAIN}" ]; then
	line "httpdの導入状況を確認します。"
	if isModuleInstall "httpd"; then
	  logOut "WARN" "${WR01_MSG}"
	   exitLog ${JOB_ER}
	fi
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 1.OS標準のhttpdのインストール
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "1.OS標準のhttpdのインストールを行ないます。"
	dnf install -y httpd mod_ssl
	if [ $? -eq 0 ]; then

	  logOut "INFO" "${IF01_MSG} [ Apache(httpd) ]"
	  line "既存の設定ファイルを退避します。"
	  cp -p "${conf_dir}${httpd_conf}" "${conf_dir}${httpd_conf}.${date}"

	  if [ -f "${conf_dir}${httpd_conf}.${date}" ]; then
	    logOut "INFO" "ファイルの退避${IF02_MSG} [ ${conf_dir}${httpd_conf}.${date} ]"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 2.httpd.confファイルのServerNameのコメントアウトを外して編集
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	    line "2.httpd.confファイルのServerNameのコメントアウトを外して編集します。"
	    if ! editHttpdConf ; then
	      logOut "ERROR" "ファイルの編集${ER02_MSG} [ ${conf_dir}${httpd_conf} ]"
	      rc=`expr ${rc} + ${JOB_ER}`
	      exitLog ${rc}
	    fi
	    sleep 1
	    logOut "INFO" "ファイルの編集${IF02_MSG} [ ${conf_dir}${httpd_conf}"
	    echo -e `cat ${conf_dir}${httpd_conf} | grep -v '^\s*#' | grep 'ServerName'`
	    echo -e `cat ${conf_dir}${httpd_conf} | grep -v '^\s*#' | grep 'ServerTokens'`
	  else
	    logOUt "ERROR" "ファイル退避${ER02_MSG} [ ${conf_dir}${httpd_conf} ]"
	    rc=`expr ${rc} + ${JOB_ER}`
	    exitLog ${rc}
	  fi
	else
	  logOut "ERROR" "${ER01_MSG} [ Apache(httpd) ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 3.httpd上の不要な設定ファイルを無効
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "3.httpd上の不要な設定ファイルを無効にします。"
	:>${conf_d_dir}welcome.conf 
	:>${conf_d_dir}userdir.conf 
	:>${conf_d_dir}autoindex.conf
	sleep 1
	ls -l ${conf_d_dir}
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 4.httpdの動作モードをevent
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "4.httpdの動作モードをeventに変更するための設定変更を行います。"
	if ! editLimitsConf; then
	  logOut "ERROR" "ファイルの編集${ER02_MSG} [ ${conf_d_dir}${mpm_conf} ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 5.新たにmpm.confファイルを作成
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "5.新たにmpm.confファイルを作成して設定を記述します。"
cat << EOS > "${conf_d_dir}${mpm_conf}"
KeepAlive Off
<IfModule worker.c>
  StartServers             4
  ServerLimit             20
  MaxRequestWorkers      500
  MinSpareThreads         25
  MaxSpareThreads         75
  ThreadsPerChild         25
  MaxConnectionsPerChild   0
</IfModule>
EOS
	sleep 1
	if [ ! -f "${conf_d_dir}${mpm_conf}" ]; then
	  logOut "ERROR" "ファイルの編集に${ER02_MSG} [ ${conf_d_dir}${mpm_conf} ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	logOut "INFO" "ファイルの編集${IF02_MSG} ${conf_d_dir}${mpm_conf}"
	cat "${conf_d_dir}${mpm_conf}"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 6.httpdのopen file limitの上限値緩和
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "6.httpdのopen file limitの上限値緩和のための設定ファイルを作成します。"
	mkdir -p ${limits_conf_dir}
cat << EOS > "${limits_conf_dir}limits.conf"
[Service]
LimitNOFILE=65535
EOS
	sleep 1
	if [ ! -f "${limits_conf_dir}limits.conf" ]; then
	  logOut "ERROR" "ファイルの編集${ER02_MSG} [ ${limits_conf_dir}limits.conf ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	logOut "INFO" "ファイルの編集${IF02_MSG} ${limits_conf_dir}limits.conf"
	cat "${limits_conf_dir}limits.conf"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 7.httpdの自動起動設定および起動
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "7.httpdの自動起動設定および起動を行います。"
	systemctl daemon-reload
	systemctl enable httpd
	sleep 1
	if [ $? -ne 0 ]; then
	  logOut "WARNING" "自動起動設定${WR03_MSG} [ httpd ]"
	  rc=`expr ${rc} + ${JOB_WR}`
	fi
	logOut "INFO" "自動起動設定${IF02_MSG} [ Apacht(httpd) ]"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 8.設定値反映確認のため、Apache/httpdのプロセスIDを取得
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "8.設定値反映確認のため、Apache/httpdのプロセスIDを取得します。"
	systemctl status httpd
	sleep 1

	#起動確認の為、一回起動する
	systemctl start httpd
	sleep 1
	if ! isProcessAlive "httpd"; then
	  logOut "ERROR" "Apache(httpd)の起動${ER02_MSG} [ httpd ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	logOut "INFO" "Apache(httpd)の起動${IF02_MSG} [ Apacht(httpd) ]"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# Let's Encrypt を用いたSSL証明書の取得
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
  line "9.Let's Encrypt を用いたSSL証明書の取得"
  logOut "INFO" "Let's Encrypt を用いたSSL証明書の取得とApacheへの組み込み"
  installLetsEncryptCert "$DOMAIN" "$EMAIL"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 10.Apache/httpd用のopen file limitが更新確認
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "10.Apache/httpd用のopen file limitが更新されたことを確認します。"
	logOut "INFO" "ファイルの編集${IF02_MSG} [ Apacht(httpd) ]"
	echo `cat /proc/$(ps -ef | grep httpd | head -n 1 | awk '{print $2}')/limits | grep 'Max open files'`
	echo "目視による確認を行ってください。"
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 11.アプリケーション連携のため、設定ファイル「httpd.conf」を編集
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "11.アプリケーション連携のため、設定ファイル「httpd.conf」を編集します。"
var=$(cat << EOS
<VirtualHost *:80>
    ServerName ${DOMAIN}
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN}

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem

    <Location /${VHOST1}/>
        ProxyPass ajp://localhost:8009/${VHOST1}/
    </Location>

    <Location /${VHOST2}/>
        ProxyPass ajp://localhost:8009/${VHOST2}/
    </Location>
</VirtualHost>
EOS
)
	echo  "${var}" >> "${conf_dir}${httpd_conf}"
	sleep 1

	editConfHttp2Https

  matched_count=$(grep -cE 'VirtualHost[[:space:]]+\*:443' "${conf_dir}${httpd_conf}")
  if [ "$matched_count" -eq 0 ]; then
      logOut "ERROR" "ファイルの編集${ER02_MSG} [ ${conf_dir}${httpd_conf} ]"
      rc=$((rc + JOB_ER))
      exitLog ${rc}
  fi

	logOut "INFO" "ファイルの編集${IF02_MSG} [ ${conf_dir}${httpd_conf} ]"
        tail ${conf_dir}${httpd_conf}

	# 確認用のHTMLファイルの作成
cat <<- EOS > /var/www/html/index.html
  <html>
  <head>
  <title>sample page</title>
  </head>
  <body>
  "このページは${hostname}で表示されたテストページです"
  </body>
  </html>
EOS
	sleep 1
	if [ $? -ne 0 ]; then
	  logOut "ERROR" "${ER02_MSG} [ /var/www/html/index.html ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	logOut "INFO" "htmlファイルの作成${IF02_MSG} [ /var/www/html/index.html ]"
        cat /var/www/html/index.html
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	# 12.サービスを再起動
	#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
	line "12.サービスを再起動します。"
	systemctl restart httpd
	sleep 1
	if [ $? -ne 0 ]; then
	  logOut "ERROR" "Apache(httpd)の再起動${ER02_MSG} [ httpd ]"
	  rc=`expr ${rc} + ${JOB_ER}`
	  exitLog ${rc}
	fi
	logOut "INFO" "Apache(httpd)の再起動${IF02_MSG} [ Apacht(httpd) ]"
	systemctl status httpd

	line "Apacheへアクセステスト"
	curl http://localhost
	sleep 1
fi

# ----------------------------------------------------------
# post-process （事後処理ロジックを記述する領域）
# ----------------------------------------------------------
scope="post"

exitLog ${rc}

