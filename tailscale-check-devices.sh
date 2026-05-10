#!/bin/bash

# ==========================================
# Configuracion y Constantes
# ==========================================
CREDS_FILE="/overlay/tailscale-check-devices_credentials.dat"
EXCLUSIONS_FILE="/overlay/tailscale-check-devices.exclusions"

# Archivos de estado en overlay pero se pueden mover a /tmp/ (RAM) para no quemar la memoria Flash
STATE_FILE="/overlay/tailscale-check_state.json"
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
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
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
    echo "$json_data" | jq -r 'if .Peer == null then empty else .Peer | to_entries[] | select(.value.DNSName != null) | "\(.value.DNSName|split(".")[0])|\(.value.Online)|\(.value.TailscaleIPs[0])|\(.value.LastSeen)" end'
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
    
    # 1. Cargar exclusiones si el archivo existe
    if [ -f "$EXCLUSIONS_FILE" ]; then
        while IFS= read -r line; do
            # Limpiar saltos de carro estilo Windows
            line=$(echo "$line" | tr -d '\r')
            # Ignorar lineas vacias y comentarios que empiecen por #
            [ -z "$line" ] || [[ "$line" == \#* ]] && continue
            excluded_nodes["$line"]=1
        done < "$EXCLUSIONS_FILE"
    fi
    
    # 2. Procesar estado actual
    while IFS='|' read -r hostname status ip last_seen; do
        if [ -n "$hostname" ]; then
            current_nodes[$hostname]="$status"
            current_ips[$hostname]="$ip"
        fi
    done <<< "$current_state"
    
    # 3. Procesar estado previo
    while IFS='|' read -r hostname status ip last_seen; do
        [ -n "$hostname" ] && previous_nodes[$hostname]="$status"
    done <<< "$previous_state"
    
    # 4. Comparar y generar notificaciones (omitiendo excluidos)
    for hostname in "${!current_nodes[@]}"; do
        # Si el nodo esta en la lista de exclusiones, pasamos al siguiente
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
    
    # 5. Enviar un unico mensaje si hay cambios
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