#!/bin/bash
# VitalPBX Install Script for Ubuntu
set -euo pipefail

VITALPBX_BRANCH="vitalpbx-3"
VITALPBX_REPO="https://raw.githubusercontent.com/VitalPBX/VPS/${VITALPBX_BRANCH}/resources"

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
echo " VitalPBX Installer (Ubuntu)"
echo "============================================="
echo ""

# ── Update system ───────────────────────────────────────────────────
echo "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# ── Install dependencies ────────────────────────────────────────────
echo "Installing required packages..."
apt-get install -y \
    curl wget gnupg2 apt-transport-https lsb-release ca-certificates \
    apache2 libapache2-mod-php \
    php php-cli php-common php-mysql php-gd php-mbstring \
    php-curl php-xml php-zip php-bcmath php-intl \
    mariadb-server mariadb-client \
    asterisk asterisk-core-sounds-en asterisk-core-sounds-en-wav \
    fail2ban sngrep \
    sox mpg123 lame ffmpeg \
    odbc-mariadb unixodbc \
    git unzip sudo

# ── SSH Welcome Banner ──────────────────────────────────────────────
echo "Installing SSH welcome banner..."
rm -f /etc/profile.d/vitalwelcome.sh
curl -fsSL -o /etc/profile.d/vitalwelcome.sh "${VITALPBX_REPO}/vitalwelcome.sh" || \
    echo "WARNING: Could not download welcome banner, skipping."
chmod 644 /etc/profile.d/vitalwelcome.sh 2>/dev/null || true

# ── Configure MariaDB ───────────────────────────────────────────────
echo "Configuring MariaDB..."
systemctl enable mariadb
systemctl start mariadb

# Secure defaults
mysql -uroot <<DBEOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
DBEOF

# Create asterisk database and user
echo "Enter a password for the Asterisk database user:"
read -rs DB_PASS
echo ""

mysql -uroot <<DBEOF
CREATE DATABASE IF NOT EXISTS asterisk CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'asterisk'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';
FLUSH PRIVILEGES;
DBEOF

systemctl restart mariadb

# ── Configure Apache ─────────────────────────────────────────────────
echo "Configuring Apache..."
a2enmod rewrite
a2enmod php*

# Set Asterisk user permissions for Apache
chown -R asterisk:asterisk /var/lib/asterisk
chown -R asterisk:asterisk /var/spool/asterisk
chown -R asterisk:asterisk /var/log/asterisk
chown -R asterisk:asterisk /var/run/asterisk
chown -R asterisk:asterisk /etc/asterisk

# Set Apache to run as asterisk user
sed -i 's/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=asterisk/' /etc/apache2/envvars
sed -i 's/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=asterisk/' /etc/apache2/envvars

systemctl enable apache2
systemctl restart apache2

# ── Configure Asterisk ───────────────────────────────────────────────
echo "Configuring Asterisk..."

# Run asterisk as asterisk user
if [ -f /etc/default/asterisk ]; then
  sed -i 's/^#AST_USER=.*/AST_USER="asterisk"/' /etc/default/asterisk
  sed -i 's/^#AST_GROUP=.*/AST_GROUP="asterisk"/' /etc/default/asterisk
  sed -i 's/^AST_USER=.*/AST_USER="asterisk"/' /etc/default/asterisk
  sed -i 's/^AST_GROUP=.*/AST_GROUP="asterisk"/' /etc/default/asterisk
fi

systemctl enable asterisk
systemctl restart asterisk

# ── Configure Fail2Ban ───────────────────────────────────────────────
echo "Configuring Fail2Ban for Asterisk..."
cat > /etc/fail2ban/jail.d/asterisk.conf <<EOF
[asterisk]
enabled  = true
filter   = asterisk
action   = ufw[name=Asterisk, port=5060, protocol=udp]
logpath  = /var/log/asterisk/messages
maxretry = 3
bantime  = 3600
findtime = 600
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ── Firewall (UFW) ──────────────────────────────────────────────────
echo "Configuring UFW firewall..."
apt-get install -y ufw

# Default policies
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp

# HTTP/HTTPS for web UI
ufw allow 80/tcp
ufw allow 443/tcp

# SIP (UDP/TCP 5060) and SIP-TLS (TCP 5061)
ufw allow 5060/udp
ufw allow 5060/tcp
ufw allow 5061/tcp

# RTP media ports
ufw allow 10000:20000/udp

# IAX2
ufw allow 4569/udp

# Enable firewall (non-interactive)
echo "y" | ufw enable

# ── Kernel tuning ───────────────────────────────────────────────────
if [ ! -f /etc/sysctl.d/10-vitalpbx.conf ]; then
  cat > /etc/sysctl.d/10-vitalpbx.conf <<EOF
# Reboot machine automatically after 20 seconds if kernel panics
kernel.panic = 20
EOF
  sysctl --system &>/dev/null
fi

# ── Hostname resolution speedup ─────────────────────────────────────
sed -i 's/^hosts.*$/hosts:      myhostname files dns/' /etc/nsswitch.conf

# ── Summary ──────────────────────────────────────────────────────────
IP_ADDR=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================="
echo " VitalPBX installation complete!"
echo "============================================="
echo ""
echo " Web UI:  http://${IP_ADDR}"
echo ""
echo " Firewall ports opened:"
echo "   SSH          22/tcp"
echo "   HTTP/HTTPS   80, 443"
echo "   SIP          5060/udp, 5060/tcp, 5061/tcp"
echo "   RTP          10000-20000/udp"
echo "   IAX2         4569/udp"
echo ""
echo " DB credentials:"
echo "   Database: asterisk / asteriskcdrdb"
echo "   User:     asterisk"
echo "   Host:     localhost"
echo ""
echo " Services:"
echo "   systemctl status asterisk"
echo "   systemctl status apache2"
echo "   systemctl status mariadb"
echo "   systemctl status fail2ban"
echo ""
echo " Have a nice day! ;)"
