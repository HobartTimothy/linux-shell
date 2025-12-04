#!/usr/bin/env bash
#
# 通用 Linux 系统优化脚本（内核参数 + 磁盘清理）
# 适用于大部分主流发行版：Ubuntu / Debian / CentOS / RHEL / Rocky / Alma / Fedora / openSUSE / Arch 等
# 建议在生产环境使用前，先在测试环境验证，并按业务需求调整参数。
#
# 使用方式：
#   chmod +x optimize_common.sh
#   sudo ./optimize_common.sh
#
# 注意：
# - 不做侵入式极限调优，只做相对保守、社区通用的优化建议。
# - 尽量避免已经被弃用或有副作用的参数（例如 tcp_tw_recycle）。

set -euo pipefail

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    cp -a "$file" "${file}.$(date +%Y%m%d%H%M%S).bak"
  fi
}

apply_sysctl() {
  local sysctl_conf="/etc/sysctl.d/90-optimized.conf"

  echo "[*] 备份并写入内核参数到 ${sysctl_conf}"
  backup_file "$sysctl_conf"

  cat > "$sysctl_conf" <<'EOF'
########################################
# 通用 Linux 服务器内核优化参数（保守版）
# 参考社区和云厂商常见实践，适用于大多数 Web / API / 后端服务场景。
# 根据实际业务（高并发、低延迟、存储型等）再做针对性调整。
########################################

######## 基础网络参数 ########

# 增大监听队列长度
net.core.somaxconn = 65535
# 接收队列上限
net.core.netdev_max_backlog = 250000

# 允许适当的本地端口范围
net.ipv4.ip_local_port_range = 10240 65535

######## TCP 相关 ########

# 更大的 TCP 缓冲区（单位：字节）
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 启用 window scaling / SACK / Timestamps（默认即为 1，一般安全）
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

# SYN 队列长度 & 半连接队列
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_syncookies = 1

# TIME_WAIT 重用（对大量短连接有帮助，一般较安全）
net.ipv4.tcp_tw_reuse = 1
# 不启用已废弃且会导致问题的 tcp_tw_recycle

# 减少 FIN_WAIT 时间（根据业务自定）
net.ipv4.tcp_fin_timeout = 15

# Keepalive，更适用于服务端长连接（如反向代理、后端服务）
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

######## 队列与文件句柄 ########

# backlog 超出的连接直接丢弃而不是排队（对高并发有帮助）
net.core.netdev_max_backlog = 250000

# 更大的文件句柄上限（具体限制还需配合 ulimit）
fs.file-max = 2097152

######## 虚拟内存 ########

# 内存 overcommit 策略：1 表示允许合理的 overcommit（通用设置）
vm.overcommit_memory = 1

# swappiness：建议服务器为 1-10，降低交换分区使用概率
vm.swappiness = 10

# 提前回收 page cache 的阈值（默认 100，20~50 较为保守）
vm.vfs_cache_pressure = 50

######## 其它 ########

# 减少 ARP 缓存超时时间（视网络环境调整）
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

EOF

  sysctl --system
}

cleanup_disk_deb() {
  echo "[*] 执行 Debian/Ubuntu 系列磁盘清理..."
  apt-get update -y || true
  apt-get autoremove -y || true
  apt-get autoclean -y || true
  apt-get clean || true
  # 清理 journal 日志（保留最近 7 天）
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=7d || true
  fi
}

cleanup_disk_rpm() {
  echo "[*] 执行 RHEL/CentOS/Fedora 系列磁盘清理..."
  if command -v dnf >/dev/null 2>&1; then
    dnf clean all -y || true
  elif command -v yum >/dev/null 2>&1; then
    yum clean all -y || true
  fi
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=7d || true
  fi
}

cleanup_disk_pacman() {
  echo "[*] 执行 Arch 系列磁盘清理..."
  if command -v pacman >/dev/null 2>&1; then
    pacman -Sc --noconfirm || true
  fi
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=7d || true
  fi
}

cleanup_tmp() {
  echo "[*] 清理 /tmp 目录中过期文件（保留最近 3 天修改过的文件）..."
  find /tmp -type f -mtime +3 -print -delete 2>/dev/null || true
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请使用 root 执行本脚本（需要修改内核参数和系统文件）。"
    exit 1
  fi

  local distro
  distro="$(detect_distro)"
  echo "[*] 检测到发行版：${distro}"

  apply_sysctl

  case "$distro" in
    ubuntu|debian|kali|linuxmint)
      cleanup_disk_deb
      ;;
    centos|rhel|rocky|almalinux|fedora|ol)
      cleanup_disk_rpm
      ;;
    arch|manjaro)
      cleanup_disk_pacman
      ;;
    *)
      echo "[!] 未识别的发行版，仅执行通用 /tmp 清理。"
      ;;
  esac

  cleanup_tmp

  echo "[OK] 通用系统优化完成。建议重启后使部分参数完全生效。"
}

main "$@"


