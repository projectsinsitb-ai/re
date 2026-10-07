#!/bin/bash
# Uso: sudo bash arreglar_dhcp.sh
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root"; exit 1; }

# ---- AJUSTA ESTO SEGÚN EL ENUNCIADO ----
LEASE_DEF=86400
LEASE_MAX=172800
ROUTER1="192.105.22.1"
HOST="$(cat /etc/hostname)"
# -----------------------------------------

BK=/root/backup_dhcp_$(date +%H%M%S)
mkdir -p "$BK"
cp -a /etc/dhcp /etc/default/isc-dhcp-server /etc/netplan /etc/hosts "$BK"/
echo "[+] Copia de seguridad en $BK"

# 1. Fichero include que faltaba
touch /etc/dhcp/windows.conf

# 2. dhcpd.conf completo
cat > /etc/dhcp/dhcpd.conf <<EOF
ddns-update-style none;
authoritative;
deny client-updates;

subnet 192.105.22.0 netmask 255.255.255.0 {
    option dhcp-server-identifier 192.105.22.1;
    option subnet-mask 255.255.255.0;
    option broadcast-address 192.105.22.255;
    option routers ${ROUTER1};
    option domain-name-servers 8.8.8.8, 192.105.22.1;
    option domain-name "seritbrce.domrce.internal";
    default-lease-time ${LEASE_DEF};
    max-lease-time ${LEASE_MAX};
    pool {
        deny known-clients;
        range 192.105.22.100 192.105.22.200;
    }
}

subnet 172.105.0.0 netmask 255.255.0.0 {
    option dhcp-server-identifier 172.105.22.1;
    option subnet-mask 255.255.0.0;
    option broadcast-address 172.105.255.255;
    option domain-name-servers 172.105.22.1, 8.8.8.8;
    option domain-name "domrce.internal";
    include "/etc/dhcp/windows.conf";
    default-lease-time ${LEASE_DEF};
    max-lease-time ${LEASE_MAX};
    pool {
        allow known-clients;
        range 172.105.0.100 172.105.0.200;
    }
}
EOF

# 3. Interfaces que sirve el DHCP
sed -i 's/^INTERFACESv4=.*/INTERFACESv4="enp2s0 enp3s0"/' /etc/default/isc-dhcp-server

# 4. Netplan: enp3s0 no puede tener DHCP y IP fija a la vez
sed -i '/enp3s0:/,/addresses:/ s/dhcp4: true/dhcp4: false/' /etc/netplan/00-installer-config.yaml

# 5. /etc/hosts coherente con el hostname
sed -i '/seritbrce/d' /etc/hosts
sed -i "/^127.0.0.1/a 192.105.22.1    ${HOST}.domrce.internal    ${HOST}" /etc/hosts

# 6. Validar y aplicar
echo "[+] Validando sintaxis..."
if dhcpd -t -cf /etc/dhcp/dhcpd.conf; then
    netplan apply
    systemctl restart isc-dhcp-server
    sleep 2
    systemctl is-active isc-dhcp-server
    ss -ulpn | grep ':67' && echo "[OK] dhcpd escuchando en el 67"
else
    echo "[!] dhcpd -t sigue dando errores. Copia original en $BK"
    exit 1
fi
