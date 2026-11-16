#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
cd -- "$(dirname -- "$0")"

[[ $EUID -eq 0 && ! -e /etc/pve && ! -d /etc/gwos && ! -d /opt/gwos &&
   $(hostname -s) == firewall ]] ||
    { echo 'Execute como root na VM Debian dedicada, com hostname firewall.' >&2; exit 1; }

ip -br link
read -r -p 'Interface do lado do roteador: ' uplink
read -r -p 'Interface do lado da LAN: ' lan
[[ $uplink != "$lan" ]] || { echo 'Escolha duas interfaces diferentes.' >&2; exit 1; }
for port in "$uplink" "$lan"; do
    [[ $port =~ ^[a-zA-Z0-9_-]+$ && -e /sys/class/net/$port/device &&
       ! -e /sys/class/net/$port/master ]] ||
        { echo "Interface inválida ou já vinculada: $port" >&2; exit 1; }
    [[ -z $(ip -o -4 addr show dev "$port") &&
       -z $(ip -o -6 addr show dev "$port" scope global) ]] ||
        { echo "Configure $port sem IP ou DHCP e tente novamente." >&2; exit 1; }
done

if [[ -e /etc/systemd/system/firewall-bridge.service || -e /etc/firewall ]]; then
    echo 'Instalação existente. Edite /etc/firewall/firewall.nft e recarregue o serviço.' >&2
    exit 1
fi
printf 'Bridge entre %s e %s. Confira no Proxmox se estão em segmentos separados.\n' "$uplink" "$lan"
read -r -p 'Digite INSTALAR para confirmar: ' confirmation
[[ $confirmation == INSTALAR ]] || exit 0

if ! command -v nft >/dev/null; then
    apt-get -o APT::Update::Error-Mode=any update
    apt-get install -y nftables
fi
rollback_install() {
    systemctl disable --now firewall-bridge.service 2>/dev/null || true
    rm -f -- /etc/systemd/system/firewall-bridge.service /usr/local/sbin/firewall-servico
    rm -f -- /etc/firewall/firewall.nft /etc/firewall/firewall.env
    rmdir /etc/firewall 2>/dev/null || true
    systemctl daemon-reload || true
}
[[ ! -e /usr/local/sbin/firewall-servico ]] ||
    { echo '/usr/local/sbin/firewall-servico já existe.' >&2; exit 1; }
trap rollback_install ERR
install -d -m 0755 /etc/firewall
install -m 0644 firewall.nft /etc/firewall/firewall.nft
install -m 0755 firewall-servico.sh /usr/local/sbin/firewall-servico
printf 'FIREWALL_UPLINK=%s\nFIREWALL_LAN=%s\n' "$uplink" "$lan" > /etc/firewall/firewall.env

cat > /etc/systemd/system/firewall-bridge.service <<'UNIT'
[Unit]
Description=Firewall transparente Ethernet
After=network.target nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/firewall/firewall.env
ExecStart=/usr/local/sbin/firewall-servico start ${FIREWALL_UPLINK} ${FIREWALL_LAN}
ExecReload=/usr/local/sbin/firewall-servico reload
ExecStop=/usr/local/sbin/firewall-servico stop

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl start firewall-bridge.service
systemctl enable firewall-bridge.service
trap - ERR
bridge link show master br-firewall
nft list table bridge firewall
