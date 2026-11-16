#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

bridge=br-firewall
rules=/etc/firewall/firewall.nft
batch=$(mktemp)
trap 'rm -f -- "$batch"' EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }

load_rules() {
    if nft list table bridge firewall >/dev/null 2>&1; then
        printf 'delete table bridge firewall\n' > "$batch"
    else
        : > "$batch"
    fi
    cat "$rules" >> "$batch"
    nft -c -f "$batch"
    nft -f "$batch"
}

case ${1:-} in
    start)
        uplink=${2:-}
        lan=${3:-}
        [[ -n $uplink && -n $lan && $uplink != "$lan" ]] ||
            fail 'Configure duas interfaces distintas no firewall.env.'
        [[ ! -e /sys/class/net/$bridge ]] || fail "$bridge já existe."
        for port in "$uplink" "$lan"; do
            [[ $port =~ ^[a-zA-Z0-9_-]+$ && -e /sys/class/net/$port/device &&
               ! -e /sys/class/net/$port/master ]] ||
                fail "Interface inválida ou já vinculada a uma bridge: $port"
            [[ -z $(ip -o -4 addr show dev "$port") &&
               -z $(ip -o -6 addr show dev "$port" scope global) ]] ||
                fail "Remova a configuração de IP de $port antes de usá-la como porta de passagem."
        done
        nft list table bridge firewall >/dev/null 2>&1 &&
            fail 'A tabela bridge firewall já existe. Confira quem a criou.'
        ip link add name "$bridge" type bridge stp_state 0 mcast_snooping 0
        trap 'ip link delete dev "$bridge" 2>/dev/null || true;
              nft delete table bridge firewall 2>/dev/null || true;
              rm -f -- "$batch"' EXIT
        ip link set dev "$bridge" addrgenmode none
        load_rules
        ip link set dev "$uplink" master "$bridge" up
        ip link set dev "$lan" master "$bridge" up
        ip link set dev "$bridge" up
        trap 'rm -f -- "$batch"' EXIT
        ;;
    reload)
        [[ -d /sys/class/net/$bridge/bridge ]] || fail "$bridge está inativa."
        load_rules
        ;;
    stop)
        if [[ -d /sys/class/net/$bridge/bridge ]]; then ip link delete dev "$bridge"; fi
        if nft list table bridge firewall >/dev/null 2>&1; then nft delete table bridge firewall; fi
        ;;
    *) fail 'Use start, reload ou stop.' ;;
esac
