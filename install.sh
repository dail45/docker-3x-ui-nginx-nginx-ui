#!/bin/bash

set -euo pipefail

# ============================================================================
# PATHS & FILES
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/install.log"
NGINX_DIR="$SCRIPT_DIR/nginx"
NGINX_UI_DIR="$SCRIPT_DIR/nginx-ui"
CERTBOT_DIR="$SCRIPT_DIR/certbot"
XRAY_SNI="www.google.com"

DOCKER_CMD="docker"
COMPOSE_CMD="docker compose"

# ============================================================================
# TEMPLATES: FILE & DIRECTORY STRUCTURES
# ============================================================================

tmpl_required_dirs() {
    echo \
        "$SCRIPT_DIR/3x-ui/db" \
        "$SCRIPT_DIR/3x-ui/cert" \
        "$NGINX_DIR/conf.d" \
        "$NGINX_DIR/html" \
        "$NGINX_DIR/sites-available" \
        "$NGINX_DIR/sites-enabled" \
        "$NGINX_UI_DIR" \
        "$CERTBOT_DIR"
}

tmpl_index_html() {
    cat << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Welcome</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; background: linear-gradient(135deg, #0f0f1a 0%, #1a1a2e 50%, #16213e 100%);
      color: #e0e0e0;
    }
    .card {
      text-align: center; padding: 3rem 4rem;
      background: rgba(255,255,255,0.05);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 16px;
      backdrop-filter: blur(10px);
      box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    }
    .icon { font-size: 3rem; margin-bottom: 1rem; }
    h1 { font-size: 1.8rem; font-weight: 600; color: #ffffff; margin-bottom: 0.5rem; }
    p  { color: #888; font-size: 0.95rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">🛡️</div>
    <h1>It works!</h1>
    <p>nginx is running.</p>
  </div>
</body>
</html>
HTMLEOF
}

tmpl_docker_compose() {
    cat << 'DCEOF'
services:
  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/sites-available:/etc/nginx/sites-available:rw
      - ./nginx/sites-enabled:/etc/nginx/sites-enabled:rw
      - ./nginx/html:/usr/share/nginx/html:rw
      - ./nginx/ssl:/etc/nginx/ssl:rw
      - ./certbot:/etc/letsencrypt:ro
      - nginx_logs:/var/log/nginx
    networks:
      - proxy
    depends_on:
      - 3x-ui
      - nginx-ui

  certbot:
    image: certbot/certbot
    container_name: certbot
    restart: unless-stopped
    volumes:
      - ./certbot:/etc/letsencrypt
      - ./nginx/html:/usr/share/nginx/html
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew --webroot -w /usr/share/nginx/html --quiet; sleep 12h & wait $${!}; done;'"
    depends_on:
      - nginx

  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: unless-stopped
    volumes:
      - ./3x-ui/db:/etc/x-ui
      - ./3x-ui/cert:/root/cert
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    networks:
      - proxy

  nginx-ui:
    image: uozi/nginx-ui:latest
    container_name: nginx-ui
    restart: unless-stopped
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:rw
      - ./nginx/conf.d:/etc/nginx/conf.d:rw
      - ./nginx/sites-available:/etc/nginx/sites-available:rw
      - ./nginx/sites-enabled:/etc/nginx/sites-enabled:rw
      - ./nginx-ui:/etc/nginx-ui
      - ./nginx/ssl:/etc/nginx/ssl:rw
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./certbot:/etc/letsencrypt:ro
      - nginx_logs:/var/log/nginx
    networks:
      - proxy

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
ContainerName = nginx
AccessLogPath = /var/log/nginx/access.log

[auth]
TrustProxyHeaders = true
INIEOF
}

# ============================================================================
# COLORS & UI PRIMITIVES
# ============================================================================

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_CYAN="\033[0;36m"
C_WHITE="\033[1;37m"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
ok()      { echo -e "  ${C_GREEN}✔${C_RESET}  $1"; log "OK: $1"; }
fail()    { echo -e "\n${C_RED}  ✖  ${MSG_ERROR}: $1${C_RESET}" >&2; log "ERROR: $1"; exit 1; }
warn()    { echo -e "  ${C_YELLOW}⚠${C_RESET}  $1"; log "WARN: $1"; }
info()    { echo -e "  ${C_CYAN}→${C_RESET}  $1"; }
step()    { echo -e "\n${C_BOLD}${C_WHITE}▶ $1${C_RESET}"; }
skip()    { echo -e "  ${C_DIM}◌  $1${C_RESET}"; }
divider() { echo -e "${C_DIM}  ─────────────────────────────────────────────────${C_RESET}"; }

# ============================================================================
# LANGUAGE SELECTION
# ============================================================================

choose_language() {
    clear
    echo -e ""
    echo -e "  ${C_BOLD}${C_WHITE}╔══════════════════════════════════════════════════╗${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}║   3x-ui + Nginx + Nginx-UI + Certbot Installer  ║${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}╚══════════════════════════════════════════════════╝${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}Select language / Выберите язык:${C_RESET}"
    echo -e ""
    echo -e "    ${C_BOLD}1)${C_RESET}  🇺🇸  English"
    echo -e "    ${C_BOLD}2)${C_RESET}  🇷🇺  Русский"
    echo -e ""
    printf "  ${C_WHITE}Choice / Выбор [1/2]:${C_RESET} "
    read -r lang_choice

    case "${lang_choice:-1}" in
        2)
            MSG_ERROR="ОШИБКА"
            MSG_STEP_CHECKS="Предполётные проверки"
            MSG_STEP_INPUT="Настройка домена"
            MSG_STEP_DIRS="Подготовка директорий и файлов"
            MSG_STEP_CONFIGS="Генерация конфигураций"
            MSG_STEP_CERTS_DUMMY="Временные SSL-сертификаты"
            MSG_STEP_STACK="Запуск стека Docker"
            MSG_STEP_3XUI="Настройка 3x-ui"
            MSG_STEP_CERTS_REAL="Получение сертификатов Let's Encrypt"
            MSG_STEP_DONE="Установка завершена"
            MSG_CHECK_ROOT="Проверка прав root"
            MSG_CHECK_DOCKER="Проверка Docker"
            MSG_CHECK_COMPOSE="Проверка Docker Compose"
            MSG_CHECK_CURL="Проверка curl"
            MSG_CHECK_OPENSSL="Проверка openssl"
            MSG_CHECK_DNS="Проверка DNS для"
            MSG_PROMPT_EMAIL="  Введите email для Let's Encrypt: "
            MSG_PROMPT_DOMAIN="  Введите домен"
            MSG_DIR_EXISTS="Уже существует:"
            MSG_DIR_CREATED="Создана директория:"
            MSG_FILE_EXISTS="Файл уже есть:"
            MSG_FILE_CREATED="Сгенерирован файл:"
            MSG_COMPOSE_SKIP="docker-compose.yml уже существует, пропуск"
            MSG_COMPOSE_CREATED="docker-compose.yml сгенерирован"
            MSG_DNS_OK="DNS указывает на этот сервер"
            MSG_DNS_MISMATCH="DNS-адрес не совпадает с IP сервера"
            MSG_DNS_FAIL="Домен не резолвится — проверьте A-запись"
            MSG_STARTING_STACK="Запуск контейнеров..."
            MSG_WAIT_DB="Ожидание базы данных 3x-ui..."
            MSG_BASEPATH_SET="URI path 3x-ui установлен:"
            MSG_NGINX_RELOAD="Перезапуск Nginx с боевыми сертификатами..."
            MSG_ACCESS="ДОСТУП"
            MSG_HINT_LOG="Логи установки:"
            MSG_SYMLINK_CREATED="Создан симлинк:"
            MSG_ERR_ROOT="Запустите скрипт от имени root (sudo)"
            MSG_ERR_DOCKER_MISSING="Docker не найден. Сначала установите Docker."
            MSG_ERR_DOCKER_DAEMON="Демон Docker не запущен."
            MSG_ERR_COMPOSE_MISSING="Docker Compose не найден."
            MSG_WARN_CURL_INSTALL="curl не найден, устанавливаем..."
            MSG_ERR_CURL_FAIL="Не удалось установить curl"
            MSG_WARN_OPENSSL_INSTALL="openssl не найден, устанавливаем..."
            MSG_ERR_OPENSSL_FAIL="Не удалось установить openssl"
            MSG_INFO_MIME_DL="Скачивание mime.types..."
            MSG_WARN_MIME_FAIL="Не удалось скачать mime.types (в nginx:alpine используется встроенный)"
            MSG_INFO_DUMMY_GEN="Генерация временных сертификатов для"
            MSG_OK_DUMMY_READY="Временные сертификаты готовы"
            MSG_INFO_DUMMY_RM="Удаление временных сертификатов..."
            MSG_INFO_CERT_REQ="Запрос сертификата Let's Encrypt..."
            MSG_ERR_CERT_FAIL="Ошибка выпуска сертификата. Проверьте логи:"
            MSG_OK_CERT_DONE="Сертификат Let's Encrypt получен"
            MSG_ERR_3XUI_TIMEOUT="3x-ui не создал базу данных за 30с. Проверьте:"
            MSG_OK_STACK_RUN="Стек контейнеров запущен"
            MSG_OK_NGINX_RELOAD="Конфигурация Nginx перезагружена"
            ;;
        *)
            MSG_ERROR="ERROR"
            MSG_STEP_CHECKS="Pre-flight checks"
            MSG_STEP_INPUT="Domain configuration"
            MSG_STEP_DIRS="Preparing directories & files"
            MSG_STEP_CONFIGS="Generating configurations"
            MSG_STEP_CERTS_DUMMY="Dummy SSL certificates"
            MSG_STEP_STACK="Starting Docker stack"
            MSG_STEP_3XUI="Configuring 3x-ui"
            MSG_STEP_CERTS_REAL="Obtaining Let\'s Encrypt certificates"
            MSG_STEP_DONE="Installation complete"
            MSG_CHECK_ROOT="Checking root privileges"
            MSG_CHECK_DOCKER="Checking Docker"
            MSG_CHECK_COMPOSE="Checking Docker Compose"
            MSG_CHECK_CURL="Checking curl"
            MSG_CHECK_OPENSSL="Checking openssl"
            MSG_CHECK_DNS="Checking DNS for"
            MSG_PROMPT_EMAIL="  Enter email for Let\'s Encrypt: "
            MSG_PROMPT_DOMAIN="  Enter your domain"
            MSG_DIR_EXISTS="Already exists:"
            MSG_DIR_CREATED="Created directory:"
            MSG_FILE_EXISTS="File already present:"
            MSG_FILE_CREATED="Generated file:"
            MSG_COMPOSE_SKIP="docker-compose.yml already exists, skipping"
            MSG_COMPOSE_CREATED="docker-compose.yml generated"
            MSG_DNS_OK="DNS points to this server"
            MSG_DNS_MISMATCH="DNS address does not match server IP"
            MSG_DNS_FAIL="Domain does not resolve — check your A record"
            MSG_STARTING_STACK="Starting containers..."
            MSG_WAIT_DB="Waiting for 3x-ui database..."
            MSG_BASEPATH_SET="3x-ui URI path set:"
            MSG_NGINX_RELOAD="Reloading Nginx with real certificates..."
            MSG_ACCESS="ACCESS"
            MSG_HINT_LOG="Installation log:"
            MSG_SYMLINK_CREATED="Created symlink:"
            MSG_ERR_ROOT="Run this script as root (sudo)"
            MSG_ERR_DOCKER_MISSING="Docker not found. Please install Docker first."
            MSG_ERR_DOCKER_DAEMON="Docker daemon is not running."
            MSG_ERR_COMPOSE_MISSING="Docker Compose not found."
            MSG_WARN_CURL_INSTALL="curl not found, installing..."
            MSG_ERR_CURL_FAIL="Failed to install curl"
            MSG_WARN_OPENSSL_INSTALL="openssl not found, installing..."
            MSG_ERR_OPENSSL_FAIL="Failed to install openssl"
            MSG_INFO_MIME_DL="Downloading mime.types..."
            MSG_WARN_MIME_FAIL="Could not download mime.types (nginx:alpine ships its own)"
            MSG_INFO_DUMMY_GEN="Generating dummy certificates for"
            MSG_OK_DUMMY_READY="Dummy certificates ready"
            MSG_INFO_DUMMY_RM="Removing dummy certificates..."
            MSG_INFO_CERT_REQ="Requesting Let's Encrypt certificate..."
            MSG_ERR_CERT_FAIL="Certificate issuance failed. Check logs:"
            MSG_OK_CERT_DONE="Let's Encrypt certificate obtained"
            MSG_ERR_3XUI_TIMEOUT="3x-ui did not create the database within 30s. Check:"
            MSG_OK_STACK_RUN="Stack is running"
            MSG_OK_NGINX_RELOAD="Nginx reloaded"
            ;;
    esac
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

check_root() {
    info "$MSG_CHECK_ROOT"
    test "$EUID" -eq 0 || fail "$MSG_ERR_ROOT"
    ok "$MSG_CHECK_ROOT"
}

check_docker() {
    info "$MSG_CHECK_DOCKER"
    command -v "$DOCKER_CMD" &>/dev/null || fail "$MSG_ERR_DOCKER_MISSING"
    "$DOCKER_CMD" info &>/dev/null        || fail "$MSG_ERR_DOCKER_DAEMON"
    ok "$MSG_CHECK_DOCKER"
}

check_docker_compose() {
    info "$MSG_CHECK_COMPOSE"
    if "$DOCKER_CMD" compose version &>/dev/null; then
        COMPOSE_CMD="$DOCKER_CMD compose"
        ok "$MSG_CHECK_COMPOSE (v2+)"
        return 0
    fi
    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        warn "$MSG_CHECK_COMPOSE (v1 legacy)"
        return 0
    fi
    fail "$MSG_ERR_COMPOSE_MISSING"
}

check_curl() {
    info "$MSG_CHECK_CURL"
    if ! command -v curl &>/dev/null; then
        warn "$MSG_WARN_CURL_INSTALL"
        apt-get update -qq && apt-get install -y -qq curl || fail "$MSG_ERR_CURL_FAIL"
    fi
    ok "$MSG_CHECK_CURL"
}

check_openssl() {
    info "$MSG_CHECK_OPENSSL"
    if ! command -v openssl &>/dev/null; then
        warn "$MSG_WARN_OPENSSL_INSTALL"
        apt-get update -qq && apt-get install -y -qq openssl || fail "$MSG_ERR_OPENSSL_FAIL"
    fi
    ok "$MSG_CHECK_OPENSSL"
}

check_dns() {
    local domain="$1"
    info "$MSG_CHECK_DNS $domain"
    local server_ip dns_ip
    server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    dns_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1 || echo "")
    if test -z "$dns_ip"; then
        warn "$MSG_DNS_FAIL: $domain"
    elif test "$dns_ip" != "$server_ip"; then
        warn "$MSG_DNS_MISMATCH: DNS=$dns_ip, server=$server_ip"
    else
        ok "$MSG_DNS_OK ($server_ip)"
    fi
}

# ============================================================================
# DIRECTORY & FILE MANAGEMENT
# ============================================================================

ensure_dirs() {
    for dir in $(tmpl_required_dirs); do
        if test -d "$dir"; then
            skip "$MSG_DIR_EXISTS ${dir#"$SCRIPT_DIR/"}"
        else
            mkdir -p "$dir"
            ok "$MSG_DIR_CREATED ${dir#"$SCRIPT_DIR/"}"
        fi
    done
}

ensure_index_html() {
    local target="$NGINX_DIR/html/index.html"
    if test -f "$target"; then
        skip "$MSG_FILE_EXISTS nginx/html/index.html"
    else
        tmpl_index_html > "$target"
        ok "$MSG_FILE_CREATED nginx/html/index.html"
    fi
}

ensure_docker_compose() {
    local target="$SCRIPT_DIR/docker-compose.yml"
    if test -f "$target"; then
        skip "$MSG_COMPOSE_SKIP"
    else
        tmpl_docker_compose > "$target"
        ok "$MSG_COMPOSE_CREATED"
    fi
}

ensure_nginx_ui_ini() {
    local target="$NGINX_UI_DIR/app.ini"
    if test -f "$target"; then
        skip "$MSG_FILE_EXISTS nginx-ui/app.ini"
    else
        tmpl_nginx_ui_ini > "$target"
        ok "$MSG_FILE_CREATED nginx-ui/app.ini"
    fi
}

# ============================================================================
# CONFIG GENERATORS
# ============================================================================

generate_nginx_conf() {
    local domain="$1"
    local domain_escaped
    domain_escaped=$(echo "$domain" | sed 's/\./\\\\./g')

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
        ${XRAY_SNI}                    xray_backend;
        ${domain}                      web_backend;
        ~^.*\\.${domain_escaped}\$     web_backend;
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
    ok "$MSG_FILE_CREATED nginx/nginx.conf"
}

generate_vhost_conf() {
    local domain="$1"

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
    ok "$MSG_FILE_CREATED nginx/conf.d/default.conf"

    cat > "$NGINX_DIR/sites-available/${domain}.conf" << EOF
server {
    listen 7443 ssl;
    server_name ${domain};

    port_in_redirect off;

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=63072000" always;

    location /3x-ui-panel/ {
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

    location /nginx-ui/ {
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
    ok "$MSG_FILE_CREATED nginx/sites-available/${domain}.conf"

    ln -sf "../sites-available/${domain}.conf" "$NGINX_DIR/sites-enabled/${domain}.conf"
    ok "$MSG_SYMLINK_CREATED nginx/sites-enabled/${domain}.conf"
}

generate_configs() {
    local domain="$1"
    generate_nginx_conf  "$domain"
    generate_vhost_conf  "$domain"
    ensure_nginx_ui_ini

    if ! test -f "$NGINX_DIR/mime.types"; then
        info "Downloading mime.types..."
        curl -sL https://raw.githubusercontent.com/nginx/nginx/master/conf/mime.types \
            -o "$NGINX_DIR/mime.types" 2>/dev/null \
            && ok "$MSG_FILE_CREATED nginx/mime.types" \
            || warn "Could not download mime.types (nginx:alpine ships its own)"
    else
        skip "$MSG_FILE_EXISTS nginx/mime.types"
    fi
}

# ============================================================================
# SSL CERTIFICATES
# ============================================================================

setup_dummy_certs() {
    local domain="$1"
    info "$MSG_INFO_DUMMY_GEN $domain..."

    mkdir -p "$CERTBOT_DIR/live/$domain"

    openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
        -keyout "$CERTBOT_DIR/live/$domain/privkey.pem" \
        -out    "$CERTBOT_DIR/live/$domain/fullchain.pem" \
        -subj   "/CN=$domain" 2>/dev/null

    if ! test -f "$CERTBOT_DIR/options-ssl-nginx.conf"; then
        curl -sL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
            -o "$CERTBOT_DIR/options-ssl-nginx.conf"
        curl -sL https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem \
            -o "$CERTBOT_DIR/ssl-dhparams.pem"
    fi

    ok "$MSG_OK_DUMMY_READY"
}

get_real_certs() {
    local domain="$1"
    local email="$2"

    info "$MSG_INFO_DUMMY_RM"
    rm -rf "$CERTBOT_DIR/live/$domain"
    rm -rf "$CERTBOT_DIR/archive/$domain"
    rm -f  "$CERTBOT_DIR/renewal/$domain.conf"

    info "$MSG_INFO_CERT_REQ"
    $COMPOSE_CMD run --rm --no-deps --entrypoint certbot certbot certonly \
        --webroot -w /usr/share/nginx/html \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --force-renewal \
        -d "$domain" || fail "Certificate issuance failed. Check logs: $COMPOSE_CMD logs nginx"

    ok "$MSG_OK_CERT_DONE"
}

# ============================================================================
# 3X-UI CONFIGURATION
# ============================================================================

configure_3xui_basepath() {
    local basepath="/3x-ui-panel/"
    info "$MSG_WAIT_DB"

    local retries=0
    until docker exec 3x-ui test -f /etc/x-ui/x-ui.db 2>/dev/null; do
        retries=$((retries + 1))
        test "$retries" -ge 15 && fail "$MSG_ERR_3XUI_TIMEOUT $COMPOSE_CMD logs 3x-ui"printf "."
        sleep 2
    done
    echo ""

    docker exec 3x-ui python3 -c \
        "import sqlite3; conn = sqlite3.connect('/etc/x-ui/x-ui.db'); cur = conn.cursor(); cur.execute(\"INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '${basepath}');\"); conn.commit(); conn.close()"

    $COMPOSE_CMD restart 3x-ui
    sleep 3

    ok "$MSG_BASEPATH_SET ${basepath}"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    choose_language
    clear

    echo -e ""
    echo -e "  ${C_BOLD}${C_WHITE}╔══════════════════════════════════════════════════╗${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}║   3x-ui + Nginx + Nginx-UI + Certbot Installer  ║${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}╚══════════════════════════════════════════════════╝${C_RESET}"
    echo -e ""

    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"

    step "$MSG_STEP_CHECKS"
    divider
    check_root
    check_docker
    check_docker_compose
    check_curl
    check_openssl

    step "$MSG_STEP_INPUT"
    divider
    local hostname
    hostname=$(hostname)
    echo ""
    printf "$MSG_PROMPT_EMAIL"
    read -r email
    printf "$MSG_PROMPT_DOMAIN (default: $hostname): "
    read -r user_domain
    local domain="${user_domain:-$hostname}"
    echo ""
    check_dns "$domain"

    step "$MSG_STEP_DIRS"
    divider
    ensure_dirs
    ensure_index_html
    ensure_docker_compose

    step "$MSG_STEP_CONFIGS"
    divider
    generate_configs "$domain"

    step "$MSG_STEP_CERTS_DUMMY"
    divider
    setup_dummy_certs "$domain"

    step "$MSG_STEP_STACK"
    divider
    info "$MSG_STARTING_STACK"
    $COMPOSE_CMD up -d --build
    sleep 5
    ok "$MSG_OK_STACK_RUN"

    step "$MSG_STEP_3XUI"
    divider
    configure_3xui_basepath

    step "$MSG_STEP_CERTS_REAL"
    divider
    get_real_certs "$domain" "$email"
    info "$MSG_NGINX_RELOAD"
    $COMPOSE_CMD restart nginx
    ok "$MSG_OK_NGINX_RELOAD"

    echo -e ""
    echo -e "  ${C_GREEN}${C_BOLD}╔══════════════════════════════════════════════════╗${C_RESET}"
    echo -e "  ${C_GREEN}${C_BOLD}║          ✔  ${MSG_STEP_DONE}                  ║${C_RESET}"
    echo -e "  ${C_GREEN}${C_BOLD}╚══════════════════════════════════════════════════╝${C_RESET}"
    echo -e ""
    echo -e "  ${C_BOLD}${C_WHITE}🌐 $MSG_ACCESS${C_RESET}"
    echo -e ""
    echo -e "    ${C_CYAN}3x-ui panel  →${C_RESET}  https://${domain}/3x-ui-panel/"
    echo -e "    ${C_CYAN}Nginx-UI     →${C_RESET}  https://${domain}/nginx-ui/"
    echo -e ""
    divider
    echo -e "  ${C_DIM}📄 $MSG_HINT_LOG ${LOG_FILE}${C_RESET}"
    echo -e ""
}

main "$@"
