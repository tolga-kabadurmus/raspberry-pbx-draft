#!/usr/bin/env bash

set -euo pipefail

#############################################
#               GLOBAL CONFIG
#############################################

MAX_RETRIES=3
RETRY_SLEEP_SECONDS=10

# docker exec timeout (seconds)
DOCKER_EXEC_TIMEOUT=15

INTERNET_CHECK_URL="https://1.1.1.1"

DEFAULT_ASTERISK_SERVICE="asterisk.service"
DEFAULT_CONTAINER_NAME="asterisk-dongle"

# RSSI eşik değerleri
RSSI_WARN_THRESHOLD=10
RSSI_CRITICAL_THRESHOLD=5

#############################################
#               ARGUMENTS
#############################################

ASTERISK_SERVICE="${1:-$DEFAULT_ASTERISK_SERVICE}"
CONTAINER_NAME="${2:-$DEFAULT_CONTAINER_NAME}"

#############################################
#          STATE + LOG CONFIG
#############################################

WATCHDOG_DIR="/mnt/ssd/freepbx/log/asterisk/watchdog"
STATE_FILE="$WATCHDOG_DIR/state"
ALERT_TS_FILE="$WATCHDOG_DIR/last_alert_ts"

ALERT_INTERVAL_SEC=600   # 10 dakika

mkdir -p "$WATCHDOG_DIR"

[ -f "$STATE_FILE" ]    || echo "OK" > "$STATE_FILE"
[ -f "$ALERT_TS_FILE" ] || echo "0"  > "$ALERT_TS_FILE"

# 30 günden eski .bak dosyalarını sil
find "$WATCHDOG_DIR" -name "watchdog.log.*.bak" -mtime +30 -delete

#############################################
#               NOTIFICATIONS
#############################################

notify_user() {
    local msg="$1"

    local_log "INFO" "Try to notify user. Message => \"$msg\""

    # --- Telegram (token ve chat_id'yi doldurun) ---
    # local TELEGRAM_TOKEN="YOUR_BOT_TOKEN"
    # local TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
    # curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    #     --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    #     --data-urlencode "text=${msg}" > /dev/null 2>&1

    # --- Email ---
    # mail -s "Watchdog Alert" user@example.com <<< "$msg"

    return 0
}

#############################################
#               LOGGING
#############################################

journal_notify() {
    local level="$1"
    local message="$2"

    local prev_state
    prev_state=$(get_state)

    local new_state="$prev_state"

    if [[ "$level" == "ERROR" ]]; then
        new_state="CRITICAL"
    elif [[ "$level" == "OK" ]]; then
        new_state="OK"
    fi

    echo "[${level}] ${message}"
    local_log "$level" "$message"

    local now_ts
    now_ts=$(date +%s)

    # ------------------------------
    # CRITICAL HANDLING (Re-alert)
    # ------------------------------
    if [[ "$new_state" == "CRITICAL" ]]; then

        local last_alert_ts
        last_alert_ts=$(get_last_alert_ts)

        local elapsed=0
        if [[ -n "$last_alert_ts" ]]; then
            elapsed=$((now_ts - last_alert_ts))
        fi

        if [[ "$prev_state" != "CRITICAL" || "$elapsed" -ge "$ALERT_INTERVAL_SEC" ]]; then

            local_log "ALERT" "CRITICAL alert triggered (elapsed=${elapsed}s)"

            if notify_user "CRITICAL: ${message} (elapsed=${elapsed}s)"; then
                local_log "INFO" "User notified about alert"
                set_last_alert_ts
            else
                local_log "ERROR" "Notify failed (CRITICAL)"
            fi
        fi
    fi

    # ------------------------------
    # RECOVERY HANDLING (One-shot)
    # ------------------------------
    if [[ "$new_state" == "OK" && "$prev_state" == "CRITICAL" ]]; then

        local_log "INFO" "RECOVERED_FROM_CRITICAL"

        if notify_user "OK: System recovered - ${message}"; then
            local_log "INFO" "Recovery notification sent"
        else
            local_log "ERROR" "Recovery notification failed (no retry)"
        fi
    fi

    # ------------------------------
    # STATE UPDATE
    # ------------------------------
    if [[ "$new_state" != "$prev_state" ]]; then
        local_log "INFO" "STATE_CHANGE ${prev_state} -> ${new_state}"
        set_state "$new_state"
    fi
}

#############################################
#           STATE MANAGEMENT
#############################################

get_state() {
    cat "$STATE_FILE"
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

get_last_alert_ts() {
    cat "$ALERT_TS_FILE"
}

set_last_alert_ts() {
    date +%s > "$ALERT_TS_FILE"
}

local_log() {
    local level="$1"
    local message="$2"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$ts][$level] $message" >> "$LOCAL_LOG_FILE"
}

#############################################
#           GENERIC RETRY HANDLER
#############################################

retry_check() {
    local fail_message="$1"
    shift

    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        echo "[INFO] Attempt ${attempt}/${MAX_RETRIES}..."

        if "$@"; then
            echo "[OK] Check passed on attempt ${attempt}."
            return 0
        fi

        if (( attempt < MAX_RETRIES )); then
            echo "[WARN] Attempt ${attempt} failed. Retrying in ${RETRY_SLEEP_SECONDS}s..."
            sleep "$RETRY_SLEEP_SECONDS"
        fi

        attempt=$((attempt + 1))   # FIX: ((attempt++)) yerine — set -e ile güvenli
    done

    journal_notify "ERROR" "$fail_message"
    return 1
}

#############################################
#               CHECK FUNCTIONS
#############################################

check_internet() {
    curl --silent --fail --connect-timeout 5 "$INTERNET_CHECK_URL" > /dev/null 2>&1 || \
    curl --silent --fail --connect-timeout 5 "https://8.8.8.8" > /dev/null 2>&1
}

handle_internet() {
    if retry_check "Internet connection not available." check_internet; then
        echo "[OK] Internet connection available."
        return 0
    else
        return 1
    fi
}

check_docker_service() {
    systemctl is-active --quiet docker.service
}

handle_docker_service() {
    if retry_check "docker.service inactive." check_docker_service; then
        echo "[OK] docker.service active."
        return 0
    else
        return 1
    fi
}

check_asterisk_service() {
    systemctl is-active --quiet "$ASTERISK_SERVICE"
}

handle_asterisk_service() {
    if retry_check "$ASTERISK_SERVICE inactive." check_asterisk_service; then
        echo "[OK] $ASTERISK_SERVICE active."
        return 0
    else
        return 1
    fi
}

check_container_running() {
    docker ps --format '{{.Names}}' | grep -w "$CONTAINER_NAME" > /dev/null 2>&1
}

handle_container() {
    if retry_check "Container $CONTAINER_NAME not running." check_container_running; then
        echo "[OK] Container $CONTAINER_NAME running."
        return 0
    else
        return 1
    fi
}

#############################################
#         CONTAINER INTERNAL CHECKS
#############################################

find_container_name() {
    if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
        echo "$CONTAINER_NAME"
        return 0
    else
        echo "[ERROR] Container $CONTAINER_NAME not running or not found."
        return 1
    fi
}

exec_into_container() {
    local container="$1"
    local command="$2"

    echo "[INFO] Exec: $command"

    local exit_code=0
    timeout "$DOCKER_EXEC_TIMEOUT" \
        docker exec "$container" bash -c "$command" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "[OK] Command executed successfully."
        return 0
    elif [[ $exit_code -eq 124 ]]; then
        echo "[ERROR] Command timeout (${DOCKER_EXEC_TIMEOUT}s)."
    else
        echo "[ERROR] Command failed. Exit code: $exit_code"
    fi

    return 1
}

handle_container_internal_checks() {

    local container
    container=$(find_container_name) || return 1
    echo "[OK] Container found => $container"

    # check_msgs ve check_cmds aynı sırada olmalı — her indeks birbirine karşılık gelir
    check_msgs=(
        "chan_dongle modülü yüklü değil."
        "Dongle cihazı bağlı değil veya hazır durumda değil."
        "PJSIP contact Avail değil. Linphone uygulamasını açıp bağlantıyı kontrol edin."
    )

    check_cmds=(
        # 1. chan_dongle modülü yüklü mü?
        "asterisk -rx 'module show like dongle' | grep chan_dongle.so"

        # 2. Dongle bağlı ve Free/Busy durumunda mı?
        "asterisk -rx 'dongle show devices' | grep dongle0 | grep -E 'Free|Busy'"

        # 3. PJSIP contact Avail mi? (en az 1 Avail yeterli)
        "asterisk -rx 'pjsip show contacts' | grep '100' | grep 'Avail'"
    )

    for i in "${!check_msgs[@]}"; do
        retry_check \
            "${check_msgs[$i]}" \
            exec_into_container \
            "$container" \
            "${check_cmds[$i]}" \
            || return 1
    done

    echo "[OK] Container internal checks passed."
    return 0
}

#############################################
#           DONGLE SIGNAL CHECK
#############################################

check_dongle_signal() {
    local rssi
    rssi=$(timeout "$DOCKER_EXEC_TIMEOUT" \
        docker exec "$CONTAINER_NAME" \
        bash -c "asterisk -rx 'dongle show devices' | grep dongle0 | awk '{print \$4}'")

    # Değer gelmedi mi?
    if [[ -z "$rssi" ]]; then
        echo "[ERROR] RSSI değeri okunamadı."
        return 1
    fi

    # Geçersiz değerler (0 = bilinmiyor, 99 = sinyal yok)
    if [[ "$rssi" -eq 0 || "$rssi" -eq 99 ]]; then
        echo "[ERROR] Geçersiz RSSI: $rssi (dongle şebekeye kayıtlı olmayabilir)"
        return 1
    fi

    # Kritik eşik
    if [[ "$rssi" -lt "$RSSI_CRITICAL_THRESHOLD" ]]; then
        echo "[ERROR] RSSI kritik seviyede düşük: $rssi (eşik: $RSSI_CRITICAL_THRESHOLD)"
        return 1
    fi

    # Uyarı eşiği — watchdog'u durdurmaz, sadece loglar
    if [[ "$rssi" -lt "$RSSI_WARN_THRESHOLD" ]]; then
        echo "[WARN] RSSI düşük: $rssi (eşik: $RSSI_WARN_THRESHOLD)"
        journal_notify "WARN" "Sinyal zayıf: RSSI=$rssi"
        return 0
    fi

    echo "[OK] RSSI: $rssi"
    return 0
}

handle_dongle_signal() {
    if retry_check "Dongle sinyal gücü kritik seviyede düşük." check_dongle_signal; then
        echo "[OK] Dongle sinyal kontrolü geçti."
        return 0
    else
        return 1
    fi
}

#############################################
#               MAIN FLOW
#############################################

concurrency_lock() {
    LOCK_FILE="/var/run/asterisk-watchdog.lock"
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
        echo "Another instance is already running."
        exit 1
    }
}

main() {
    concurrency_lock || return 1

    handle_internet                  || return 1
    handle_docker_service            || return 1
    handle_asterisk_service          || return 1
    handle_container                 || return 1
    handle_container_internal_checks || return 1
    handle_dongle_signal             || return 1

    journal_notify "OK" "All checks passed."
    return 0
}

main
exit $?
