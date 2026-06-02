#!/bin/bash
# This script installs Slurp'it (Network Inventory Discovery) via Docker
# and configures Nginx as a reverse proxy at slurpit.tcioe.edu.np
set -euo pipefail

DOMAIN="slurpit.tcioe.edu.np"
INSTALL_DIR="/opt/slurpit"
NGINX_SITE_CONF="/etc/nginx/sites-available/slurpit"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/slurpit"
SLURPIT_HTTP_PORT=8080

# ── Helper ───────────────────────────────────────────────────────────
run_cmd() {
  local msg="$1"; shift
  echo "${msg} ($*)..."
  "$@" || { echo "ERROR: Command failed: $*"; exit 1; }
}

# ── Prerequisites check ─────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)."
  exit 1
fi

echo "============================================="
echo " Slurp'it Installer"
echo " Domain: ${DOMAIN}"
echo "============================================="
echo ""

# ── Install Docker ───────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  run_cmd "Installing Docker Engine" \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  echo "Docker is already installed."
fi

systemctl enable --now docker

# ── Install Docker Compose (standalone, if plugin not available) ─────
if ! docker compose version &>/dev/null; then
  echo "Installing Docker Compose standalone..."
  COMPOSE_VERSION=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# ── Set up Slurp'it directory ────────────────────────────────────────
echo "Setting up Slurp'it in ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# ── Docker Compose file ─────────────────────────────────────────────
cat > docker-compose.yml <<'EOF'
services:
  slurpit-portal:
    image: slurpit/portal:latest
    container_name: slurpit-portal
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"
    volumes:
      - portal-data:/app/data
    depends_on:
      - slurpit-warehouse
    environment:
      - TZ=Asia/Kathmandu
    networks:
      - slurpit

  slurpit-warehouse:
    image: slurpit/warehouse:latest
    container_name: slurpit-warehouse
    restart: unless-stopped
    volumes:
      - warehouse-data:/var/lib/mysql
    environment:
      - TZ=Asia/Kathmandu
    networks:
      - slurpit

  slurpit-scanner:
    image: slurpit/scanner:latest
    container_name: slurpit-scanner
    restart: unless-stopped
    environment:
      - TZ=Asia/Kathmandu
    networks:
      - slurpit

  slurpit-scraper:
    image: slurpit/scraper:latest
    container_name: slurpit-scraper
    restart: unless-stopped
    environment:
      - TZ=Asia/Kathmandu
    networks:
      - slurpit

  slurpit-retriever:
    image: slurpit/retriever:latest
    container_name: slurpit-retriever
    restart: unless-stopped
    environment:
      - TZ=Asia/Kathmandu
    networks:
      - slurpit

volumes:
  portal-data:
  warehouse-data:

networks:
  slurpit:
    driver: bridge
EOF

# ── Pull images and start containers ────────────────────────────────
echo "Pulling Slurp'it container images..."
docker compose pull

echo "Starting Slurp'it containers..."
docker compose up -d

# ── Install Nginx ────────────────────────────────────────────────────
echo "Setting up Nginx reverse proxy for ${DOMAIN}..."

if ! command -v nginx &>/dev/null; then
  run_cmd "Installing Nginx" apt-get install -y nginx
fi

# ── SSL certificate (self-signed initially) ──────────────────────────
CERT_DIR="/etc/ssl/slurpit"
CERT_KEY="${CERT_DIR}/slurpit.key"
CERT_CRT="${CERT_DIR}/slurpit.crt"

if [ ! -f "${CERT_CRT}" ] || [ ! -f "${CERT_KEY}" ]; then
  echo "Generating self-signed TLS certificate for ${DOMAIN}..."
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "${CERT_KEY}" \
    -out "${CERT_CRT}" \
    -subj "/C=NP/ST=Bagmati/L=Kathmandu/O=TCIOE/CN=${DOMAIN}" 2>/dev/null
  chmod 600 "${CERT_KEY}"
fi

# ── Nginx site configuration ────────────────────────────────────────
cat > "${NGINX_SITE_CONF}" <<NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_CRT};
    ssl_certificate_key ${CERT_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 25m;

    location / {
        proxy_pass         http://127.0.0.1:${SLURPIT_HTTP_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
NGINX_EOF

ln -sf "${NGINX_SITE_CONF}" "${NGINX_SITE_ENABLED}"
rm -f /etc/nginx/sites-enabled/default

nginx -t || { echo "ERROR: Nginx configuration test failed"; exit 1; }
run_cmd "Restarting Nginx" systemctl restart nginx
systemctl enable nginx

# ── Optional: Let's Encrypt (certbot) ────────────────────────────────
echo ""
echo "---------------------------------------------------------------------"
echo " TIP: Replace the self-signed cert with Let's Encrypt (recommended):"
echo ""
echo "   apt install certbot python3-certbot-nginx"
echo "   certbot --nginx -d ${DOMAIN}"
echo "---------------------------------------------------------------------"

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " Slurp'it installation complete!"
echo "============================================="
echo ""
echo " Web UI:    https://${DOMAIN}"
echo " Install:   ${INSTALL_DIR}"
echo " Containers:"
docker compose ps --format "   {{.Name}}  {{.Status}}" 2>/dev/null || true
echo ""
echo " Useful commands:"
echo "   cd ${INSTALL_DIR}"
echo "   docker compose logs -f        # View logs"
echo "   docker compose restart        # Restart all"
echo "   docker compose down           # Stop all"
echo "   docker compose pull && docker compose up -d  # Update"
echo ""
