#!/usr/bin/env bash
set -euo pipefail

KERNEL_DIR="${1:-$(pwd)}"
CONFIG_FILE="${2:-/proc/config.gz}"

need=(
  CONFIG_NAMESPACES
  CONFIG_UTS_NS
  CONFIG_IPC_NS
  CONFIG_PID_NS
  CONFIG_NET_NS
  CONFIG_POSIX_MQUEUE
  CONFIG_FHANDLE
  CONFIG_SECCOMP
  CONFIG_SECCOMP_FILTER
  CONFIG_KEYS
  CONFIG_CGROUPS
  CONFIG_MEMCG
  CONFIG_BLK_CGROUP
  CONFIG_CGROUP_SCHED
  CONFIG_CFS_BANDWIDTH
  CONFIG_CGROUP_FREEZER
  CONFIG_CGROUP_DEVICE
  CONFIG_CPUSETS
  CONFIG_CGROUP_CPUACCT
  CONFIG_CGROUP_PIDS
  CONFIG_VETH
  CONFIG_BRIDGE
  CONFIG_BRIDGE_NETFILTER
  CONFIG_MACVLAN
  CONFIG_VXLAN
  CONFIG_DUMMY
  CONFIG_TUN
  CONFIG_OVERLAY_FS
  CONFIG_EXT4_FS_POSIX_ACL
  CONFIG_EXT4_FS_SECURITY
  CONFIG_BLK_DEV_DM
  CONFIG_DM_THIN_PROVISIONING
  CONFIG_NETFILTER
  CONFIG_NF_CONNTRACK
  CONFIG_NETFILTER_XTABLES
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
  CONFIG_NETFILTER_XT_MATCH_CONNTRACK
  CONFIG_NETFILTER_XT_MATCH_MULTIPORT
  CONFIG_IP_NF_IPTABLES
  CONFIG_IP_NF_FILTER
  CONFIG_IP_NF_TARGET_REJECT
  CONFIG_IP_NF_NAT
  CONFIG_IP_NF_TARGET_MASQUERADE
  CONFIG_IP_NF_MANGLE
)

optional=(
  CONFIG_USER_NS
  CONFIG_MEMCG_SWAP
  CONFIG_MEMCG_SWAP_ENABLED
  CONFIG_CGROUP_BPF
  CONFIG_NETFILTER_XT_MATCH_IPVS
  CONFIG_NETFILTER_XT_TARGET_CHECKSUM
  CONFIG_IP6_NF_IPTABLES
  CONFIG_IP6_NF_FILTER
  CONFIG_IP6_NF_NAT
  CONFIG_IP6_NF_TARGET_MASQUERADE
  CONFIG_NF_TABLES
  CONFIG_NF_TABLES_IPV4
  CONFIG_NF_TABLES_IPV6
  CONFIG_NFT_NAT
  CONFIG_NFT_MASQ
  CONFIG_NFT_MASQ_IPV4
  CONFIG_NFT_MASQ_IPV6
  CONFIG_NFT_CHAIN_NAT_IPV4
  CONFIG_NFT_CHAIN_NAT_IPV6
)

if [[ "$CONFIG_FILE" == /proc/config.gz ]]; then
  if [[ -r /proc/config.gz ]]; then
    cfg_cmd=(zcat /proc/config.gz)
  else
    echo "ERR: /proc/config.gz 不可读；请传入编译生成的 .config 路径" >&2
    echo "用法: $0 <kernel_dir> <path-to-.config>" >&2
    exit 2
  fi
else
  cfg_cmd=(cat "$CONFIG_FILE")
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
"${cfg_cmd[@]}" > "$tmp"

status=0
check_one() {
  local sym="$1" class="$2"
  if grep -q "^${sym}=y" "$tmp"; then
    printf 'OK   %-9s %s=y\n' "$class" "$sym"
  elif grep -q "^${sym}=m" "$tmp"; then
    printf 'WARN %-9s %s=m  容器早期启动更建议内建 y\n' "$class" "$sym"
    [[ "$class" == required ]] && status=1
  else
    printf 'MISS %-9s %s\n' "$class" "$sym"
    [[ "$class" == required ]] && status=1
  fi
}

for s in "${need[@]}"; do check_one "$s" required; done
for s in "${optional[@]}"; do check_one "$s" optional; done

if [[ $status -eq 0 ]]; then
  echo "PASS: LXC/Docker 关键内核项已满足。"
else
  echo "FAIL: 有必需项缺失。"
fi
exit "$status"
