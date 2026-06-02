#!/bin/bash
# This script will install/upgrade Nautobot and configure Nginx as a reverse proxy.
set -euo pipefail

export NAUTOBOT_CONFIG=/opt/nautobot/nautobot_config.py
NAUTOBOT_USER=nautobot
NGINX_SITE_CONF="/etc/nginx/sites-available/nautobot"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/nautobot"
NAUTOBOT_PORT=8443

cd "$(dirname "$0")"
VIRTUALENV="$(pwd -P)/venv"

# ── Helper ───────────────────────────────────────────────────────────
run_cmd() {
  local msg="$1"; shift
  echo "${msg} ($*)..."
  "$@" || { echo "ERROR: Command failed: $*"; exit 1; }
}

# ── Static directories ──────────────────────────────────────────────
STATIC_DIRS=("jobs" "git" "media/image-attachments" "media/devicetype-images")

echo "Verifying static file directories..."
for d in "${STATIC_DIRS[@]}"; do
  dir="$(pwd -P)/${d}"
  if [ ! -d "${dir}" ]; then
    echo "  Creating ${dir}..."
    mkdir -p "${dir}"
    chown -R "${NAUTOBOT_USER}" "${dir}"
  fi
done

# ── Virtual environment ─────────────────────────────────────────────
WARN_MISSING_VENV=0
if [ -d "${VIRTUALENV}" ]; then
  echo "Removing old virtual environment..."
  rm -rf "${VIRTUALENV}"
else
  WARN_MISSING_VENV=1
fi

echo "Creating a new virtual environment at ${VIRTUALENV}..."
/usr/bin/python3 -m venv "${VIRTUALENV}" || {
  echo "--------------------------------------------------------------------"
  echo "ERROR: Failed to create the virtual environment. Check that you have"
  echo "the required system packages installed and the following path is"
  echo "writable: ${VIRTUALENV}"
  echo "--------------------------------------------------------------------"
  exit 1
}

source "${VIRTUALENV}/bin/activate"

# ── Python packages ─────────────────────────────────────────────────
run_cmd "Upgrading pip"          pip3 install --upgrade pip
run_cmd "Installing wheel"       pip3 install wheel
run_cmd "Installing Nautobot"    pip3 install nautobot

if [ -s "local_requirements.txt" ]; then
  run_cmd "Installing local dependencies" pip3 install -r local_requirements.txt
elif [ -f "local_requirements.txt" ]; then
  echo "Skipping local dependencies (local_requirements.txt is empty)"
else
  echo "Skipping local dependencies (local_requirements.txt not found)"
fi

# ── Nautobot post-install tasks ──────────────────────────────────────
run_cmd "Applying database migrations"      nautobot-server migrate
run_cmd "Checking for missing cable paths"  nautobot-server trace_paths --no-input
run_cmd "Collecting static files"           nautobot-server collectstatic --no-input
run_cmd "Removing stale content types"      nautobot-server remove_stale_contenttypes --no-input
run_cmd "Removing expired user sessions"    nautobot-server clearsessions

# ── Nginx reverse proxy setup ───────────────────────────────────────
echo "Setting up Nginx reverse proxy for Nautobot..."

run_cmd "Installing Nginx" apt-get install -y nginx

# Generate a self-signed certificate if one does not exist
CERT_DIR="/etc/ssl/nautobot"
CERT_KEY="${CERT_DIR}/nautobot.key"
CERT_CRT="${CERT_DIR}/nautobot.crt"

if [ ! -f "${CERT_CRT}" ] || [ ! -f "${CERT_KEY}" ]; then
  echo "Generating self-signed TLS certificate..."
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "${CERT_KEY}" \
    -out "${CERT_CRT}" \
    -subj "/C=US/ST=State/L=City/O=Nautobot/CN=$(hostname -f)" 2>/dev/null
  chmod 600 "${CERT_KEY}"
fi

# Write Nginx site configuration
cat > "${NGINX_SITE_CONF}" <<NGINX_EOF
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     ${CERT_CRT};
    ssl_certificate_key ${CERT_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 25m;

    location /static/ {
        alias $(pwd -P)/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:${NAUTOBOT_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF

# Enable the site and remove the default if present
ln -sf "${NGINX_SITE_CONF}" "${NGINX_SITE_ENABLED}"
rm -f /etc/nginx/sites-enabled/default

# Validate and reload Nginx
nginx -t || { echo "ERROR: Nginx configuration test failed"; exit 1; }
run_cmd "Restarting Nginx" systemctl restart nginx
systemctl enable nginx

# ── Summary ──────────────────────────────────────────────────────────
if [ "${WARN_MISSING_VENV}" -eq 1 ]; then
  echo "--------------------------------------------------------------------"
  echo "WARNING: No existing virtual environment was detected. A new one has"
  echo "been created. Update your systemd service files to reflect the new"
  echo "Python and gunicorn executables. (If this is a new installation,"
  echo "this warning can be ignored.)"
  echo ""
  echo "nautobot.service ExecStart:"
  echo "  ${VIRTUALENV}/bin/gunicorn"
  echo ""
  echo "nautobot-worker.service ExecStart:"
  echo "  ${VIRTUALENV}/bin/python"
  echo ""
  echo "After modifying these files, reload the systemctl daemon:"
  echo "  > systemctl daemon-reload"
  echo "--------------------------------------------------------------------"
fi

echo ""
echo "============================================="
echo " Nautobot install/upgrade complete!"
echo " Nginx reverse proxy configured on port 443"
echo "============================================="
echo ""
echo "Restart services:"
echo "  > sudo systemctl restart nautobot nautobot-worker nginx"
