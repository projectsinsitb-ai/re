#!/bin/bash
# practica_servidor.sh
# Usuario + hostname + tarjetas (isard/oficina/taller) + DHCP + logs de pruebas
# Uso: sudo bash practica_servidor.sh [/ruta/coneguts.conf]

[ "$EUID" -eq 0 ] || { echo "Ejecuta con: sudo bash $0 [coneguts.conf]"; exit 1; }

################ AJUSTES ################
NEWUSER="hrazzouki"
NEWHOST="seritbhrb"
MAC_OFI="52:54:00:26:d3:2a"     # tarjeta 2 -> oficina
MAC_TAL="52:54:00:53:3b:f7"     # tarjeta 3 -> taller
IF_OFI="oficina"
IF_TAL="taller"
# Desconocidos de oficina (literal del enunciado). Si fuera errata:
#   OFI_UNK_NET="192.168.20"  y  OFI_UNK_FROM=100
OFI_UNK_NET="192.168.100"
OFI_UNK_FROM=5
OFI_UNK_TO=150
#########################################

# ---------- 0. Comprobaciones ----------
for m in "$MAC_OFI" "$MAC_TAL"; do
    ip -o link | grep -qi "link/ether $m" || {
        echo "No hay ninguna tarjeta con MAC $m. Tarjetas actuales:"; ip -br link; exit 1; }
done

CONF="${1:-}"
[ -n "$CONF" ] || CONF="$(find / -xdev -name 'coneguts.conf' 2>/dev/null | head -1)"
[ -f "$CONF" ] || { echo "No encuentro coneguts.conf. Pásalo como argumento."; exit 1; }
echo "[i] Usando $CONF"

# ---------- 1. Usuario con sudo + hostname ----------
if id "$NEWUSER" &>/dev/null; then
    echo "[i] $NEWUSER ya existe."
else
    adduser --disabled-password --gecos "" "$NEWUSER"
    while true; do
        read -rsp "Contraseña para $NEWUSER: " P1; echo
        read -rsp "Repite la contraseña: " P2; echo
        [ "$P1" = "$P2" ] && [ -n "$P1" ] && break
        echo "No coinciden o está vacía, otra vez."
    done
    echo "$NEWUSER:$P1" | chpasswd; unset P1 P2
fi
usermod -aG sudo "$NEWUSER"

hostnamectl set-hostname "$NEWHOST"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEWHOST/" /etc/hosts
else
    echo "127.0.1.1 $NEWHOST" >> /etc/hosts
fi

# ---------- 2. Leer coneguts.conf ----------
parse_hosts() {
    local section="" pend="" line low net mac name ip hostline
    local -A n=([oficina]=4 [taller]=4) seen=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"; low="${line,,}"
        case "$low" in \#*|\;*|//*) continue;; esac
        net=""; hostline=""
        case "$low" in *oficina*) net=oficina;; *taller*) net=taller;; esac
        if [[ $low =~ host[[:space:]]+([a-z0-9_-]+) ]]; then pend="${BASH_REMATCH[1]}"; hostline=1; fi
        mac=$(grep -oiE '([0-9a-f]{2}[:-]){5}[0-9a-f]{2}' <<<"$line" | head -1 | tr 'A-F-' 'a-f:')
        if [ -z "$mac" ]; then
            [ -n "$net" ] && [ -z "$hostline" ] && section="$net"
            continue
        fi
        [ -n "$net" ] || net="$section"
        [ -n "$net" ] || { echo "AVISO: sin red (oficina/taller): $line" >&2; continue; }
        n[$net]=$(( n[$net] + 1 ))
        [ "${n[$net]}" -le 10 ] || { echo "AVISO: más de 6 hosts en $net, ignoro: $line" >&2; continue; }
        if [ -n "$pend" ]; then
            name="$pend"; pend=""
        else
            name=$(sed -E 's/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}//g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}//g; s/oficina|taller|hardware|ethernet|fixed-address|host|mac//Ig' <<<"$line" \
                   | grep -oE '[A-Za-z][A-Za-z0-9_-]*' | head -1)
        fi
        name=$(tr 'A-Z_' 'a-z-' <<<"$name")
        [ -n "$name" ] || name="$net-${n[$net]}"
        [ -z "${seen[$name]:-}" ] || name="$name-${n[$net]}"
        seen[$name]=1
        if [ "$net" = oficina ]; then ip="192.168.20.${n[$net]}"; else ip="192.168.67.${n[$net]}"; fi
        echo "$net $mac $name $ip"
    done < "$CONF"
}
mapfile -t HOSTS < <(parse_hosts)
[ "${#HOSTS[@]}" -gt 0 ] || { echo "No he entendido ningún host de $CONF. Pégamelo y adapto el parser."; exit 1; }
echo "[i] Hosts conocidos detectados (red / MAC / nombre / IP):"
printf '    %s\n' "${HOSTS[@]}"
read -rp "¿Es correcto? [S/n] " R
[[ "${R:-S}" =~ ^[Ss]$ ]] || { echo "Cancelado. Revisa $CONF."; exit 1; }

# ---------- 3. Netplan: renombrar tarjetas + IPs ----------
cat > /etc/netplan/01-practica.yaml <<EOF
network:
  version: 2
  ethernets:
    $IF_OFI:
      match:
        macaddress: $MAC_OFI
      set-name: $IF_OFI
      dhcp4: false
      optional: true
      addresses:
        - 192.168.20.1/24
$( [ "$OFI_UNK_NET" != "192.168.20" ] && echo "        - $OFI_UNK_NET.1/24" )
    $IF_TAL:
      match:
        macaddress: $MAC_TAL
      set-name: $IF_TAL
      dhcp4: false
      optional: true
      addresses:
        - 192.168.67.1/16
EOF
chmod 600 /etc/netplan/01-practica.yaml
netplan generate || { echo "Error en el YAML de netplan"; exit 1; }
netplan apply
udevadm settle; sleep 4
for i in "$IF_OFI" "$IF_TAL"; do
    ip link show "$i" &>/dev/null || {
        echo "La tarjeta '$i' no se ha renombrado todavía."
        echo "Haz 'sudo reboot' y vuelve a ejecutar este script."; exit 1; }
done

# ---------- 4. Instalar dnsmasq (sin que arranque solo) ----------
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
rm -f /usr/sbin/policy-rc.d
command -v dnsmasq >/dev/null || { echo "dnsmasq no se instaló (¿sin internet?)"; exit 1; }
grep -qE '^conf-dir=/etc/dnsmasq.d' /etc/dnsmasq.conf || echo 'conf-dir=/etc/dnsmasq.d/,*.conf' >> /etc/dnsmasq.conf

# ---------- 5. Configuración DHCP ----------
{
    echo "# Generado por practica_servidor.sh"
    echo "port=0                  # solo DHCP (evita choque con systemd-resolved)"
    echo "bind-dynamic"
    echo "interface=$IF_OFI"
    echo "interface=$IF_TAL"
    echo "dhcp-authoritative"
    echo "log-dhcp"
    echo "dhcp-leasefile=/var/lib/misc/dnsmasq.leases"
    echo
    echo "# ---- OFICINA ----"
    echo "dhcp-range=tag:$IF_OFI,192.168.20.0,static,255.255.255.0"
    echo "dhcp-range=tag:$IF_OFI,$OFI_UNK_NET.$OFI_UNK_FROM,$OFI_UNK_NET.$OFI_UNK_TO,255.255.255.0,12h"
    echo "# ---- TALLER ----"
    echo "dhcp-range=tag:$IF_TAL,192.168.67.100,192.168.67.150,255.255.0.0,12h"
    echo
    echo "# ---- HOSTS CONOCIDOS (de $CONF) ----"
    for h in "${HOSTS[@]}"; do
        read -r net mac name ip <<<"$h"
        echo "dhcp-host=$mac,$name,$ip     # $net"
    done
} > /etc/dnsmasq.d/practica.conf

dnsmasq --test || { echo "Error en la configuración de dnsmasq"; exit 1; }
systemctl enable dnsmasq >/dev/null 2>&1
systemctl restart dnsmasq

# ---------- 6. Logs de pruebas (estilo captura, prompt usuario@host) ----------
LOGDIR="/home/$NEWUSER/pruebas"
mkdir -p "$LOGDIR"
P="$NEWUSER@$NEWHOST:~\$"
mklog() { LOG="$LOGDIR/$1"; : > "$LOG"; }
runu()  { printf '%s %s\n' "$P" "$1" | tee -a "$LOG"; sudo -u "$NEWUSER" -H bash -c "cd ~; $1" 2>&1 | tee -a "$LOG"; }
runs()  { printf '%s sudo %s\n' "$P" "$1" | tee -a "$LOG"; bash -c "$1" 2>&1 | tee -a "$LOG"; }

mklog 01_usuario_hostname.txt
runu 'ls'
runu 'echo $HOSTNAME'
runu 'whoami'
runu "id $NEWUSER"
runu 'hostnamectl'

mklog 02_tarjetas_red.txt
runu 'ip a'
runu 'ip -br a'
runu 'ip route'
runs 'cat /etc/netplan/01-practica.yaml'
runs 'netplan get'

mklog 03_dhcp_config.txt
runs "cat $CONF"
runs 'cat /etc/dnsmasq.d/practica.conf'
runs 'dnsmasq --test'
runs 'systemctl status dnsmasq --no-pager'
runs 'ss -ulpn | grep ":67 "'

# ---------- 7. Script auxiliar para el log de leases (cuando haya clientes) ----------
cat > "$LOGDIR/ver_leases.sh" <<'EOS'
#!/bin/bash
# Uso: sudo bash ~/pruebas/ver_leases.sh   (después de encender los clientes)
[ "$EUID" -eq 0 ] || { echo "Usa sudo"; exit 1; }
U="${SUDO_USER:-hrazzouki}"; H="$(hostname)"
LOG="/home/$U/pruebas/04_leases_clientes.txt"; : > "$LOG"
runs() { printf '%s@%s:~$ sudo %s\n' "$U" "$H" "$1" | tee -a "$LOG"; bash -c "$1" 2>&1 | tee -a "$LOG"; }
runs 'cat /var/lib/misc/dnsmasq.leases'
runs 'journalctl -u dnsmasq --no-pager | grep -E "DHCP(DISCOVER|OFFER|REQUEST|ACK)" | tail -n 30'
chown "$U:$U" "$LOG"
EOS
chmod +x "$LOGDIR/ver_leases.sh"
chown -R "$NEWUSER:$NEWUSER" "$LOGDIR"

echo
echo "[OK] Todo listo. Logs en $LOGDIR:"
ls -1 "$LOGDIR"
echo "Entra como $NEWUSER (su - $NEWUSER) y haz 'cat pruebas/<fichero>' para las capturas."
