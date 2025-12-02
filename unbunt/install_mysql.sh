#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (e.g., sudo $0)" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mysql-server

# Ensure MySQL starts on boot and is running now
systemctl enable --now mysql

# Optionally set the root password when MYSQL_ROOT_PASSWORD is provided
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  mysql --protocol=socket -uroot --execute="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD//\'/'"'"'}'; FLUSH PRIVILEGES;"
  echo "Root password set from MYSQL_ROOT_PASSWORD env var."
fi

CONFIG_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "MySQL config file not found at $CONFIG_FILE" >&2
  exit 1
fi

set_bind_address() {
  local ip="$1"
  if grep -Eq '^[#[:space:]]*bind-address[[:space:]]*=' "$CONFIG_FILE"; then
    sed -i "s/^[#[:space:]]*bind-address[[:space:]]*=.*/bind-address = $ip/" "$CONFIG_FILE"
  else
    printf "\n[mysqld]\nbind-address = %s\n" "$ip" >> "$CONFIG_FILE"
  fi
}

set_thread_concurrency() {
  local value="$1"
  if grep -Eq '^[#[:space:]]*thread_concurrency[[:space:]]*=' "$CONFIG_FILE"; then
    sed -i "s/^[#[:space:]]*thread_concurrency[[:space:]]*=.*/thread_concurrency = $value/" "$CONFIG_FILE"
  else
    printf "\n[mysqld]\nthread_concurrency = %s\n" "$value" >> "$CONFIG_FILE"
  fi
}

echo "Remote access configuration:"
read -rp "Restrict remote access to a specific IP? (y/N): " limit_remote
if [[ "${limit_remote:-}" =~ ^[Yy]$ ]]; then
  read -rp "Enter the allowed IP address: " allowed_ip
  if [[ -z "${allowed_ip:-}" ]]; then
    echo "No IP provided; exiting." >&2
    exit 1
  fi
  set_bind_address "$allowed_ip"
  echo "MySQL bind-address set to: $allowed_ip"
else
  set_bind_address "0.0.0.0"
  echo "MySQL bind-address set to: 0.0.0.0 (no IP restriction)"
fi

CPU_CORES=$(nproc)
MAX_THREAD_CONCURRENCY=$((CPU_CORES * 2))

echo "thread_concurrency configuration:"
echo "Default (recommended): $MAX_THREAD_CONCURRENCY (2 x CPU cores). Custom value must be < $MAX_THREAD_CONCURRENCY."
read -rp "Enter thread_concurrency (< $MAX_THREAD_CONCURRENCY) or press Enter to use default: " tc_input

if [[ -n "${tc_input:-}" ]]; then
  if ! [[ "$tc_input" =~ ^[0-9]+$ ]]; then
    echo "Invalid number for thread_concurrency." >&2
    exit 1
  fi
  if (( tc_input <= 0 || tc_input >= MAX_THREAD_CONCURRENCY )); then
    echo "thread_concurrency must be greater than 0 and less than $MAX_THREAD_CONCURRENCY." >&2
    exit 1
  fi
  thread_concurrency="$tc_input"
else
  thread_concurrency="$MAX_THREAD_CONCURRENCY"
fi

set_thread_concurrency "$thread_concurrency"
echo "thread_concurrency set to: $thread_concurrency"

systemctl restart mysql

mysql --version
systemctl is-active --quiet mysql && echo "MySQL is running." || echo "MySQL is not running."
