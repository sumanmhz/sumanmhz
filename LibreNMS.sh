#!/bin/bash
# LibreNMS Install script for Ubuntu 24.04
# Hosts LibreNMS at http://text.tcioe.edu.np
set -euo pipefail

DOMAIN="text.tcioe.edu.np"
PHP_VER="8.3"

# ── Helper ───────────────────────────────────────────────────────────
run_cmd() {
  local msg="$1"; shift
  echo "${msg} ($*)..."
  "$@" || { echo "ERROR: Command failed: $*"; exit 1; }
}

# ── Root check ───────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)."
  exit 1
fi

echo "============================================="
echo " LibreNMS Installer"
echo " Domain: ${DOMAIN}"
echo "============================================="
echo ""

# ── Timezone ─────────────────────────────────────────────────────────
echo "Have you set the system timezone? [yes/no]"
read -r ANS
if [[ "$ANS" =~ ^[Nn][Oo]?$ ]]; then
    echo "Available timezones (press q to quit list):"
    sleep 2
    timedatectl list-timezones
    echo "Enter system timezone:"
    read -r TZ
    timedatectl set-timezone "$TZ"
    echo "Timezone set to $TZ"
else
    TZ="$(cat /etc/timezone)"
    echo "Using existing timezone: $TZ"
fi

# ── Update & base packages ──────────────────────────────────────────
echo ""
echo "Updating package repositories..."
apt-get update -y

echo "Installing base dependencies..."
apt-get install -y software-properties-common
LC_ALL=C.UTF-8 add-apt-repository -y universe
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
apt-get update -y
apt-get upgrade -y

# ── Install all required packages ────────────────────────────────────
echo "Installing LibreNMS dependencies..."
apt-get install -y \
    acl composer curl fping git graphviz imagemagick \
    mariadb-client mariadb-server mtr-tiny nmap \
    php${PHP_VER}-cli php${PHP_VER}-curl php${PHP_VER}-fpm \
    php${PHP_VER}-gd php${PHP_VER}-gmp php${PHP_VER}-mbstring \
    php${PHP_VER}-mysql php${PHP_VER}-snmp php${PHP_VER}-xml \
    php${PHP_VER}-zip \
    python3-pymysql python3-psutil python3-setuptools \
    python3-systemd python3-pip python3-venv python3-dotenv \
    rrdtool snmp snmpd whois unzip traceroute

# ── Install Nginx ────────────────────────────────────────────────────
echo "Installing Nginx..."
if ! command -v nginx &>/dev/null; then
  apt-get install -y nginx-full
else
  echo "  Nginx already installed."
fi

# ── Download LibreNMS ────────────────────────────────────────────────
echo "Cloning LibreNMS to /opt/librenms..."
if [ -d "/opt/librenms" ]; then
  echo "  /opt/librenms already exists, pulling latest..."
  cd /opt/librenms && su librenms -s /bin/bash -c 'git pull' || true
else
  cd /opt
  git clone https://github.com/librenms/librenms.git
fi

# ── Create librenms user ─────────────────────────────────────────────
if ! id -u librenms &>/dev/null; then
  echo "Creating librenms user..."
  useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
fi

# ── Permissions & ACLs ───────────────────────────────────────────────
echo "Setting permissions and ACLs..."
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs \
    /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs \
    /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

# ── PHP dependencies (Composer) ─────────────────────────────────────
echo "Installing PHP dependencies via Composer..."
su librenms -s /bin/bash -c '/opt/librenms/scripts/composer_wrapper.php install --no-dev'

# ── Python dependencies ─────────────────────────────────────────────
echo "Installing Python dependencies..."
su librenms -s /bin/bash -c 'pip3 install --user -r /opt/librenms/requirements.txt' || \
  echo "WARNING: pip install had issues — check /opt/librenms/requirements.txt"

# ── Configure MariaDB ────────────────────────────────────────────────
echo ""
echo "Configuring MariaDB..."
systemctl restart mariadb

echo "Enter a password for the LibreNMS database user:"
read -rs DB_PASS
echo ""

mysql -uroot <<DBEOF
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
DBEOF

# Add innodb settings
if ! grep -q "innodb_file_per_table=1" /etc/mysql/mariadb.conf.d/50-server.cnf; then
  sed -i '/\[mysqld\]/ a innodb_file_per_table=1' /etc/mysql/mariadb.conf.d/50-server.cnf
fi
if ! grep -q "lower_case_table_names=0" /etc/mysql/mariadb.conf.d/50-server.cnf; then
  sed -i '/\[mysqld\]/ a lower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf
fi

systemctl restart mariadb
systemctl enable mariadb

# ── Configure PHP-FPM ────────────────────────────────────────────────
echo "Configuring PHP-FPM..."
cp /etc/php/${PHP_VER}/fpm/pool.d/www.conf /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf

sed -i 's/\[www\]/\[librenms\]/' /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf
sed -i 's/user = www-data/user = librenms/' /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf
sed -i 's/group = www-data/group = librenms/' /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf
sed -i "s|listen = /run/php/php${PHP_VER}-fpm.sock|listen = /run/php-fpm-librenms.sock|" \
    /etc/php/${PHP_VER}/fpm/pool.d/librenms.conf

# Set timezone in PHP configs
sed -i "s|;date.timezone =|date.timezone = ${TZ}|" /etc/php/${PHP_VER}/fpm/php.ini
sed -i "s|;date.timezone =|date.timezone = ${TZ}|" /etc/php/${PHP_VER}/cli/php.ini

systemctl restart php${PHP_VER}-fpm
systemctl enable php${PHP_VER}-fpm

# ── Nginx Configuration (HTTP only, no SSL) ──────────────────────────
echo "Configuring Nginx for ${DOMAIN} (HTTP)..."

cat > /etc/nginx/conf.d/librenms.conf <<'NGINX_EOF'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    root        /opt/librenms/html;
    index       index.php;
    charset     utf-8;

    client_max_body_size 25m;

    gzip on;
    gzip_types text/css application/javascript text/javascript
               application/x-javascript image/svg+xml text/plain
               text/xsd text/xsl text/xml image/x-icon;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_pass unix:/run/php-fpm-librenms.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi.conf;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX_EOF

# Replace placeholder (avoids bash expanding $uri etc.)
sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" /etc/nginx/conf.d/librenms.conf

rm -f /etc/nginx/sites-enabled/default

nginx -t || { echo "ERROR: Nginx configuration test failed"; exit 1; }
systemctl restart nginx
systemctl enable nginx

# ── LNMS CLI shortcut ───────────────────────────────────────────────
ln -sf /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

# ── SNMP Configuration ──────────────────────────────────────────────
echo "Configuring SNMP..."
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf

echo "Enter SNMP community string [e.g. public]:"
read -r COMMUNITY
sed -i "s/RANDOMSTRINGGOESHERE/${COMMUNITY}/g" /etc/snmp/snmpd.conf

curl -fsSL -o /usr/bin/distro \
    https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro

systemctl enable snmpd
systemctl restart snmpd

# ── Cron & Scheduler ────────────────────────────────────────────────
cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
cp /opt/librenms/dist/librenms-scheduler.service /etc/systemd/system/
cp /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/

# ── Systemd services for LibreNMS ────────────────────────────────────
echo "Creating systemd service files..."

# Main poller service
cat > /etc/systemd/system/librenms-poller.service <<EOF
[Unit]
Description=LibreNMS Poller Service
After=network.target mariadb.service

[Service]
Type=oneshot
User=librenms
Group=librenms
ExecStart=/opt/librenms/poller-wrapper.py 16
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Poller timer (runs every 5 minutes)
cat > /etc/systemd/system/librenms-poller.timer <<EOF
[Unit]
Description=LibreNMS Poller Timer

[Timer]
OnCalendar=*:0/5
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# Discovery service
cat > /etc/systemd/system/librenms-discovery.service <<EOF
[Unit]
Description=LibreNMS Discovery Service
After=network.target mariadb.service

[Service]
Type=oneshot
User=librenms
Group=librenms
ExecStart=/opt/librenms/discovery-wrapper.py 1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Discovery timer (runs every 6 hours)
cat > /etc/systemd/system/librenms-discovery.timer <<EOF
[Unit]
Description=LibreNMS Discovery Timer

[Timer]
OnCalendar=*:0/360
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# Daily maintenance service
cat > /etc/systemd/system/librenms-daily.service <<EOF
[Unit]
Description=LibreNMS Daily Maintenance
After=network.target mariadb.service

[Service]
Type=oneshot
User=librenms
Group=librenms
ExecStart=/opt/librenms/daily.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Daily maintenance timer
cat > /etc/systemd/system/librenms-daily.timer <<EOF
[Unit]
Description=LibreNMS Daily Timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload and enable all systemd units
systemctl daemon-reload
systemctl enable --now librenms-scheduler.timer
systemctl enable --now librenms-poller.timer
systemctl enable --now librenms-discovery.timer
systemctl enable --now librenms-daily.timer

# ── Logrotate ────────────────────────────────────────────────────────
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

# ── Firewall (if ufw is active) ─────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
  echo "Configuring firewall rules..."
  ufw allow 80/tcp
  ufw allow 161/udp
  ufw reload
fi

# ── Validate installation ───────────────────────────────────────────
echo ""
echo "Running LibreNMS validation..."
su librenms -s /bin/bash -c 'cd /opt/librenms && php validate.php' || true

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " LibreNMS installation complete!"
echo " http://${DOMAIN}"
echo "============================================="
echo ""
echo " Systemd services enabled:"
echo "   librenms-poller.timer      (every 5 min)"
echo "   librenms-discovery.timer   (every 6 hrs)"
echo "   librenms-daily.timer       (once daily)"
echo "   librenms-scheduler.timer   (scheduler)"
echo ""
echo " Next steps:"
echo "   1. Navigate to http://${DOMAIN}/install"
echo "      to finish the web-based setup."
echo ""
echo "   2. DB credentials:"
echo "      Database: librenms"
echo "      User:     librenms"
echo "      Host:     localhost"
echo ""
echo " Useful commands:"
echo "   systemctl status librenms-poller.timer"
echo "   systemctl list-timers --all | grep librenms"
echo "   journalctl -u librenms-poller"
echo "   su - librenms -c 'cd /opt/librenms && php validate.php'"
echo ""
echo " Have a nice day! ;)"
