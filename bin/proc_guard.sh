#!/bin/sh
# ------------------------------------------------------------------
# proc_guard.sh - 多機能・多モード対応の常駐プロセス制御スクリプト
#
# Usage:
#   sh proc_guard.sh <configFile> <operation>
#
# 概要:
#   設定ファイル（conf）をもとに、監視対象プロセスを常駐実行・制御する汎用スクリプト。
#   実行対象のコマンドや監視間隔、ログパス、ロックディレクトリなどはすべて設定ファイルに定義。
#   operation により、起動、停止、状態確認、1回実行、設定再読み込み、テンプレート出力などが可能。
#
# 対応operation:
#   run        : プロセスを設定に基づき常駐実行（起動＋監視）
#   start      : 常駐監視プロセスを起動（バックグラウンド）
#   stop       : プロセスの停止（PIDファイルおよびロック破棄）
#   status     : 実行状態の確認
#   once       : 対象コマンドを1回だけ即時実行
#   reload     : 設定・コマンドファイルの再読み込み＋再実行
#   dump       : 現在の設定内容のダンプ表示
#   cleanup    : 異常終了時のロックファイル群の削除
#   log [arg]  : ログファイルを tail 表示（オプションでtail引数指定可）
#   list       : 登録された全監視プロセスの一覧表示
#   template   : 設定ファイルのテンプレート出力
#   help       : このヘルプを表示
#
# 備考:
#   引数で与える設定ファイルはフルパスで指定すること。
#   設定ファイル内で定義される内容により動作が完全に切り替わる設計。
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  〇〇〇〇〇  2025/07/19  Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ------------------------------------------------------------------
# 初期処理
# ------------------------------------------------------------------
. "$(dirname "$0")/../com/logger.shrc"
. "$(dirname "$0")/../com/utils.shrc"
startLog                                 # ログ出力を初期化
startTimer                               # 実行時間計測用タイマー開始
setLANG utf-8

# ------------------------------------------------------------------
# 関数名　　：usage
# 概要　　　：スクリプトの使い方を表示する
# 説明　　　：
#   対応する操作モードと引数の組み合わせを明示し、
#   configFileベースの監視処理と、グローバル操作の2系統を区別して表示。
#   tailログ表示、プロセスの一覧、設定の再読み込みなど、
#   オペレーション用のCLIとして自己完結できるように構成。
#
# 引数　　　：なし
# 戻り値　　：標準出力にヘルプを表示し、exit 1 で異常終了
# 使用箇所　：引数パース時のエラー、または `help` コマンド実行時
# ------------------------------------------------------------------
usage() {
  cat <<EOUSAGE

Usage:
  $0 <configFile> <operation-1>
  $0 <operation-2>

Description:
  configFile:
    フルパスで設定ファイルを指定してください。

  operation-1（設定ファイルを伴う操作）:
    status       現在の監視状態を表示します
    start        プロセス監視を開始します（常駐ループ）
    stop         プロセス監視を停止します
    reload       設定ファイルとコマンドファイルを再読み込みします
    once         1回だけジョブを即時実行します
    log [args]   ログを tail 表示します（[args] は tail にそのまま渡されます）
    dump         現在の設定情報を表示します
    cleanup      デッドロックディレクトリを削除します

  operation-2（グローバル操作）:
    list         すべての常駐監視プロセス一覧を表示します
    template     サンプル設定ファイルを表示します
    help         このヘルプを表示します

EOUSAGE
}


template() {
  cat $0 | sed -n '/TEMPLATE_BEGIN$/,/TEMPLATE_END$/p'
  return 0
#------------------------------------------------------------TEMPLATE_BEGIN
# sample config
name=your_process_name
basedir="/tmp/${name}"
logdir=${basedir}/log
lockD=${basedir}/lock
pidfile=${lockD}/pid
cmdfile=${lockD}/cmd
inifile=${lockD}/ini
logfile=${logdir}/${name}.`date "+%Y%m%d"`.log
interval=10
repeat=0
once=0
dumpvariables="name basedir lockD pidfile cmdfile logfile interval repeat once"

process() {
  value=`ps auxww | wc -l`
  if [ $value -gt 400 ]; then
    /usr/bin/logger "check processes... too many processes. : ${value}"
  fi
}
#------------------------------------------------------------TEMPLATE_END
}

# the job. please re-define this function in your config file.
process() {
  :
}

# echo with timestamp
loggingecho() {
  echo "[`date '+%Y-%m-%d %H:%M:%S'`] $*"
}

# directory preparation
prepareDirs() {
  for d in ${basedir} ${logdir}; do
    if [ ! -d ${d} ]; then
      mkdir -p ${d}
    fi
  done
}

# check user
invalidUser() {
  if [ `id -u` -eq 0 ]; then
    return 1
  fi
  echo "invoke me as root."
  return 0
}

# sleep intermittently.
intermittentSleep() {
  loggingecho sleeping [${interval}] sec...
  limit=${interval}
  a=0
  while ([ ${a} -lt ${limit} ])
  do
    let a=${a}+1 > /dev/null
    sleep 1
  done
}

# switch current logfile depend upon machine date.
switchLog() {
  logfile=${logdir}/${name}.`date "+%Y%m%d"`.log
  exec >> ${logfile} 2>&1
  if [ `ls ${logdir}/${name}.*.log | wc -l` -gt 8 ]; then
    ls -t ${logdir}/${name}.*.log | tail -1 | xargs rm
  fi
}

# bail out after clean up lock and working directory.
terminate() {
  switchLog
  status=0
  [ "$1" ] && status=$1
  loggingecho "terminating with status [${status}]..."
  cd ${lockD}/..
  rm -rf ${lockD}
  loggingecho "done."
  exit ${status}
}

# dump current setting variables for convenience.
dumpSetting() {
  cat /dev/null > ${inifile}
  for key in ${dumpvariables}
  do
    eval value=\$${key}
    echo ${key}=${value} >> ${inifile}
  done
}

# do the job only once
once() {
  loggingecho ==== on demand process start
  limit=0  # break sleeping
  once=1
}

# reload both config and command
reload() {
  loadConfig
  loadCommand
  dumpSetting
}

# search and decide the config file.
searchConfig() {
  if [ -f ${config} ]; then
    return 0
  fi
  for path in /home/rightarm/etc/`hostname` /usr/local/etc; do
    if [ -f $path/${config} ]; then
      config=${path}/${config}
      break
    fi
    if [ -f $path/${config}.shrc ]; then
      config=${path}/${config}.conf
      break
    fi
  done
}

# load config
loadConfig() {
  if [ -f ${config} ]; then
    load ${config}
  fi
}

# load command and remove it
loadCommand() {
  if [ -f ${cmdfile} ]; then
    load ${cmdfile}
    rm ${cmdfile}
    dumpSetting
  fi
}

# load one file.
load() {
  theFile=$1
  loggingecho loading [${theFile}]...
  . ${theFile}
  if [ ${terminate} -eq 1 ]; then
    loggingecho "terminate command accepted."
    terminate 0
  fi
  limit=0  # break intermittent sleep
}

# perform specified process
callProcess() {
  if [ ${repeat} -eq 1 -o ${once} -eq 1 ]; then
    process
    if [ ${once} -eq 1 ]; then
      once=0
    fi
  fi
}

# check status. (and clean up dead lock directory.)
checkStatus() {
  withClean=$1
  if [ -d ${lockD} ]; then
    if [ -f ${pidfile} ]; then
      pid=`cat ${pidfile}`
      loggingecho ${name} maybe running. pid = ${pid}
      count=`ps $PSOPT | grep ${config} | grep ${pid} | grep -v grep | wc -l`
      if [ $count -eq 0 ]; then
        loggingecho but ${pid} is not ${name}.
        if [ "$withClean" = "clean" ]; then
          loggingecho cleaning up lock directory ...
          cd / && rm -rf ${lockD}.dead && mv ${lockD} ${lockD}.dead
          loggingecho done.
        fi
      fi
    fi
  else
    loggingecho ${name} is not running.
  fi
}

#------------------------------------------------------------
# default variables
#------------------------------------------------------------
conf=""
name="common"
basedir="/tmp/cyclic"
logdir=${basedir}/log
lockD=${basedir}/lock
pidfile=${lockD}/pid
cmdfile=${lockD}/cmd
inifile=${lockD}/ini
logfile=${logdir}/${name}.`date "+%Y%m%d"`.log
interval=86400
limit=${interval}
terminate=0
repeat=0
once=0
dumpvariables="name interval pidfile cmdfile logfile"

#------------------------------------------------------------
# main routine
#------------------------------------------------------------
TZ="JST-9"
export TZ
invoked=`pwd`
cd `dirname $0`
fullname=`pwd`/${0##*/}
cd /
PSOPT="-aef"
case `uname` in
  FreeBSD) PSOPT="auxww" ;;
esac

# operation-2 group does not require config filename.
# so check them here.
if [ ! "$1" -o "$1" = "help" -o "$1" = "usage" ]; then
  usage
  exit 0
fi
if [ "$1" = "template" ]; then
  cd $invoked > /dev/null
  $1
  exit 0
fi
if [ "$1" = "list" ]; then
  PROGRAM=${0##*/}
  ps auxww | grep $PROGRAM | grep -v grep | grep ' run '
  exit 0
fi

# operation-1 group need config file for process information to run.
# check it before starting.
if [ $# -ge 2 ]; then
  config=$1
  shift
  searchConfig
  if [ ! -r ${config} ]; then
    echo "ERROR. no such file [${config}]."
    exit 1
  fi
  loadConfig
  if [ $? -ne 0 ];then
    echo "ERROR. can not load config [${config}]."
    exit 1
  fi
fi

# start
if [ "x$1" = "xstart" ]; then
  if invalidUser; then
    exit 0
  fi
  prepareDirs
  if [ -f ${pidfile} ]; then
    echo "already running. try $0 status"
    exit 0
  fi
  nohup $fullname $config run ver=$VERSION > /dev/null 2>&1 &
  sleep 1

  pid=`cat ${pidfile}`
  count=`ps auxww | grep ${pid} | grep -v grep | wc -l`
  if [ ${count} -eq 1 ]; then
    echo "may be launched."
    exit 0
  else
    echo "boot failure. check ${lockD}"
    [ -f ${logfile} ] && tail -5 ${logfile} || echo '(no logfile)'
    exit 1
  fi
fi

# stop
if [ "x$1" = "xstop" ]; then
  if invalidUser; then
    exit 0
  fi
  if [ -d ${lockD} ]; then
    if [ -f ${pidfile} ]; then
      pid=`cat ${pidfile}`
      status=`ps $PSOPT | grep ${config} | grep ${pid} | grep -v grep | wc -l`
      if [ ${status} -eq 1 ]; then
        kill ${pid}
        loggingecho "the process ${pid} was killed. return code : $?"
      else
        loggingecho "there is no process to be stopped."
      fi
    else
      loggingecho "it may be corrupted. check environment." 1>&2
      exit 1
    fi
  else
    loggingecho "there is no process to be stopped."
  fi
  exit 0
fi

case $1 in
"log")
  tail $2 ${logfile}
  exit 0
  ;;
"dump")
  cat ${inifile}
  exit 0
  ;;
"once")
  kill -USR1 `cat ${pidfile}`
  exit 0
  ;;
"reload")
  kill -USR2 `cat ${pidfile}`
  exit 0
  ;;
"status")
  checkStatus
  exit 0
  ;;
"cleanup")
  checkStatus clean
  exit 0
  ;;
"run")
  break
  ;;
*)
  usage
  exit 0
  ;;
esac

# entering infinite loop.

# check lock
if [ -d ${lockD} ]; then
  if [ -f ${pidfile} ]; then
    pid=`cat ${pidfile}`
  fi
  if [ "${pid}" ]; then
    loggingecho "is there doppelganger? please check pid=[${pid}]." 1>&2
    ps -aef | grep ${pid} | grep -v grep
    exit 0
  else
    loggingecho "it may be corrupted. check environment." 1>&2
    exit 1
  fi
else
  mkdir -p ${lockD} || exit 1
  echo $$ > ${pidfile}
  cd ${lockD}
fi

# define signal traps.
# see also  "man kill" and "/usr/include/sys/signal.h" for detail.
#define SIGHUP     1    /* hangup, generated when terminal disconnects */
#define SIGINT     2    /* interrupt, generated from terminal special char */
#define SIGQUIT    3    /* (*) quit, generated from terminal special char */
#define SIGTERM   15    /* software termination signal */
#define SIGUSR1   30    /* user defined signal 1 */
#define SIGUSR2   31    /* user defined signal 2 */
trap "terminate 0" 1 2 3 15
trap "once" 30
trap "reload" 31

# initialize.
switchLog
loggingecho initializing...

# dump current setting variables for convenience.
dumpSetting

# main loop.
loggingecho entering main loop.
while true
do
  switchLog
  loadCommand
  callProcess
  intermittentSleep
done