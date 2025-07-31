
#!/bin/bash
# ------------------------------------------------------------------
# RHEL系Linux開発サーバー初期設定スクリプト v2.0
#
# Usage:
#     sh init_rhel_devhost.sh
#
# Description:
#    Com（共通） Layer構築コマンド及び設定コマンド
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  〇〇〇〇〇  2025/07/19  Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
startLog                                 # ログ出力を初期化
startTimer                               # 実行時間計測用タイマー開始
setLANG utf-8
runAs root "$@"

# ====== グローバル変数の設定 ======
BASE_PATH="/home/bepro/projects/scripts"        # ベースディレクトリ（全体のルートパス）
LOG_PATH="${BASE_PATH}/log"  				    # ログファイルの保存先ディレクトリ
LOG_LEVEL="INFO"              					# ログレベル（DEBUG, INFO, WARNING, ERROR）
DEFAULT_LOG_MODE="CONSOLE"       				# ログ出力先（CONSOLEまたはFILE）
ETC_PATH="${BASE_PATH}/etc"      				# 設定ファイルを保存するディレクトリ
JOB_OK=0                         				# 正常終了コード

# ========================================
# 定数定義
# ========================================
readonly JOB_OK=0
readonly JOB_WR=1
readonly JOB_ER=2

# ------------------------------------------------------------------
# variables
# ------------------------------------------------------------------
scope="var"

hostname="dev01"
date=$(date "+%Y-%m-%d")
hostname_short=$(hostname -s)
rc=${JOB_OK}
limits_conf="/etc/security/limits.conf"
init_conf="/etc/sysconfig/init"
sysctl_conf="/etc/sysctl.conf"
dailyjobs="/etc/cron.d/dailyjobs"
hosts="/etc/hosts"
selinux_conf="/etc/selinux/config"

# ------------------------------------------------------------------
# functions
# ------------------------------------------------------------------
scope="func"

line () {
	echo ""
	echo "    ------------"
	echo "    ▼ ${1}"
}

terminate() { :; }

edit_limits_conf () {
	sed -i -e "/# End of file/i * soft nofile 65535\n* hard nofile 65535" "$limits_conf"
	sleep 1
}

disable_selinux () {
	setenforce 0
	sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$selinux_conf"
}

# ------------------------------------------------------------------
# pre-process
# ------------------------------------------------------------------
scope="pre"

setLogMode ${LOG_MODE:-overwrite}
startLog
trap "terminate" 0 1 2 3 15

# ------------------------------------------------------------------
# main-process
# ------------------------------------------------------------------
scope="main"

# 1. SELinux 無効化
line "1. SELinux を無効化します"
disable_selinux
if [ $? -ne 0 ]; then
	logOut "ERROR" "1. SELinux を無効化に失敗しました。"
	exitLog ${JOB_ER}
fi

# 2. タイムゾーン設定（Asia/Tokyo）
line "2. タイムゾーンを Asia/Tokyo に設定します"
timedatectl set-timezone Asia/Tokyo
timedatectl status
if [ $? -ne 0 ]; then
	logOut "ERROR"  "2. タイムゾーン設定に失敗しました"
	exitLog ${JOB_ER}
fi

# 3. ロケール設定（ja_JP.UTF-8）
line "3. ロケールを ja_JP.UTF-8 に設定します"
dnf -y install glibc-langpack-ja
localectl set-locale LANG=ja_JP.UTF-8
localectl status
if [ $? -ne 0 ]; then
	logOut "ERROR"  "3. ロケール設定に失敗しました"
	exitLog ${JOB_ER}
fi

# 4. ホスト名設定
line "4. ホスト名を ${hostname} に設定します"
hostnamectl set-hostname "${hostname}"
hostnamectl status
if [ $? -ne 0 ]; then
	logOut "ERROR"  "4. ホスト名設定に失敗しました"
	exitLog ${JOB_ER}
fi

# 5. ファイアウォール設定
line "5. firewalld を起動し、必要なポートを解放します"
systemctl enable firewalld --now
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=5000-5003/tcp
firewall-cmd --reload
firewall-cmd --list-all

# 6. rootログインを禁止設定
line "6. rootログインを禁止します"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
if [ $? -ne 0 ]; then
	logOut "ERROR"  "6. rootログインを禁止設定に失敗しました"
	exitLog ${JOB_ER}
fi

# 7. IPv6 を無効化設定
line "7. IPv6 を無効化します"
cat << EOS >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOS
sysctl -p

# 8. パッケージのアップデート
line "8. パッケージのアップデート"
dnf -y update
if [ $? -ne 0 ]; then
	logOut "dnf update 失敗"
	rc=$((rc + JOB_ER))
	exitLog $rc
fi

# 9. パッケージメタデータの事前キャッシュ
line "9. パッケージメタデータを事前にキャッシュします"
dnf makecache --refresh
if [ $? -ne 0 ]; then
	logOut "ERROR"  "9. パッケージメタデータの事前キャッシュに失敗しました"
	exitLog ${JOB_ER}
fi

# 10. 必要パッケージのインストール
line "10. 開発用パッケージのインストール"
dnf -y install vim unzip tcpdump net-tools bind-utils curl git rsync lsof zstd
	logOut "ERROR"  "10. 必要パッケージのインストール設定に失敗しました"
	exitLog ${JOB_ER}
fi

# 11. chronyd の設定
line "11. chronyd の再起動"
systemctl restart chronyd
if ! isProcessAlive "chronyd"; then
	logOut "chronyd 起動失敗"
	rc=$((rc + JOB_ER))
	exitLog $rc
fi

line "11.1 chronyd 状態確認"
systemctl --no-pager status chronyd

line "11.2 chrony 同期状態確認"
chronyc sources

line "11.3 chronyd 自動起動設定"
systemctl enable chronyd

# 12. limits.conf 設定
line "12. プロセス数上限設定"
edit_limits_conf
logOut "limits.conf 編集完了"
if [ $? -ne 0 ]; then
	logOut "ERROR"  "12. limits.conf 設定に失敗しました"
	exitLog ${JOB_ER}
fi

# 13. ファイルディスクリプタ上限緩和
line "13. ulimit -n を設定"
if ! grep -q "ulimit -n 65535" "$init_conf"; then
  echo "ulimit -n 65535" >> "$init_conf"
  logOut "ulimit 設定追記 [$init_conf]"
else
  logOut "ulimit は既に設定済み [$init_conf]"
fi

# 14. sysctl 設定
line "14. sysctl カーネルパラメータ設定"
if ! grep -q "net.core.somaxconn" "$sysctl_conf"; then
  cat << EOS >> "$sysctl_conf"
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.ip_local_reserved_ports = 23364,27017
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_tw_reuse = 1
EOS
fi

sysctl -p

# 15. crond 設定
line "15. crond 定期ジョブ設定"
cat << EOS > "$dailyjobs"
# Daily/Weekly/Monthly cron jobs
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root

02 15 * * * root [ ! -f /etc/cron.hourly/0anacron ] && run-parts /etc/cron.daily
22 15 * * 0 root [ ! -f /etc/cron.hourly/0anacron ] && run-parts /etc/cron.weekly
42 15 1 * * root [ ! -f /etc/cron.hourly/0anacron ] && run-parts /etc/cron.monthly
EOS

# ------------------------------------------------------------------
# post-process
# ------------------------------------------------------------------
scope="post"

endTimer                                  # タイマーを終了
exitLog $rc

