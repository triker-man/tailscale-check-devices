# [SYSTEM CONTEXT & HANDOFF DOCUMENT]
**Project:** Tailscale Node Monitor & Telegram Notifier for OpenWRT.
**Language:** Bash Script.
**Target Environment:** OpenWRT Router (Linux embedded, ash/bash, busybox).
**Execution Frequency:** Cron job, every 1 minute.

## 1. Project Summary
The user has a script running on an OpenWRT router that checks the status of Tailscale nodes via `tailscale status --json`, compares it with the previous state, and sends grouped Telegram notifications if nodes go ONLINE or OFFLINE. 

## 2. Critical Design Decisions & Constraints (DO NOT REVERT)
As the target environment is OpenWRT running on flash memory, the following architectural decisions were made and MUST be preserved in future updates:
* **Flash Wear-Leveling Protection:** The state file (`tailscale-check_state.json`) is stored in `/tmp/` (RAM disk), NOT in `/overlay/` or flash memory, because the script runs every minute. 
* **Atomic Writes:** State is saved using `echo > file.tmp` followed by `mv file.tmp file` to prevent corruption if the script is interrupted.
* **Anti-Spam / Rate Limiting:** Telegram notifications are grouped into a single message per execution. We do NOT send one API request per node to avoid Telegram API bans during mass disconnects.
* **Concurrency Control:** The OpenWRT native `lock` command (`/var/run/tailscale-check.lock`) is used to prevent overlapping executions if curl or tailscale hang.
* **Logging:** Errors are not just echoed; they are sent to the system log using OpenWRT's `logger` command.
* **Exclusions Support:** The script reads `/overlay/tailscale-check-devices.exclusions` to ignore noisy devices (e.g., mobile phones). It strips Windows `\r` carriage returns and ignores empty lines and `#` comments.
* **JSON Parsing Fix:** `jq` parses `.value.HostName` instead of `.value.DNSName` to prevent bugs where Windows nodes (or nodes pending MagicDNS propagation) were ignored.
* **Encoding:** The script avoids using special characters (accents, ñ) in variables and Telegram messages because pasting via `busybox vi` over SSH in OpenWRT corrupts UTF-8 characters.

## 3. Current File Structure
* `/overlay/telegram-credentials.dat` -> Contains `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.
* `/overlay/tailscale-check-devices.exclusions` -> List of HostNames to ignore (one per line).
* `/overlay/tailscale-check-devices.sh` -> The main executable script.
* `/tmp/tailscale-check_state.json` -> The JSON state file (stored in RAM).

## 4. Current Codebase (Latest Stable Version)
```bash
#!/bin/bash

# ==========================================
# Configuracion y Constantes
# ==========================================
CREDS_FILE="/overlay/telegram-credentials.dat"
EXCLUSIONS_FILE="/overlay/tailscale-check-devices.exclusions"

# Archivos de estado en /tmp/ (RAM) para no quemar la memoria Flash
STATE_FILE="/tmp/tailscale-check_state.json"
STATE_FILE_TMP="${STATE_FILE}.tmp"
LOCK_FILE="/var/run/tailscale-check.lock"

TAILSCALE_CMD="tailscale status --json"
MAX_RETRIES=3
RETRY_DELAY=5

# Emojis
WARNING_EMOJI=$(echo -e "\U26A0\UFE0F")
ONLINE_EMOJI=$(echo -e "\U1F7E2")
OFFLINE_EMOJI=$(echo -e "\U1F534")
STATS_EMOJI=$(echo -e "\U1F4CA")

# ==========================================
# Validaciones Iniciales
# ==========================================

for cmd in jq curl tailscale lock; do
    if ! command -v $cmd >/dev/null 2>&1; then
        logger -t "tailscale-check" "Error critico: El comando '$cmd' no esta instalado."
        exit 1
    fi
done

if [ ! -f "$CREDS_FILE" ]; then
    logger -t "tailscale-check" "Error: Archivo de credenciales no encontrado en $CREDS_FILE"
    exit 1
fi

source "$CREDS_FILE"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    logger -t "tailscale-check" "Error: TELEGRAM_BOT_TOKEN o TELEGRAM_CHAT_ID no estan definidos."
    exit 1
fi

# ==========================================
# Funciones
# ==========================================

send_telegram_message() {
    local message="$1"
    local http_code
    
    http_code=$(curl -s -w "%{http_code}" -o /dev/null --connect-timeout 5 --max-time 10 \
        -X POST "[https://api.telegram.org/bot$](https://api.telegram.org/bot$){TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true")
        
    if [ "$http_code" -ne 200 ]; then
        logger -t "tailscale-check" "Advertencia: Fallo al enviar mensaje de Telegram. HTTP Code: $http_code"
    fi
}

check_tailscale_status() {
    local retries=0
    local status_output=""
    
    while [ $retries -lt $MAX_RETRIES ]; do
        status_output=$(${TAILSCALE_CMD} 2>&1)
        if [ $? -eq 0 ]; then
            echo "$status_output"
            return 0
        fi
        
        retries=$((retries + 1))
        [ $retries -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
    done
    
    local error_msg="${WARNING_EMOJI} WARNING: No se pudo obtener el estado de Tailscale tras ${MAX_RETRIES} intentos."
    logger -t "tailscale-check" "$error_msg. Error: $status_output"
    send_telegram_message "$error_msg"
    return 1
}

get_nodes_status() {
    local json_data="$1"
    # Note: Using HostName instead of DNSName to fix issues with Windows nodes.
    echo "$json_data" | jq -r 'if .Peer == null then empty else .Peer | to_entries[] | select(.value.HostName != null) | "\(.value.HostName)|\(.value.Online)|\(.value.TailscaleIPs[0])|\(.value.LastSeen)" end'
}

load_previous_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
        return 0
    fi
    return 1
}

save_current_state() {
    echo "$1" > "$STATE_FILE_TMP"
    mv "$STATE_FILE_TMP" "$STATE_FILE"
}

send_initial_state() {                                                                                                                                                                                                                           
    local current_state="$1"                                                                                                                                                                                                                     
    local message="${STATS_EMOJI} <b>Estado inicial de nodos Tailscale:</b>"$'\n\n'                                                                                                                                                               
                                                                                                                                                                                                                                                 
    local online_count=0                                                                                                                                                                                                                         
    local total_count=0                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                 
    while IFS='|' read -r hostname status ip last_seen; do
        if [ -n "$hostname" ]; then
            total_count=$((total_count + 1))
            if [ "$status" = "true" ]; then
                online_count=$((online_count + 1))
                message+="${ONLINE_EMOJI} <a href=\"http://${ip}\">${hostname}</a>"$'\n'
            else
                formatted_last_seen=$(echo "$last_seen" | sed -E 's/T/ /; s/\.[0-9]+Z$//')
                message+="${OFFLINE_EMOJI} <a href=\"http://${ip}\">${hostname}</a> (Ultima vez: ${formatted_last_seen})"$'\n'
            fi
        fi
    done <<< "$(echo "$current_state" | sort)"

    message+=$'\n'"<b>${online_count}/${total_count} Nodos Online</b>"                                                                                                                                                                          
                                                                                                                                                                                                                                                 
    send_telegram_message "$message"                                                                                                                                                                                                             
}

compare_states() {
    local current_state="$1"
    local previous_state="$2"
    local notification_msg=""
    
    declare -A current_nodes
    declare -A current_ips
    declare -A previous_nodes
    declare -A excluded_nodes
    
    if [ -f "$EXCLUSIONS_FILE" ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d '\r')
            [ -z "$line" ] || [[ "$line" == \#* ]] && continue
            excluded_nodes["$line"]=1
        done < "$EXCLUSIONS_FILE"
    fi
    
    while IFS='|' read -r hostname status ip last_seen; do
        if [ -n "$hostname" ]; then
            current_nodes[$hostname]="$status"
            current_ips[$hostname]="$ip"
        fi
    done <<< "$current_state"
    
    while IFS='|' read -r hostname status ip last_seen; do
        [ -n "$hostname" ] && previous_nodes[$hostname]="$status"
    done <<< "$previous_state"
    
    for hostname in "${!current_nodes[@]}"; do
        if [ "${excluded_nodes[$hostname]}" = "1" ]; then
            continue
        fi
        
        current_status="${current_nodes[$hostname]}"
        current_ip="${current_ips[$hostname]}"
        previous_status="${previous_nodes[$hostname]:-unknown}"
        
        if [ "$previous_status" != "unknown" ] && [ "$current_status" != "$previous_status" ]; then
            if [ "$current_status" = "true" ]; then
                notification_msg+="${ONLINE_EMOJI} <a href=\"http://${current_ip}\"><b>${hostname}</b></a> esta ahora ONLINE"$'\n'
            else
                notification_msg+="${OFFLINE_EMOJI} <a href=\"http://${current_ip}\"><b>${hostname}</b></a> esta ahora OFFLINE"$'\n'
            fi
        fi
    done
    
    if [ -n "$notification_msg" ]; then
        send_telegram_message "$notification_msg"
    fi
}

# ==========================================
# Bloque de Ejecucion Principal
# ==========================================
main() {
    lock "$LOCK_FILE" || exit 1
    trap "lock -u $LOCK_FILE" EXIT

    local json_data current_state previous_state
    
    json_data=$(check_tailscale_status)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    current_state=$(get_nodes_status "$json_data")
    if [ -z "$current_state" ]; then
        local warn_msg="${WARNING_EMOJI} WARNING: No se encontraron nodos en el output de Tailscale."
        logger -t "tailscale-check" "$warn_msg"
        send_telegram_message "$warn_msg"
        exit 1
    fi
    
    if ! previous_state=$(load_previous_state); then
        send_initial_state "$current_state"
    else
        compare_states "$current_state" "$previous_state"
    fi
    
    save_current_state "$current_state"
}

main

5. Next steps and Instructions for the AI
Please acknowledge this context. We are ready to continue developing or adding features to this script. Ask the user what they want to implement next.