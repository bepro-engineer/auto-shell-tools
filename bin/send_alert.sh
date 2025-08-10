#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
#
# logger.sh ver.1.0.0 2025.07.20
#
# Usage:
#   sh send_alert.sh -m {start|stop|status|run|once|list} -u <unit_name> [-t {line|mail}] [-i <interval>]
#
# Description:
#   - root権限での実行必須
#   - 多重起動防止（ロック機構）
#   - PID管理対応
#
# 設計書
#     none
#
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# ＜変更履歴＞
# Ver. 変更管理No. 日付        更新者       変更内容
# 1.0  PR-0001    2025/07/16 Bepro       新規作成
#_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/
# 共通関数・ログ読み込み
. "$(dirname "$0")/../com/utils.shrc"
. "$(dirname "$0")/../com/logger.shrc"
setLANG utf-8

runAs root "$@"

# ------------------------------------------------------------------
# 変数宣言
# ------------------------------------------------------------------
scope="var"

host_id=$(hostname -s)
host_id=$(hostname -s)
LINE_CHANNEL_ACCESS_TOKEN=$(grep '^LINE_CHANNEL_ACCESS_TOKEN=' "${ETC_PATH}/${host_id}/.env" | cut -d '=' -f2-)
LINE_CHANNEL_SECRET=$(grep '^LINE_CHANNEL_SECRET=' "${ETC_PATH}/${host_id}/.env" | cut -d '=' -f2-)
MAIL_TO=""

mode=""
unit_name=""
target="mail"          # 通知先のデフォルトはmail
interval=60            # 監視間隔（秒）のデフォルト

# ロック管理用ディレクトリ・PIDファイル
lockD=""
pidfile=""
lock_owned=0

# ------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------
scope="func"

# 終了処理：トラップからの呼び出し用
terminate() {
    # 自分がロックを取っている時だけ解放する
    releaseLock "${unit_name}"
}

# ------------------------------------------------------------------
# 関数名　　：usage
# 概要　　　：スクリプトの使用方法を表示して終了する
# 説明　　　：
#   スクリプト実行時の引数指定方法を表示し、終了ステータス1で処理を終了する。
#   引数の誤りや不足がある場合に呼び出される想定。
#   モード、監視対象ユニット名、通知先、監視間隔などの指定方法を提示する。
#
# 引数　　　：なし（標準出力に使用方法を表示）
# 戻り値　　：1（異常終了）
# 使用箇所　：引数チェック処理（checkArgs 関数など）
# ------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 -m {start|stop|status|run|once|list} -u <unit_name> [-t {line|mail}] [-i <interval>]

  -m : モード（start|stop|status|run|once|list）
  -u : systemdユニット名（必須）
  -t : 通知先（line または mail、デフォルト mail）
  -i : 監視間隔（秒、runモード時、デフォルト60）
EOF
    exitLog ${JOB_WR}
}

# ------------------------------------------------------------------
# 関数名　　：acquireLock
# 概要　　　：ロックディレクトリとPIDファイルを作成し、二重起動を防止する
# 説明　　　：
#   指定されたロックディレクトリが存在しない場合は作成し、PIDファイルを生成する。
#   既にPIDファイルが存在し、かつそのプロセスが稼働中であれば処理を終了（ロック取得失敗）。
#   プロセスが存在しない場合はPIDファイルを削除し、再度ロックを取得する。
#
# 引数　　　：$1  ロック名（ユニット名など識別子）
# 戻り値　　：0 正常取得
# 　　　　　　1 ロック取得失敗（既に起動中またはディレクトリ作成失敗）
# 使用箇所　：startMonitor 関数など、常駐監視開始時
# ------------------------------------------------------------------
acquireLock() {
    logOut "DEBUG" "$0:acquireLock() STARTED !"

    local name="$1"

    # ロックディレクトリがなければ作成
    if [ ! -d "$lockD" ]; then
        logOut "DEBUGG" "ディレクトリを新規作成します。${lockD}"
        mkdir -p "$lockD" || return 1
    fi

    # 既存PID確認
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 1 # 既に起動中
        else
            # プロセス死んでたらクリア
            rm -rf "$pidfile"
        fi
    fi

    echo $$ > "$pidfile"

    logOut "DEBUG" "$0:acquireLock() ENDED !"
    return 0
}

# ------------------------------------------------------------------
# 関数名　　：releaseLock
# 概要　　　：ロックディレクトリと関連ファイルの削除処理
# 説明　　　：
#   ロックディレクトリ内のPIDファイルやnohupログを削除し、
#   その後ディレクトリを安全に削除する。
#   削除対象はTMP_PATH配下の「*.lock」ディレクトリに限定し、
#   誤削除を防止するためにパスチェックを行う。
#
# 引数　　　：なし（グローバル変数 lockD, pidfile を使用）
# 戻り値　　：なし
# 使用箇所　：stopMonitor 関数など、監視停止処理や終了処理時
# ------------------------------------------------------------------
releaseLock() {
    # 既知のファイルを個別に削除
    rm -f "${pidfile}" 2>/dev/null || true
    rm -f "${lockD}/nohup.log" 2>/dev/null || true
    rm -f "${lockD}/nohup.out" 2>/dev/null || true

    # 万一の取りこぼし（隠しファイル等）を掃除してからディレクトリ削除
    if [ -d "${lockD}" ]; then
        # TMP_PATH 配下かつ 「<unit>.lock」形式だけを安全に削除
        case "${lockD}" in
            "${TMP_PATH}/"*.lock)
                # 既存ファイルを全削除（意図せぬパス破壊を避けるため -rf は限定的に）
                rm -f "${lockD}/"* "${lockD}"/.[!.]* "${lockD}"/..?* 2>/dev/null || true
                rmdir "${lockD}" 2>/dev/null || true
                ;;
        esac
    fi
}

# ------------------------------------------------------------------
# 関数名　　：checkArgs
# 概要　　　：コマンドライン引数の検証処理
# 説明　　　：
#   モード(-m)やユニット名(-u)、監視間隔(-i)、通知先(-t)の
#   必須性と値の妥当性をチェックする。
#   不正または不足があれば usage 関数を呼び出して終了する。
#
# 引数　　　：なし（グローバル変数 mode, unit_name, interval, target を使用）
# 戻り値　　：なし（不正時は usage 関数で終了）
# 使用箇所　：スクリプト実行開始直後の引数解析後
# ------------------------------------------------------------------
checkArgs() {
    if [ -z "${mode}" ]; then
        logOut "ERROR" "モード(-m)が指定されていません。"
        usage
    fi

    case "${mode}" in
        start|stop|status|once)
            if [ -z "${unit_name}" ]; then
                logOut "ERROR" "モード[${mode}]では -u ユニット名が必須です。"
                usage
            fi
            ;;
        run)
            if [ -z "${unit_name}" ]; then
                logOut "ERROR" "モード[run]では -u ユニット名が必須です。"
                usage
            fi
            if ! echo "${interval}" | grep -qE '^[0-9]+$'; then
                logOut "ERROR" "監視間隔(-i)は正の整数で指定してください。"
                usage
            fi
            if [ "${target}" != "line" ] && [ "${target}" != "mail" ]; then
                logOut "ERROR" "通知先(-t)は 'line' か 'mail' を指定してください。"
                usage
            fi
            ;;
        list)
            # listモードは特に必須引数なし
            ;;
        *)
            logOut "ERROR" "不正なモードが指定されました: ${mode}"
            usage
            ;;
    esac
}

# ------------------------------------------------------------------
# 関数名　　：checkUnitExists
# 概要　　　：指定された systemd ユニットの存在確認
# 説明　　　：
#   引数やグローバル変数で指定されたユニット名が
#   systemctl list-unit-files の一覧に存在するかを確認する。
#   存在しない場合はエラーログを出力して終了する。
#
# 引数　　　：なし（グローバル変数 unit_name を使用）
# 戻り値　　：なし（存在しない場合は exit 1 で終了）
# 使用箇所　：startMonitor、runMonitor などユニット操作前の検証処理
# ------------------------------------------------------------------
checkUnitExists() {
    if ! systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -qw "${unit_name}"; then
        logOut "ERROR" "ユニット [${unit_name}] は存在しません。"
        exit 1
    fi
}

# ------------------------------------------------------------------
# 関数名　　：runMonitor
# 概要　　　：監視プロセスの常駐監視処理
# 説明　　　：
#   指定されたユニットのプロセス状態を定期的に確認し、
#   必要に応じてアラートを送信する。
# 引数　　　：なし
# 戻り値　　：なし（無限ループ）
# 使用箇所　：main-process（-m run 時）
# ------------------------------------------------------------------
runMonitor() {
    logOut "DEBUG" "$0:runMonitor() STARTED !"
    while true; do
        if ! pgrep -f "${unit_name}" > /dev/null 2>&1; then
            logOut "ERROR" "[${unit_name}] プロセスが停止しています。アラート送信します。"
        fi
        
        checkJournald

        logOut "DEBUG" "${interval}"
        sleep "${interval}"
    done
    logOut "DEBUG" "$0:runMonitor() ENDED !"
}

# ------------------------------------------------------------------
# 関数名　　：startMonitor
# 概要　　　：監視プロセスの起動
# 説明　　　：
#   ロックディレクトリとPIDファイルの有無を確認し、
#   実行中でなければ監視処理(runMonitor)をバックグラウンドで開始する。
# 引数　　　：なし（グローバル変数 unit_name を利用）
# 戻り値　　：0=正常, 1=異常
# 使用箇所　：main-process（-m start 時）
# ------------------------------------------------------------------
startMonitor() {
    logOut "DEBUG" "$0:startMonitor() STARTED !"

    checkUnitExists

    if [ -f "${pidfile}" ]; then
        pid=$(cat "${pidfile}")
        logOut "DEBUG" "${pid}"
        if ps -p "${pid}" > /dev/null 2>&1; then
            logOut "INFO" "監視プロセスは既に起動中です。PID: ${pid}"
            logOut "DEBUG" "$0:startMonitor() ENDED !"
            return 0
        else
            logOut "WARNING" "PIDファイルは存在しますが、プロセスが存在しません。再起動します。"
        fi
    fi

    prepareDir "${lockD}"

    logOut "DEBUG" "nohup ${BIN_PATH}/${SCRIPT_NAME} -m run -u ${unit_name} -t ${target} -i ${interval} > ${lockD}/nohup.log 2>&1 &"
    nohup "${BIN_PATH}/${SCRIPT_NAME}" -m run -u "${unit_name}" -t "${target}" -i "${interval}" > "${lockD}/nohup.log" 2>&1 &

    sleep 2

    pid=$(pgrep -f "${BIN_PATH}/${SCRIPT_NAME}.*-m run.*-u ${unit_name}")
    if [ -z "${pid}" ]; then
        logOut "ERROR" "監視プロセスの起動に失敗しました。nohupログを確認してください。"
        logOut "DEBUG" "$0:startMonitor() ENDED !"
        exitLog ${JOB_ER}
    fi

    echo "${pid}" > "${pidfile}"
    logOut "INFO" "監視プロセスを起動しました。PID: ${pid}"

    logOut "DEBUG" "$0:startMonitor() ENDED !"
}

# ------------------------------------------------------------------
# 関数名　　：stopMonitor
# 概要　　　：監視スクリプトを終了させる
# 説明　　　：
#   ・指定されたユニット名に対応するロックディレクトリとPIDファイルを確認
#   ・PIDファイルのプロセスが稼働中なら終了させる
#   ・ロックを解除して監視状態を停止
#
# 引数　　　：なし（事前に unit_name 変数が設定されていること）
# 戻り値　　：正常終了=0 / 異常終了=2
# 使用箇所　：send_alert.sh の main-process 内
# ------------------------------------------------------------------
stopMonitor() {
    logOut "DEBUG" "$0:stopMonitor() 開始"

    # ロックディレクトリの存在確認
    if [ ! -d "${lockD}" ]; then
        logOut "ERROR" "監視は実行されていません: ${unit_name}"
        exitLog ${JOB_ER}
    fi

    # PIDファイル存在確認
    if [ ! -f "${pidfile}" ]; then
        logOut "ERROR" "PIDファイルが存在しません: ${pidfile}"
        exitLog ${JOB_ER}
    fi

    pid=$(cat "${pidfile}")

    if [ -z "${pid}" ]; then
        logOut "ERROR" "PIDが取得できません: ${pidfile}"
        exitLog ${JOB_ER}
    fi

    # プロセス稼働確認
    if ps -p "${pid}" >/dev/null 2>&1; then
        logOut "DEBUG" "kill -9 ${pid}"
        kill -9 "${pid}" >/dev/null 2>&1
        logOut "INFO" "監視プロセス(${pid})を終了しました。"
    else
        logOut "WARN" "監視プロセスはすでに存在しません: PID=${pid}"
    fi

    # ロック解除
    releaseLock

    logOut "DEBUG" "$0:stopMonitor() 終了"
}

# ------------------------------------------------------------------
# 関数名　　：statusMonitor
# 概要　　　：監視プロセスの稼働状況確認
# 説明　　　：
#   PIDファイルと実プロセスの存在を確認して稼働状況を出力する。
# 引数　　　：なし
# 戻り値　　：0=起動中, 1=未起動
# 使用箇所　：main-process（-m status 時）
# ------------------------------------------------------------------
statusMonitor() {
    logOut "DEBUG" "$0:statusMonitor() STARTED !"

    checkUnitExists

    if [ -f "${pidfile}" ]; then
        pid=$(cat "${pidfile}")
        if ps -p "${pid}" > /dev/null 2>&1; then
            logOut "INFO" "監視プロセスは起動中です。PID: ${pid}"
            logOut "DEBUG" "$0:statusMonitor() ENDED !"
            return 0
        else
            logOut "INFO" "監視プロセスは停止しています。（PIDファイルのみ存在）"
            logOut "DEBUG" "$0:statusMonitor() ENDED !"
            return 1
        fi
    else
        logOut "INFO" "監視プロセスは起動していません。"
        logOut "DEBUG" "$0:statusMonitor() ENDED !"
        return 1
    fi
}

# 単発監視（onceモード）
onceMonitor() {
    logOut "DEBUG" "$0:onceMonitor() STARTED"

    checkUnitExists
    # バックグラウンド監視が動いていても強制実行（ロックを取らない）
    checkJournald "once"

    # ロック解除
    releaseLock

    logOut "DEBUG" "$0:onceMonitor() ENDED"
}

# ------------------------------------------------------------------
# 関数名　　：checkJournald
# 概要　　　：指定されたユニットの systemd ログおよび logger タグ付きログから
# 　　　　　エラーや警告を抽出し、必要に応じて通知を送信する。
# 説明　　　：
#   - systemd の `-u`（ユニット名）と `-t`（logger タグ）の両方からログを取得し、
#     エラー/警告パターンにマッチする行を抽出する。
#   - 前回実行時刻からの差分のみを読み込むことで、過去ログの重複検出を防ぐ。
#   - 同一内容のエラーは再送信せず、初回または変化があった場合のみ通知する。
#   - 取得ログはマージし、重複行を削除してから通知する。
#   - 通知方法は mail または line を選択可能。
#
# 引数　　　：なし（グローバル変数 unit_name, TMP_PATH, target を使用）
# 戻り値　　：なし（処理結果はログ出力・通知）
# 使用箇所　：send_alert.sh 内の監視ループや once 実行時
# ------------------------------------------------------------------
checkJournald() {
    logOut "DEBUG" "$0:checkJournald() STARTED"
    
    local mode="${1:-run}"
    local pattern="error|fail|fatal|warning|warn|killing|【.*ERROR.*】"
    local last_msg_file="${TMP_PATH}/checkJournald_${unit_name}.last"
    local since_file="${TMP_PATH}/journal_since_${unit_name}.ts"

    # 直近だけ読む（初回は15分前）。以降は前回UNIX時刻から。
    local since_opt
    if [ -s "${since_file}" ]; then
        since_opt="--since @$(cat "${since_file}")"
    else
        since_opt="--since now-15min"
    fi

    # -u (systemd) と -t (logger -p のタグ) を別々に取得
    local systemd_logs logger_logs message
    systemd_logs=$(journalctl -u "${unit_name}" ${since_opt} --no-pager -o cat | grep -iE "${pattern}" 2>/dev/null || true)
    logger_logs=$(journalctl -t "${unit_name}" ${since_opt} --no-pager -o cat | grep -iE "${pattern}" 2>/dev/null || true)

    # マージ・重複排除・上限
    message=$(printf "%s\n%s" "${systemd_logs}" "${logger_logs}" \
        | sed '/^[[:space:]]*$/d' | sort -u | tail -n 200)

    logOut "DEBUG" "MESSAGE:${message}"

    # 検出なし → 復帰扱い（前回内容を消して時刻だけ前進）
    if [ -z "${message}" ]; then
        [ -f "${last_msg_file}" ] && rm -f "${last_msg_file}"
        date +%s > "${since_file}"
        logOut "DEBUG" "エラーは検出されませんでした。"
        logOut "DEBUG" "$0:checkJournald() ENDED"
        return
    fi

    # 同一内容は送らない（ただし時刻は前進）
    if [ -f "${last_msg_file}" ] && diff -q "${last_msg_file}" - <<< "${message}" >/dev/null 2>&1; then
        date +%s > "${since_file}"
        logOut "DEBUG" "同一エラーメッセージのため送信をスキップ"
        logOut "DEBUG" "$0:checkJournald() ENDED"
        return
    fi

    # 保存＆通知
    printf "%s\n" "${message}" > "${last_msg_file}"
    case "${target}" in
        line) sendToLine "${message}" ;;
        mail) sendToMail "${message}" ;;
        *)    logOut "ERROR" "通知先が不明: ${target}" ;;
    esac

    # 次回用の since（境界落ち防止で -1 秒）
    ts_now="$(date +%s)"; printf "%s\n" "$((ts_now-1))" > "${since_file}"

    logOut "DEBUG" "$0:checkJournald() ENDED"
}

# ------------------------------------------------------------------
# 関数名　　：listMonitor
# 概要　　　：現在実行中の監視ジョブ一覧を表示する
# 説明　　　：
#   TMP_PATH配下の *.lock ディレクトリをスキャンし、
#   その中の PID ファイルを読み込んで稼働状況を出力する。
# 引数　　　：なし
# 戻り値　　：0=正常, 1=未起動
# 使用箇所　：main-process（-m list 時）
# ------------------------------------------------------------------
listMonitor() {
    logOut "DEBUG" "$0:listMonitors() STARTED !"

    local found=0
    for lock_dir in "${TMP_PATH}"/*.lock; do
        [ ! -d "$lock_dir" ] && continue
        local unit
        unit=$(basename "$lock_dir" .lock)
        local pidfile="$lock_dir/${unit}_pid"

        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            if ps -p "$pid" > /dev/null 2>&1; then
                logOut "INFO" "[${unit}] 起動中 (PID: ${pid})"
            else
                logOut "WARN" "[${unit}] 停止中 (PIDファイルあり)"
            fi
            found=1
        else
            logOut "WARN" "[${unit}] PIDファイルなし"
            found=1
        fi
    done

    [ $found -eq 0 ] && logOut "INFO" "現在起動中の監視ジョブはありません。"

    logOut "DEBUG" "$0:listMonitors() ENDED !"
}

# ------------------------------------------------------------------
# 関数名　　：sendToLine
# 概要　　　：LINE通知処理
# 説明　　　：
#   LINE Notify等のAPIを利用してメッセージを送信します。
# 引数　　　：$1 - 送信するメッセージ内容
# 戻り値　　：なし
# 使用箇所　：checkJournald
# ------------------------------------------------------------------
sendToLine() {
    logOut "DEBUG" "$0:sendToLine() STARTED !"

    # 必要な環境変数の確認
    if [ -z "${LINE_CHANNEL_ACCESS_TOKEN}" ]; then
        logOut "ERROR" "LINE_CHANNEL_ACCESS_TOKEN が未設定です。etc/${host_id}/.env を確認してください。"
        return 1
    fi
    if [ -z "$1" ]; then
        logOut "ERROR" "送信メッセージが指定されていません。"
        return 1
    fi

    # 引数のメッセージを行単位で送信（長文は分割）
    echo "$1" | while IFS= read -r line || [ -n "$line" ]; do
        # JSON用に最低限のエスケープ（\ と "）
        esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')

        payload=$(printf '{"messages":[{"type":"text","text":"%s"}]}' "$esc")

        if curl -sS -X POST "https://api.line.me/v2/bot/message/broadcast" \
            -H "Authorization: Bearer ${LINE_CHANNEL_ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${payload}" >/dev/null 2>&1; then
            logOut "INFO" "[LINE/MessagingAPI] broadcast OK: ${line}"
        else
            logOut "ERROR" "[LINE/MessagingAPI] broadcast NG: ${line}"
        fi

        # API連投対策
        sleep 0.2
    done

    logOut "DEBUG" "$0:sendToLine() ENDED !"
}

# ------------------------------------------------------------------
# 関数名　　：sendToMail
# 概要　　　：メール通知処理
# 説明　　　：
#   mailコマンド等を利用して通知メールを送信します。
# 引数　　　：$1 - 送信するメッセージ内容
# 戻り値　　：なし
# 使用箇所　：checkJournald
# ------------------------------------------------------------------
sendToMail() {
    logOut "DEBUG" "$0:sendToMail() STARTED !"

    logOut "INFO" "(MAIL) $1"
    echo "$1" | mail -s "[ErrorLog] ${unit_name}" $MAIL_TO
    logOut "DEBUG" "MAIL_TO:${MAIL_TO}"

    logOut "DEBUG" "$0:sendToMail() ENDED !"
}

# ----------------------------------------------------------
# pre-process
# ----------------------------------------------------------
scope="pre"

startLog
trap "terminate" 0 1 2 3 15

# 引数解析
while getopts ":m:u:t:i:" opt; do
    case "$opt" in
        m) mode="$OPTARG" ;;
        u) unit_name="$OPTARG" ;;
        t) target="$OPTARG" ;;
        i) interval="$OPTARG" ;;
        *) usage ;;
    esac
done

# lockD設定はunit_nameが決まってから
lockD="${TMP_PATH}/${unit_name}.lock"
pidfile="${lockD}/${unit_name}_pid"

checkArgs

# ----------------------------------------------------------
# main-routine
# ----------------------------------------------------------
scope="main"

case "${mode}" in
    start)  startMonitor ;;
    stop)   stopMonitor ;;
    status) statusMonitor ;;
    run)    runMonitor ;;
    once)   onceMonitor ;;
    list)   listMonitor ;;
    *)      usage ;;
esac

scope="post"
exitLog ${JOB_OK}