# Firewall transparente no Proxmox

Protótipo independente do GWOS para Debian 13. Mantém os equipamentos no mesmo domínio Ethernet. Os clientes de produção poderão manter seus IPs fixos, máscara, gateway e DNS quando a topologia for validada. O firewall encaminha quadros entre duas placas e aplica bloqueios IPv4/IPv6 por endereço em tráfego sem tag VLAN. A configuração inicial permite todo o tráfego de passagem. A VM não oferece DHCP, DNS, NAT, proxy ou painel web. O console do Proxmox é suficiente para administrar o protótipo.

## 1. Montar o laboratório

1. Confirme os nomes e a função das bridges existentes em **Nó → System → Network**. Crie duas Linux Bridges novas e isoladas, por exemplo `vmbr3` e `vmbr4`, se estiverem livres. Marque Autostart e deixe Bridge ports, IPv4, IPv6 e gateways vazios. Antes de aplicar, confira as mudanças pendentes. Preserve a vmbr0 e as bridges de teste do GWOS.
2. Crie uma VM chamada **firewall**, com Debian 13 em modo terminal, 1 vCPU, 1 GiB de RAM e 8–16 GiB de disco como ponto de partida. Configure também o **hostname Debian** como `firewall`.
3. Para instalar Debian e baixar dependências, use uma terceira placa virtual temporária em uma rede com internet, seguindo a política local. Antes de isolar a VM, instale `apt-get update && apt-get install nftables iproute2`. Depois remova ou desconecte a placa temporária. Configure as duas placas de passagem VirtIO em bridges diferentes. Em laboratório isolado, desmarque Firewall nessas duas placas da VM firewall para que filtros de MAC/IP do Proxmox não interfiram na passagem dos quadros de outros equipamentos. Não altere o firewall global do host.
4. Identifique as placas pelos MACs no Proxmox e em `ip -br link`. No Debian com ifupdown, configure ambas como `iface NOME inet manual`, sem DHCP, endereço ou gateway. Exclua eventuais configurações DHCP dessas duas portas antes de instalar. Aplique essa mudança pelo console. A administração deve usar o console ou uma terceira interface em rede de gerenciamento separada.
5. Ligue uma VM cliente a cada uma das bridges isoladas. Use dois IPs livres no laboratório, por exemplo `10.14.29.150/24` no lado que representa o roteador e `10.14.29.129/24` no lado LAN. Gateway e DNS podem ficar vazios para este primeiro ensaio. Esses IPs podem ser reutilizados no laboratório porque as duas bridges não têm ligação física com produção.

## 2. Instalar e testar

Extraia o ZIP, copie os três arquivos para a VM firewall e execute como root no diretório extraído:

```bash
bash firewall-instalar.sh
systemctl status firewall-bridge --no-pager
bridge link show master br-firewall
nft list table bridge firewall
```

Escolha as duas interfaces pelos MACs e digite INSTALAR. O instalador usa o nftables da VM e valida a tabela de regras antes de levantar a bridge. Se o pacote ainda faltar, o instalador precisará de uma saída de gerenciamento para baixá-lo. O serviço firewall-bridge carrega sua própria tabela e é iniciado no boot.

1. Com o serviço parado, os dois clientes em bridges separadas devem ficar isolados. Teste com ping aos endereços IPv4, desde que o firewall local permita ICMP.
2. Inicie o serviço e repita o ping nos dois sentidos. As duas interfaces devem aparecer vinculadas a br-firewall. Veja o contador da regra de passagem aumentar.
3. No firewall, aplique um bloqueio temporário e repita o ping entre os dois clientes:

   ```bash
   nft 'add element bridge firewall bloqueados_ipv4 { 10.14.29.129 }'
   nft list table bridge firewall
   ```

   A comunicação IPv4 que atravessa a bridge com esse endereço como origem ou destino deve parar, e um contador de descarte deve aumentar.
4. Remova o bloqueio de teste e repita o ping:

   ```bash
   nft 'delete element bridge firewall bloqueados_ipv4 { 10.14.29.129 }'
   ```

5. Para persistir uma política, edite `/etc/firewall/firewall.nft` e acrescente, por exemplo, `elements = { 10.14.29.129 }` dentro do conjunto escolhido. Rode `systemctl reload firewall-bridge`. A validação precede a troca atômica da tabela. Um reload repõe a política do arquivo, inclusive se houve alterações temporárias feitas com nft. Se IPv6 for usado, teste também o conjunto IPv6. As regras desta versão foram feitas para Ethernet sem VLAN.
6. Reinicie apenas a VM firewall, repita os testes e depois verifique o isolamento com `systemctl stop firewall-bridge`. Para continuar o laboratório, use `systemctl start firewall-bridge`. Se houver falha, consulte `journalctl -b -u firewall-bridge --no-pager`.

## 3. Critérios para produção e reversão

A posição proposta é **roteador 10.14.29.1 → porta 1 do Proxmox → VM firewall → porta 2 do Proxmox → switch da LAN**. Cada porta física fica em uma bridge Proxmox distinta. A LAN inclui os IPs .250, .251, .240, .241, .2, .4, .150 e .131, além dos demais equipamentos que precisam se comunicar no mesmo switch. Tráfego local entre dispositivos do mesmo lado permanece no switch. Internet e intranet que passam pelo roteador atravessam a VM. Este firewall bloqueia IPs em trânsito; filtragem por site ou Squid exigiria um projeto separado.

Antes de mover cabos, documente onde o Proxmox, Portal e SGF ficarão acessíveis. Teste Samba, impressão, Portal, SGF, acesso remoto vindo de outra sub-rede e saída pelo gateway. Verifique também onde as câmeras estão ligadas: uma bridge no caminho do roteador não cria rota para a rede 192.168.1.0/24. A VM Trânsito e o GWOS roteado podem continuar em laboratório, separados do caminho transparente.

Aguarde uma janela de manutenção antes de ligar a bridge à produção. Planeje o cabo de reversão: em caso de falha, desconecte uma das pernas do firewall e religue o switch diretamente ao roteador. Nunca deixe o caminho direto e a bridge ativos em paralelo entre os mesmos segmentos. Parar a VM interrompe a passagem entre seus dois lados até o desvio físico ou a restauração do serviço.

Para remover do Debian, execute pelo console:

```bash
systemctl disable --now firewall-bridge
rm /etc/systemd/system/firewall-bridge.service /usr/local/sbin/firewall-servico
systemctl daemon-reload
```

Guarde `/etc/firewall` se quiser recuperar a política. Para reinstalar do zero, mova o diretório para um backup antes de executar o instalador novamente. Em uma VM com outros gerenciadores de nftables, evite operações que limpem globalmente as tabelas enquanto o firewall estiver ativo.
