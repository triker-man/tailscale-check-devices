# 🚀 Tailscale Node Monitor para OpenWRT

Un script robusto en Bash diseñado específicamente para routers **OpenWRT**. Monitoriza el estado de los dispositivos (nodos) en tu red de Tailscale y envía notificaciones agrupadas a través de Telegram cuando un equipo se conecta (ONLINE) o se desconecta (OFFLINE).

## ✨ Características Principales

- **Optimizado para OpenWRT:** Utiliza `/tmp/` (memoria RAM) para guardar los archivos de estado temporales, evitando el desgaste (burn-out) de la memoria Flash del router por escrituras constantes.
- **Anti-Spam en Telegram:** Si varios dispositivos cambian de estado al mismo tiempo (ej. caída de un switch o reinicio del router), agrupa todas las alertas en un único mensaje.
- **Lista de Exclusiones:** Permite ignorar dispositivos específicos (como teléfonos móviles o portátiles) que cambian de red constantemente, evitando falsas alarmas.
- **Tolerancia a fallos:** Incluye reintentos (`retries`) si Tailscale tarda en responder y registra los errores críticos en el log del sistema (`syslog`) nativo de OpenWRT.
- **Control de Concurrencia:** Utiliza el comando nativo `lock` para garantizar que nunca haya dos instancias del script ejecutándose simultáneamente.

## 📋 Requisitos Previos

Asegúrate de tener instalados los siguientes paquetes en tu router OpenWRT:
- `tailscale` (y configurado/autenticado)
- `curl` (para interactuar con la API de Telegram)
- `jq` (para procesar el output JSON de Tailscale)

Puedes instalarlos ejecutando:
```bash
opkg update
opkg install curl jq

🛠️ Instalación y Configuración
1. Descargar el script
Copia el archivo tailscale-check-devices.sh en la ruta /overlay/ de tu router (o la ruta que prefieras) y dale permisos de ejecución:

Bash
chmod +x /overlay/tailscale-check-devices.sh
2. Configurar credenciales de Telegram
Crea el archivo /overlay/telegram-credentials.dat con tu Token de Bot y tu Chat ID:

Bash
# /overlay/telegram-credentials.dat
TELEGRAM_BOT_TOKEN="TU_TOKEN_DEL_BOT"
TELEGRAM_CHAT_ID="TU_CHAT_ID"
3. Configurar exclusiones (Opcional)
Si quieres que el script ignore las desconexiones de ciertos dispositivos (como tu móvil), crea el archivo /overlay/tailscale-check-devices.exclusions y añade el Hostname de cada dispositivo, uno por línea. Puedes usar # para comentarios.

Plaintext
# /overlay/tailscale-check-devices.exclusions

# Dispositivos moviles
iphone-maria
samsung-galaxy
laptop-trabajo
⏱️ Automatización con Cron
Para que el script monitorice la red continuamente, añádelo a tu crontab. Recomendamos ejecutarlo cada minuto.

Abre el editor de cron en OpenWRT:

Bash
crontab -e
Añade la siguiente línea:

Fragmento de código
* * * * * /overlay/tailscale-check-devices.sh
Reinicia el servicio cron para aplicar los cambios:

Bash
/etc/init.d/cron restart
🔍 Solución de Problemas (Troubleshooting)
No recibo mensajes: Verifica que el Chat ID y el Token de Telegram sean correctos. Ejecuta el script manualmente: ./tailscale-check-devices.sh.

Quiero forzar un mensaje de estado global: Borra el archivo de estado temporal en la RAM y vuelve a ejecutar el script. Esto simulará un "primer arranque" y te enviará un resumen de todos los nodos.

Bash
rm /tmp/tailscale-check_state.json
/overlay/tailscale-check-devices.sh

- **Revisar errores en background:** Si el script se ejecuta por cron y algo falla, busca los errores en el log del sistema:
  ```bash
  logread | grep tailscale-check
  
📄 Licencia
Este proyecto se distribuye bajo la licencia MIT. Eres libre de utilizarlo, modificarlo y distribuirlo.