#!/bin/bash

# https://github.com/getAlby/lndhub.go

APPID="lndhub"
GITHUB_REPO="https://github.com/getAlby/lndhub.go"
GITHUB_VERSION=""
GITHUB_SIGN_AUTHOR="K Llewellyn"
GITHUB_SIGN_PUBKEYLINK="https://github.com/gertjaap.gpg"
GITHUB_SIGN_FINGERPRINT="8C7D8A832F7166C5"

PORT_CLEAR=3000
PORT_SSL=3001
PORT_TOR_CLEAR=3002
PORT_TOR_SSL=3003

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "-help" ]; then
  echo "# bonus.${APPID}.sh status   -> status information (key=value)"
  echo "# bonus.${APPID}.sh on       -> install the app"
  echo "# bonus.${APPID}.sh off      -> uninstall the app"
  echo "# bonus.${APPID}.sh menu     -> SSH menu dialog"
  echo "# bonus.${APPID}.sh prestart -> will be called by systemd before start"
  exit 1
fi

echo "# Running: 'bonus.${APPID}.sh $*'"
source /mnt/hdd/raspiblitz.conf

isInstalled=$(sudo ls /etc/systemd/system/${APPID}.service 2>/dev/null | grep -c "${APPID}.service")
isRunning=$(systemctl status ${APPID} 2>/dev/null | grep -c 'active (running)')

if [ "${isInstalled}" == "1" ]; then
  localIP=$(hostname -I | awk '{print $1}')
  toraddress=$(sudo cat /mnt/hdd/tor/${APPID}/hostname 2>/dev/null)
  fingerprint=$(openssl x509 -in /mnt/hdd/app-data/nginx/tls.cert -fingerprint -noout | cut -d"=" -f2)
fi

if [ "$1" = "status" ]; then
  echo "appID='${APPID}'"
  echo "githubRepo='${GITHUB_REPO}'"
  echo "githubVersion='${GITHUB_VERSION}'"
  echo "isInstalled=${isInstalled}"
  echo "isRunning=${isRunning}"
  if [ "${isInstalled}" == "1" ]; then
    echo "portCLEAR=${PORT_CLEAR}"
    echo "portSSL=${PORT_SSL}"
    echo "localIP='${localIP}'"
    echo "toraddress='${toraddress}'"
    echo "fingerprint='${fingerprint}'"
  fi
  exit
fi

if [ "$1" = "menu" ]; then
  dialogTitle=" LNDhub "
  dialogText="LNDhub provides a Bluewallet-compatible Lightning accounting interface.

Open in your local web browser:
http://${localIP}:${PORT_CLEAR}

https://${localIP}:${PORT_SSL} with Fingerprint:
${fingerprint}

Use the admin credentials created during setup.
"
  if [ "${toraddress}" != "" ]; then
    dialogText="${dialogText}
Hidden Service address for Tor Browser (QRcode on LCD):
${toraddress}"
  fi
  whiptail --title "${dialogTitle}" --msgbox "${dialogText}" 18 67
  echo "please wait ..."
  exit 0
fi

if [ "$1" = "1" ] || [ "$1" = "on" ]; then

  if [ ${isInstalled} -eq 1 ]; then
    echo "# ${APPID}.service is already installed."
    exit 1
  fi

  echo "# Installing ${APPID} ..."

  # Check PostgreSQL is installed
  if ! command -v psql &> /dev/null; then
    echo "# Installing PostgreSQL..."
    sudo apt-get update
    sudo apt-get install -y postgresql
  fi

  # Check Go is installed
  if ! command -v go &> /dev/null; then
    echo "# Installing Go..."
    /home/admin/config.scripts/bonus.go.sh on
  fi

  # Create lndhub user
  echo "# create user"
  sudo adduser --disabled-password --gecos "" ${APPID} || exit 1
  sudo /usr/sbin/usermod --append --groups lndadmin ${APPID}

  # Create data directory
  if ! [ -d /mnt/hdd/app-data/${APPID} ]; then
    echo "# create app-data directory"
    sudo mkdir /mnt/hdd/app-data/${APPID}
    sudo chown ${APPID}:${APPID} -R /mnt/hdd/app-data/${APPID}
  else
    echo "# reuse existing app-directory"
    sudo chown ${APPID}:${APPID} -R /mnt/hdd/app-data/${APPID}
  fi

  # Clone and build lndhub.go
  echo "# download and build lndhub.go"
  sudo -u ${APPID} git clone ${GITHUB_REPO} /home/${APPID}/${APPID}
  cd /home/${APPID}/${APPID}

  # Get LND credentials
  echo "# preparing LND credentials"
  LND_DIR="/home/lnd/.lnd"
  LND_CERT_HEX=$(xxd -p -c 1000 ${LND_DIR}/tls.cert)
  LND_MACAROON_HEX=$(xxd -p -c 1000 ${LND_DIR}/data/chain/bitcoin/mainnet/admin.macaroon)

  # Create .env file
  echo "# creating .env configuration"
  cat > /home/${APPID}/${APPID}/.env <<EOF
DATABASE_URI=postgresql://lndhub:lndhub@localhost:5432/lndhub?sslmode=disable
JWT_SECRET=$(openssl rand -base64 32)
JWT_ACCESS_EXPIRY=172800
JWT_REFRESH_EXPIRY=604800
LND_ADDRESS=localhost:10009
LND_CERT_HEX=${LND_CERT_HEX}
LND_MACAROON_HEX=${LND_MACAROON_HEX}
HOST=127.0.0.1
PORT=${PORT_CLEAR}
EOF
  sudo chown ${APPID}:${APPID} /home/${APPID}/${APPID}/.env

  # Setup PostgreSQL database
  echo "# setting up PostgreSQL database"
  sudo -u postgres psql -c "CREATE USER lndhub WITH PASSWORD 'lndhub';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE lndhub OWNER lndhub;" 2>/dev/null || true
  sudo -u ${APPID} go run cmd/migrate/main.go 2>&1 | head -20

  # Build the binary
  echo "# building lndhub binary"
  sudo -u ${APPID} make build 2>&1 | tail -10

  # Open firewall ports
  echo "# updating Firewall"
  sudo ufw allow ${PORT_CLEAR} comment "${APPID} HTTP"
  sudo ufw allow ${PORT_SSL} comment "${APPID} HTTPS"

  # Create systemd service
  echo "# create systemd service: ${APPID}.service"
  cat > /tmp/${APPID}.service <<EOF
[Unit]
Description=LNDhub - Bluewallet-compatible Lightning API
Wants=bitcoind postgresql
After=bitcoind postgresql

[Service]
Environment="HOME=/home/${APPID}"
WorkingDirectory=/home/${APPID}/${APPID}
ExecStartPre=-/home/admin/config.scripts/bonus.${APPID}.sh prestart
ExecStart=/home/${APPID}/${APPID}/build/lndhub
User=${APPID}
Restart=always
TimeoutSec=120
RestartSec=30
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  sudo mv /tmp/${APPID}.service /etc/systemd/system/${APPID}.service
  sudo chown root:root /etc/systemd/system/${APPID}.service

  # Tor hidden service
  if [ "${runBehindTor}" = "on" ]; then
    /home/admin/config.scripts/tor.onion-service.sh ${APPID} 80 ${PORT_TOR_CLEAR} 443 ${PORT_TOR_SSL}
  fi

  # Nginx configuration
  echo "# setup nginx confing"
  cat > /etc/nginx/sites-available/${APPID}_ssl.conf <<EOF
server {
    listen ${PORT_SSL} ssl;
    listen [::]:${PORT_SSL} ssl;
    server_name _;
    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/snippets/ssl-certificate-app-data.conf;
    access_log /var/log/nginx/access_${APPID}.log;
    error_log /var/log/nginx/error_${APPID}.log;
    location / {
        proxy_pass http://127.0.0.1:${PORT_CLEAR};
        include /etc/nginx/snippets/ssl-proxy-params.conf;
    }
}
EOF
  sudo ln -sf /etc/nginx/sites-available/${APPID}_ssl.conf /etc/nginx/sites-enabled/

  cat > /etc/nginx/sites-available/${APPID}_tor.conf <<EOF
server {
    listen localhost:${PORT_TOR_CLEAR};
    server_name _;
    access_log /var/log/nginx/access_${APPID}.log;
    error_log /var/log/nginx/error_${APPID}.log;
    location / {
        proxy_pass http://127.0.0.1:${PORT_CLEAR};
    }
}
EOF
  sudo ln -sf /etc/nginx/sites-available/${APPID}_tor.conf /etc/nginx/sites-enabled/

  cat > /etc/nginx/sites-available/${APPID}_tor_ssl.conf <<EOF
server {
    listen localhost:${PORT_TOR_SSL} ssl;
    server_name _;
    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/snippets/ssl-certificate-app-data-tor.conf;
    access_log /var/log/nginx/access_${appID}.log;
    error_log /var/log/nginx/error_${appID}.log;
    location / {
        proxy_pass http://127.0.0.1:${PORT_CLEAR};
        include /etc/nginx/snippets/ssl-proxy-params.conf;
    }
}
EOF
  sudo ln -sf /etc/nginx/sites-available/${APPID}_tor_ssl.conf /etc/nginx/sites-enabled/

  sudo nginx -t
  sudo systemctl reload nginx

  # Mark as installed
  /home/admin/config.scripts/blitz.conf.sh set ${APPID} "on"

  # Start service
  sudo systemctl enable ${APPID}
  sudo systemctl start ${APPID}
  echo "# OK - the ${APPID}.service is now enabled & started"
  echo "# Monitor with: sudo journalctl -f -u ${APPID}"
  exit 0

fi

if [ "$1" = "prestart" ]; then
  if [ "$USER" != "${APPID}" ]; then
    echo "# FAIL: run as user ${APPID}"
    exit 1
  fi
  echo "## PRESTART CONFIG START for ${APPID}"
  echo "# no need for adhoc config needed so far"
  echo "## PRESTART CONFIG DONE for ${APPID}"
  exit 0
fi

if [ "$1" = "0" ] || [ "$1" = "off" ]; then
  echo "# stop & remove systemd service"
  sudo systemctl stop ${APPID} 2>/dev/null
  sudo systemctl disable ${APPID}.service
  sudo rm /etc/systemd/system/${APPID}.service

  echo "# remove nginx symlinks"
  sudo rm -f /etc/nginx/sites-enabled/${APPID}_ssl.conf
  sudo rm -f /etc/nginx/sites-enabled/${APPID}_tor.conf
  sudo rm -f /etc/nginx/sites-enabled/${APPID}_tor_ssl.conf
  sudo rm -f /etc/nginx/sites-available/${APPID}_ssl.conf
  sudo rm -f /etc/nginx/sites-available/${APPID}_tor.conf
  sudo rm -f /etc/nginx/sites-available/${APPID}_tor_ssl.conf
  sudo nginx -t
  sudo systemctl reload nginx

  echo "# close ports on firewall"
  sudo ufw deny "${PORT_CLEAR}"
  sudo ufw deny "${PORT_SSL}"

  echo "# removing Tor hidden service"
  /home/admin/config.scripts/tor.onion-service.sh off ${APPID}

  echo "# mark app as uninstalled in raspiblitz config"
  /home/admin/config.scripts/blitz.conf.sh set ${APPID} "off"

  if [ "$(echo "$@" | grep -c delete-data)" -gt 0 ]; then
    echo "# found 'delete-data' parameter --> also deleting the app-data"
    sudo rm -r /mnt/hdd/app-data/${APPID}
  fi

  echo "# OK - app should be deinstalled now"
  exit 0

fi

echo "# FAIL - Unknown Parameter $1"
exit 1
