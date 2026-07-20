#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
LOG_FILE="$SCRIPT_DIR/install.log"
NGINX_DIR="$SCRIPT_DIR/nginx"
NGINX_UI_DIR="$SCRIPT_DIR/nginx-ui"

DOCKER_CMD="docker"
COMPOSE_CMD="docker compose"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (sudo)"
    exit 1
fi

# Check dialog
if ! command -v dialog &> /dev/null; then
    echo "dialog utility is not installed. Install it now? [Y/n]"
    read -r ans
    if [[ "$ans" != "n" && "$ans" != "N" ]]; then
        echo "Installing dialog..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq dialog || { echo "Failed to install dialog"; exit 1; }
        elif command -v dnf &>/dev/null; then
            dnf install -y -q dialog || { echo "Failed to install dialog"; exit 1; }
        elif command -v yum &>/dev/null; then
            yum install -y -q dialog || { echo "Failed to install dialog"; exit 1; }
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm dialog || { echo "Failed to install dialog"; exit 1; }
        elif command -v apk &>/dev/null; then
            apk add --no-cache dialog || { echo "Failed to install dialog"; exit 1; }
        else
            echo "Unsupported package manager. Please install 'dialog' manually."
            exit 1
        fi
    else
        echo "Aborted."
        exit 1
    fi
fi

> "$LOG_FILE"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
run_logged() { "$@" >> "$LOG_FILE" 2>&1; }

# --- TEMPLATES ---
tmpl_required_dirs() {
    echo \
        "$SCRIPT_DIR/3x-ui/db" \
        "$SCRIPT_DIR/3x-ui/cert" \
        "$NGINX_DIR/conf.d" \
        "$NGINX_DIR/html" \
        "$NGINX_DIR/sites-available" \
        "$NGINX_DIR/sites-enabled" \
        "$NGINX_DIR/streams-available" \
        "$NGINX_DIR/streams-enabled" \
        "$NGINX_UI_DIR" \
        "$NGINX_DIR/ssl"
}

tmpl_index_html() {
    cat << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Welcome</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; background: #16213e; color: #e0e0e0; }
    .card { text-align: center; padding: 3rem; background: rgba(255,255,255,0.05); border-radius: 16px; }
  </style>
</head>
<body>
  <div class="card"><h1>It works!</h1><p>nginx is running.</p></div>
</body>
</html>
HTMLEOF
}

tmpl_docker_compose() {
    cat << 'DCEOF'
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: unless-stopped
    ports:
      - "443:443/udp"
    volumes:
      - ./3x-ui/db:/etc/x-ui
      - ./3x-ui/cert:/root/cert
      - ./nginx/ssl:/etc/nginx/ssl:ro
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    networks:
      - proxy

  nginx-ui:
    image: uozi/nginx-ui:latest
    container_name: nginx-ui
    restart: unless-stopped
    environment:
      - NGINX_UI_IGNORE_DOCKER_SOCKET=true
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:rw
      - ./nginx/conf.d:/etc/nginx/conf.d:rw
      - ./nginx/sites-available:/etc/nginx/sites-available:rw
      - ./nginx/sites-enabled:/etc/nginx/sites-enabled:rw
      - ./nginx/streams-available:/etc/nginx/streams-available:rw
      - ./nginx/streams-enabled:/etc/nginx/streams-enabled:rw
      - ./nginx/html:/usr/share/nginx/html:rw
      - ./nginx-ui:/etc/nginx-ui
      - ./nginx/ssl:/etc/nginx/ssl:rw
      - nginx_logs:/var/log/nginx
    networks:
      - proxy
    depends_on:
      - 3x-ui

networks:
  proxy:
    driver: bridge

volumes:
  nginx_logs:
DCEOF
}

tmpl_nginx_ui_ini() {
    cat << 'INIEOF'
[server]
HttpPort = 9000
RunMode = release

[nginx]
AccessLogPath = /var/log/nginx/access.log

[auth]
TrustProxyHeaders = true
INIEOF
}

# --- LOGIC FUNCTIONS ---
ensure_dirs() {
    log "Creating required directories..."
    for dir in $(tmpl_required_dirs); do
        mkdir -p "$dir"
    done
    log "Generating default configuration files..."
    [ ! -f "$NGINX_DIR/html/index.html" ] && tmpl_index_html > "$NGINX_DIR/html/index.html"
    [ ! -f "$SCRIPT_DIR/docker-compose.yml" ] && tmpl_docker_compose > "$SCRIPT_DIR/docker-compose.yml"
    [ ! -f "$NGINX_UI_DIR/app.ini" ] && tmpl_nginx_ui_ini > "$NGINX_UI_DIR/app.ini"
}

generate_nginx_conf() {
    local domain="$1"
    local add_domains="$2"
    local xray_domains="$3"

    log "Generating nginx.conf for stream routing..."
    local map_block=""

    # XRAY domains (exact and wildcards to take precedence in regexes)
    for xd in $xray_domains; do
        local xd_esc
        xd_esc=$(echo "$xd" | sed 's/\./\\\\./g')
        map_block="${map_block}
        ${xd}                      xray_backend;
        ~^.*\\.${xd_esc}\$           xray_backend;"
    done

    # Main domain and its subdomains
    local domain_escaped
    domain_escaped=$(echo "$domain" | sed 's/\./\\\\./g')
    map_block="${map_block}
        ${domain}                      web_backend;
        ~^.*\\.${domain_escaped}\$     web_backend;"
        
    # Additional NGINX domains
    for ad in $add_domains; do
        local ad_esc
        ad_esc=$(echo "$ad" | sed 's/\./\\\\./g')
        map_block="${map_block}
        ${ad}                      web_backend;
        ~^.*\\.${ad_esc}\$           web_backend;"
    done

    cat > "$NGINX_DIR/nginx.conf" << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

stream {
    log_format stream_log '\$remote_addr [\$time_local] \$protocol '
                          '\$status \$bytes_sent \$bytes_received '
                          '"\$ssl_preread_server_name"';
    access_log /var/log/nginx/stream.log stream_log;

    map \$ssl_preread_server_name \$upstream_backend {
${map_block}
        default                        xray_backend;
    }

    upstream xray_backend { server 3x-ui:443; }
    upstream web_backend  { server 127.0.0.1:7443; }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$upstream_backend;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;
        proxy_buffer_size 16k;
    }

    include /etc/nginx/streams-enabled/*;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    include /etc/nginx/sites-enabled/*;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 75;
    server_tokens   off;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml text/javascript;

    include /etc/nginx/conf.d/*.conf;
}
EOF
}

generate_vhost_conf() {
    local domain="$1"
    local ui3x_path="$2"
    local nginxui_path="$3"

    if [[ "$ui3x_path" != */ ]]; then ui3x_path="${ui3x_path}/"; fi
    if [[ "$ui3x_path" != /* ]]; then ui3x_path="/${ui3x_path}"; fi
    if [[ "$nginxui_path" != */ ]]; then nginxui_path="${nginxui_path}/"; fi
    if [[ "$nginxui_path" != /* ]]; then nginxui_path="/${nginxui_path}"; fi

    log "Generating vhost conf for domain: $domain"
    cat > "$NGINX_DIR/conf.d/default.conf" << EOF
server {
    listen 80;

    location /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
		try_files \$uri @acme_proxy;
    }

	location @acme_proxy {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_pass http://nginx-ui:9180;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    cat > "$NGINX_DIR/sites-available/${domain}" << EOF
server {
    listen 7443 ssl;
    server_name ${domain};

    port_in_redirect off;

    ssl_certificate     /etc/nginx/ssl/${domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=63072000" always;

    location ${ui3x_path} {
        proxy_pass         http://3x-ui:2053;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$connection_upgrade;
        proxy_read_timeout 86400;
    }

    location ${ui3x_path}sub/ {
        proxy_pass         http://3x-ui:2096;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$connection_upgrade;
        proxy_read_timeout 86400;
    }

    location ${nginxui_path} {
        proxy_pass         http://nginx-ui:9000/;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$connection_upgrade;
        proxy_read_timeout 3600;
    }

    location / {
        root  /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF
    ln -sf "../sites-available/${domain}" "$NGINX_DIR/sites-enabled/${domain}"
}

setup_dummy_certs() {
    local domain="$1"
    log "Setting up temporary (dummy) SSL certificates..."
    mkdir -p "$NGINX_DIR/ssl/$domain"
    run_logged openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
        -keyout "$NGINX_DIR/ssl/$domain/privkey.pem" \
        -out    "$NGINX_DIR/ssl/$domain/fullchain.pem" \
        -subj   "/CN=$domain"
}

get_real_certs() {
    local domain="$1"
    local email="$2"
    log "Removing temporary SSL certificates..."
    rm -f "$NGINX_DIR/ssl/$domain/fullchain.pem"
    rm -f "$NGINX_DIR/ssl/$domain/privkey.pem"

    log "Requesting Let's Encrypt certificates via certbot..."
    run_logged docker run --rm --name temp_certbot \
        -v "$NGINX_DIR/html:/usr/share/nginx/html" \
        -v "$SCRIPT_DIR/certbot_temp:/etc/letsencrypt" \
        certbot/certbot certonly \
        --webroot -w /usr/share/nginx/html \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        -d "$domain"

    if [ -f "$SCRIPT_DIR/certbot_temp/live/$domain/fullchain.pem" ]; then
        cp -L "$SCRIPT_DIR/certbot_temp/live/$domain/fullchain.pem" "$NGINX_DIR/ssl/$domain/fullchain.pem"
        cp -L "$SCRIPT_DIR/certbot_temp/live/$domain/privkey.pem" "$NGINX_DIR/ssl/$domain/privkey.pem"
        log "Let's Encrypt certificates successfully installed."
    fi
    rm -rf "$SCRIPT_DIR/certbot_temp"
}

configure_3xui_basepath() {
    local domain="$1"
    local basepath="$2"

    if [[ "$basepath" != */ ]]; then basepath="${basepath}/"; fi
    if [[ "$basepath" != /* ]]; then basepath="/${basepath}"; fi

    local sub_port="2096"
    local sub_uri="${basepath}sub/"
    local sub_json_uri="https://${domain}${sub_uri}"

    log "Waiting for 3x-ui database to initialize..."
    local retries=0
    until docker exec 3x-ui test -f /etc/x-ui/x-ui.db 2>/dev/null; do
        retries=$((retries + 1))
        if [ "$retries" -ge 30 ]; then
            log "ERROR: 3x-ui database was not created in time. Check docker logs 3x-ui."
            return 1
        fi
        sleep 2
    done

    log "Configuring 3x-ui settings via python script..."
    docker exec -i 3x-ui python3 <<EOF
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
cur = conn.cursor()
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '${basepath}')")
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('subPort', '${sub_port}')")
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('subPath', '${sub_uri}')")
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('subURI', '${sub_json_uri}')")
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('subJsonURI', '${sub_json_uri}')")
conn.commit()
conn.close()
EOF
    log "Restarting 3x-ui to apply configuration..."
    run_logged $COMPOSE_CMD restart 3x-ui
}

# --- UI LOGIC ---
LANG_SEL=1
DOMAIN=""
DO_LETS_ENCRYPT=0
EMAIL=""
ADDITIONAL_DOMAINS=""
XRAY_DOMAINS=""
UI3X_PATH="/3x-ui-panel/"
NGINXUI_PATH="/nginx-ui/"

set_lang() {
    if [ "$LANG_SEL" = "2" ]; then
        T_TITLE="Установщик 3x-ui + Nginx-UI"
        T_WELCOME_TXT="Добро пожаловать в установщик 3x-ui и Nginx-UI.\n\nЭтот скрипт установит и настроит Docker-контейнеры, Nginx и SSL-сертификаты.\nВся установка логируется в $LOG_FILE"
        T_DOMAIN_TXT="Введите доменное имя вашего сервера (например, example.com):"
        T_CERT_TXT="Хотите ли вы автоматически получить настоящий SSL-сертификат от Let's Encrypt? (Рекомендуется)"
        T_EMAIL_TXT="Введите ваш Email для регистрации в Let's Encrypt\n(необходимо для уведомлений об истечении):"
        T_SNI_TXT="Ваш основной домен ($DOMAIN) и все его поддомены будут маршрутизироваться через Nginx.\n\nВведите другие домены (через пробел), которые также должны попадать в Nginx.\n(Оставьте пустым, если не требуется)"
        T_XRAY_TXT="Введите домены (через пробел), которые ДОЛЖНЫ попадать в XRAY в обход Nginx.\nНапример, конкретный поддомен (xray.$DOMAIN).\n(Оставьте пустым, если не требуется)"
        T_UI3X_TXT="Введите путь для панели 3x-ui:"
        T_NGINXUI_TXT="Введите путь для панели Nginx-UI:"
        T_BACK="Назад"
        T_NEXT="Далее"
        T_CONT="Продолжить?"
        
        T_STEP_DIRS="Создание директорий и файлов..."
        T_STEP_NGINX="Генерация конфигураций Nginx..."
        T_STEP_MIME="Скачивание mime.types..."
        T_STEP_DUMMY_CERT="Настройка временных сертификатов..."
        T_STEP_DOCKER="Сборка и запуск Docker контейнеров..."
        T_STEP_3XUI="Настройка 3x-ui панели..."
        T_STEP_LETS="Получение сертификатов Let's Encrypt..."
        T_STEP_RESTART="Перезапуск Nginx-UI..."
        T_STEP_DONE="Завершение..."
        
        local email_info=""
        if [ "$DO_LETS_ENCRYPT" = "Yes" ]; then
            email_info="\nEmail: $EMAIL"
        fi
        T_CONFIRM_TXT="Проверьте ваши настройки:\n\nДомен: $DOMAIN\nLet's Encrypt: $DO_LETS_ENCRYPT$email_info\nДоп. домены Nginx: ${ADDITIONAL_DOMAINS:-нет}\nДомены XRAY: ${XRAY_DOMAINS:-нет}\nПуть 3x-ui: $UI3X_PATH\nПуть Nginx-UI: $NGINXUI_PATH\n\nНачать установку?"
        T_INSTALLING="Идет установка, пожалуйста, подождите..."
        T_DONE="Установка успешно завершена!\n\nПанель 3x-ui: https://$DOMAIN$UI3X_PATH\nПанель Nginx-UI: https://$DOMAIN$NGINXUI_PATH\n\nСекрет Nginx-UI: %s\n\nЛоги: $LOG_FILE"
        T_ERR_DOCKER="Docker не установлен! Установите Docker и перезапустите скрипт."
    else
        T_TITLE="3x-ui + Nginx-UI Installer"
        T_WELCOME_TXT="Welcome to the 3x-ui and Nginx-UI installer.\n\nThis script will set up Docker containers, Nginx, and SSL certificates.\nAll actions are logged to $LOG_FILE"
        T_DOMAIN_TXT="Enter your server's domain name (e.g., example.com):"
        T_CERT_TXT="Do you want to automatically obtain a real Let's Encrypt SSL certificate? (Recommended)"
        T_EMAIL_TXT="Enter your Email for Let's Encrypt registration\n(required for expiration notices):"
        T_SNI_TXT="Your main domain ($DOMAIN) and its subdomains will route to Nginx.\n\nEnter other domains (space-separated) that should also route to Nginx.\n(Leave empty if none)"
        T_XRAY_TXT="Enter domains (space-separated) that MUST route to XRAY, bypassing Nginx.\nFor example, a specific subdomain (xray.$DOMAIN).\n(Leave empty if none)"
        T_UI3X_TXT="Enter the path for the 3x-ui panel:"
        T_NGINXUI_TXT="Enter the path for the Nginx-UI panel:"
        T_BACK="Back"
        T_NEXT="Next"
        T_CONT="Continue?"
        
        T_STEP_DIRS="Creating directories and files..."
        T_STEP_NGINX="Generating Nginx configurations..."
        T_STEP_MIME="Downloading mime.types..."
        T_STEP_DUMMY_CERT="Setting up temporary certificates..."
        T_STEP_DOCKER="Building and starting Docker containers..."
        T_STEP_3XUI="Configuring 3x-ui panel..."
        T_STEP_LETS="Obtaining Let's Encrypt certificates..."
        T_STEP_RESTART="Restarting Nginx-UI..."
        T_STEP_DONE="Finishing up..."
        
        local email_info=""
        if [ "$DO_LETS_ENCRYPT" = "Yes" ]; then
            email_info="\nEmail: $EMAIL"
        fi
        T_CONFIRM_TXT="Please review your settings:\n\nDomain: $DOMAIN\nLet's Encrypt: $DO_LETS_ENCRYPT$email_info\nAdd. Nginx domains: ${ADDITIONAL_DOMAINS:-none}\nXRAY domains: ${XRAY_DOMAINS:-none}\n3x-ui Path: $UI3X_PATH\nNginx-UI Path: $NGINXUI_PATH\n\nStart installation?"
        T_INSTALLING="Installing, please wait..."
        T_DONE="Installation completed successfully!\n\n3x-ui panel: https://$DOMAIN$UI3X_PATH\nNginx-UI panel: https://$DOMAIN$NGINXUI_PATH\n\nNginx-UI Secret: %s\n\nLogs: $LOG_FILE"
        T_ERR_DOCKER="Docker is not installed! Please install Docker and restart the script."
    fi
}

exec 3>&1

STEP=1
while [ $STEP -le 10 ]; do
    case $STEP in
        1)
            resp=0
            LANG_SEL=$(dialog --clear --title "Language Selection / Выбор языка" \
                --menu "Choose your language:" 10 40 2 \
                "1" "English" \
                "2" "Русский" \
                2>&1 1>&3) || resp=$?
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            set_lang
            STEP=2
            ;;
        2)
            resp=0
            dialog --clear --title "$T_TITLE" \
                --yes-label "$T_NEXT" --no-label "$T_BACK" \
                --yesno "$T_WELCOME_TXT\n\n$T_CONT" 12 60 || resp=$?
            if [ $resp -eq 1 ]; then STEP=1; continue; fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=3
            ;;
        3)
            resp=0
            DOMAIN=$(dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --inputbox "$T_DOMAIN_TXT" 10 60 "${DOMAIN:-$(hostname)}" \
                2>&1 1>&3) || resp=$?
            if [ $resp -eq 3 ]; then STEP=2; continue; fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=4
            ;;
        4)
            resp=0
            dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --yesno "$T_CERT_TXT" 8 60 || resp=$?
            if [ $resp -eq 3 ]; then STEP=3; continue; fi
            if [ $resp -eq 255 ]; then clear; exit 0; fi
            if [ $resp -eq 0 ]; then
                DO_LETS_ENCRYPT="Yes"
                STEP=5
            else
                DO_LETS_ENCRYPT="No"
                STEP=6
            fi
            ;;
        5)
            resp=0
            EMAIL=$(dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --inputbox "$T_EMAIL_TXT" 10 60 "$EMAIL" \
                2>&1 1>&3) || resp=$?
            if [ $resp -eq 3 ]; then STEP=4; continue; fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=6
            ;;
        6)
            set_lang # Refresh strings with chosen DOMAIN
            resp=0
            ADDITIONAL_DOMAINS=$(dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --inputbox "$T_SNI_TXT" 14 60 "$ADDITIONAL_DOMAINS" \
                2>&1 1>&3) || resp=$?
            if [ $resp -eq 3 ]; then
                if [ "$DO_LETS_ENCRYPT" = "Yes" ]; then STEP=5; else STEP=4; fi
                continue
            fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=7
            ;;
        7)
            resp=0
            XRAY_DOMAINS=$(dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --inputbox "$T_XRAY_TXT" 14 60 "$XRAY_DOMAINS" \
                2>&1 1>&3) || resp=$?
            if [ $resp -eq 3 ]; then STEP=6; continue; fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=8
            ;;
        8)
            resp=0
            UI3X_PATH=$(dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --inputbox "$T_UI3X_TXT" 10 60 "${UI3X_PATH}" \
                2>&1 1>&3) || resp=$?
            if [ $resp -eq 3 ]; then STEP=7; continue; fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=9
            ;;
        9)
            resp=0
            NGINXUI_PATH=$(dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --inputbox "$T_NGINXUI_TXT" 10 60 "${NGINXUI_PATH}" \
                2>&1 1>&3) || resp=$?
            if [ $resp -eq 3 ]; then STEP=8; continue; fi
            if [ $resp -ne 0 ]; then clear; exit 0; fi
            STEP=10
            ;;
        10)
            set_lang # Refresh T_CONFIRM_TXT
            resp=0
            dialog --clear --title "$T_TITLE" \
                --extra-button --extra-label "$T_BACK" \
                --yesno "$T_CONFIRM_TXT" 16 60 || resp=$?
            if [ $resp -eq 3 ]; then STEP=9; continue; fi
            if [ $resp -eq 255 ]; then clear; exit 0; fi
            if [ $resp -eq 0 ]; then
                STEP=11
            else
                clear; exit 0
            fi
            ;;
    esac
done

# Check Docker before proceeding
if ! command -v "$DOCKER_CMD" &>/dev/null; then
    dialog --clear --title "$T_TITLE" --msgbox "$T_ERR_DOCKER" 8 60
    clear
    exit 1
fi
if "$DOCKER_CMD" compose version &>/dev/null; then
    COMPOSE_CMD="$DOCKER_CMD compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    dialog --clear --title "$T_TITLE" --msgbox "$T_ERR_DOCKER" 8 60
    clear
    exit 1
fi

# Helper for gauge
step() {
    local pct="$1"
    local msg="$2"
    echo "XXX" >&4
    echo "$pct" >&4
    echo "$msg" >&4
    echo "XXX" >&4
}

# Screen 8 (Installation phase):
(
exec 4>&1
exec 1>>"$LOG_FILE"
exec 2>>"$LOG_FILE"

step 10 "$T_STEP_DIRS"
log "Starting installation process..."
ensure_dirs

step 20 "$T_STEP_NGINX"
log "Generating Nginx configurations..."
generate_nginx_conf "$DOMAIN" "$ADDITIONAL_DOMAINS" "$XRAY_DOMAINS"
generate_vhost_conf "$DOMAIN" "$UI3X_PATH" "$NGINXUI_PATH"

step 30 "$T_STEP_MIME"
log "Downloading mime.types..."
[ ! -f "$NGINX_DIR/mime.types" ] && run_logged curl -sL https://raw.githubusercontent.com/nginx/nginx/master/conf/mime.types -o "$NGINX_DIR/mime.types"

step 40 "$T_STEP_DUMMY_CERT"
setup_dummy_certs "$DOMAIN"

step 60 "$T_STEP_DOCKER"
log "Starting Docker compose stack..."
run_logged $COMPOSE_CMD up -d --build

step 80 "$T_STEP_3XUI"
configure_3xui_basepath "$DOMAIN" "$UI3X_PATH"

if [ "$DO_LETS_ENCRYPT" = "Yes" ]; then
    step 90 "$T_STEP_LETS"
    log "Let's Encrypt option selected. Getting certificates..."
    get_real_certs "$DOMAIN" "$EMAIL"
    
    step 95 "$T_STEP_RESTART"
    log "Restarting Nginx-UI to apply real certificates..."
    run_logged $COMPOSE_CMD restart nginx-ui
fi
step 100 "$T_STEP_DONE"
log "Installation process finished successfully."
) | dialog --title "$T_TITLE" --gauge "$T_INSTALLING" 10 70 0

# Get secret
SECRET=$(docker exec nginx-ui cat /etc/nginx-ui/.install_secret 2>/dev/null || echo "Not found")

# Screen 9: Done
FINAL_MSG=$(printf "$T_DONE" "$SECRET")

# Write to log
echo -e "\n=== ИТОГ УСТАНОВКИ / INSTALLATION RESULT ===" >> "$LOG_FILE"
echo -e "$FINAL_MSG" >> "$LOG_FILE"

dialog --clear --title "$T_TITLE" --msgbox "$FINAL_MSG" 16 70

clear
echo -e "$FINAL_MSG\n"
