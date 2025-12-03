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

set_storage_engine() {
  local engine="$1"
  if grep -Eq '^[#[:space:]]*default_storage_engine[[:space:]]*=' "$CONFIG_FILE"; then
    sed -i "s/^[#[:space:]]*default_storage_engine[[:space:]]*=.*/default_storage_engine = $engine/" "$CONFIG_FILE"
  else
    printf "\n[mysqld]\ndefault_storage_engine = %s\n" "$engine" >> "$CONFIG_FILE"
  fi
}

set_config_value() {
  local key="$1"
  local value="$2"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
    sed -i "s/^[#[:space:]]*${key}[[:space:]]*=.*/${key} = $value/" "$CONFIG_FILE"
  else
    printf "\n[mysqld]\n%s = %s\n" "$key" "$value" >> "$CONFIG_FILE"
  fi
}

validate_size_format() {
  local size="$1"
  [[ "$size" =~ ^[0-9]+[KkMmGg]?$ ]]
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

cat <<'EOF'
Storage engine options:
- InnoDB : ACID, row-level locking, crash recovery (recommended).
- MyISAM : Table-level locking, no transactions, fast reads.
- MEMORY : Data in RAM, non-persistent, very fast but volatile.
EOF

default_engine="InnoDB"
read -rp "Choose storage engine [InnoDB/MyISAM/MEMORY] (default: ${default_engine}): " engine_input
engine_choice=${engine_input:-$default_engine}
engine_choice=${engine_choice^^}

case "$engine_choice" in
  INNODB)
    set_storage_engine "$engine_choice"
    echo "default_storage_engine set to: $engine_choice"

    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || true)
    if [[ -n "${mem_kb:-}" && "$mem_kb" =~ ^[0-9]+$ ]]; then
      default_buffer_pool="$((mem_kb * 75 / 100 / 1024))M" # ~75% RAM
    else
      default_buffer_pool="1G"
    fi
    default_log_file_size="1G"
    default_flush_at_trx_commit="1"
    default_file_per_table="1"
    default_flush_method="O_DIRECT"
    if [[ "${CPU_CORES:-}" =~ ^[0-9]+$ && "$CPU_CORES" -gt 0 ]]; then
      default_io_threads=$(( CPU_CORES > 4 ? CPU_CORES : 4 ))
    else
      default_io_threads=4
    fi
    default_io_capacity="200"
    default_io_capacity_max="2000"
    default_flush_log_timeout="1"
    default_lock_wait_timeout="50"
    default_adaptive_hash="1"
    default_sort_buffer_size="256M"
    default_table_locks="ON"

    echo "InnoDB tuning (press Enter for defaults):"

    read -rp "innodb_buffer_pool_size (recommend 60%-80% RAM, default: $default_buffer_pool): " bp_input
    innodb_buffer_pool_size="${bp_input:-$default_buffer_pool}"
    if ! validate_size_format "$innodb_buffer_pool_size"; then
      echo "Invalid innodb_buffer_pool_size format. Use numbers with optional K/M/G suffix." >&2
      exit 1
    fi

    read -rp "innodb_log_file_size (256M-1G typical, default: $default_log_file_size): " log_input
    innodb_log_file_size="${log_input:-$default_log_file_size}"
    if ! validate_size_format "$innodb_log_file_size"; then
      echo "Invalid innodb_log_file_size format. Use numbers with optional K/M/G suffix." >&2
      exit 1
    fi

    read -rp "innodb_flush_log_at_trx_commit [0/1/2] (default: $default_flush_at_trx_commit): " flush_trx_input
    flush_trx="${flush_trx_input:-$default_flush_at_trx_commit}"
    if ! [[ "$flush_trx" =~ ^[0-2]$ ]]; then
      echo "Invalid innodb_flush_log_at_trx_commit. Allowed: 0, 1, 2." >&2
      exit 1
    fi

    read -rp "innodb_file_per_table [0/1] (default: $default_file_per_table): " fpt_input
    file_per_table="${fpt_input:-$default_file_per_table}"
    if ! [[ "$file_per_table" =~ ^[01]$ ]]; then
      echo "Invalid innodb_file_per_table. Allowed: 0 or 1." >&2
      exit 1
    fi

    read -rp "innodb_flush_method [O_DIRECT/fsync/O_DSYNC] (default: $default_flush_method): " fm_input
    flush_method="${fm_input:-$default_flush_method}"
    flush_method_upper=${flush_method^^}
    case "$flush_method_upper" in
      O_DIRECT|FSYNC|O_DSYNC) ;;
      *)
        echo "Invalid innodb_flush_method. Allowed: O_DIRECT, fsync, O_DSYNC." >&2
        exit 1
        ;;
    esac

    read -rp "innodb_read_io_threads (default: $default_io_threads): " read_io_input
    innodb_read_io_threads="${read_io_input:-$default_io_threads}"
    if ! [[ "$innodb_read_io_threads" =~ ^[0-9]+$ ]] || (( innodb_read_io_threads <= 0 )); then
      echo "Invalid innodb_read_io_threads. Must be a positive integer." >&2
      exit 1
    fi

    read -rp "innodb_write_io_threads (default: $default_io_threads): " write_io_input
    innodb_write_io_threads="${write_io_input:-$default_io_threads}"
    if ! [[ "$innodb_write_io_threads" =~ ^[0-9]+$ ]] || (( innodb_write_io_threads <= 0 )); then
      echo "Invalid innodb_write_io_threads. Must be a positive integer." >&2
      exit 1
    fi

    read -rp "innodb_io_capacity (default: $default_io_capacity): " io_cap_input
    innodb_io_capacity="${io_cap_input:-$default_io_capacity}"
    if ! [[ "$innodb_io_capacity" =~ ^[0-9]+$ ]] || (( innodb_io_capacity <= 0 )); then
      echo "Invalid innodb_io_capacity. Must be a positive integer." >&2
      exit 1
    fi

    read -rp "innodb_io_capacity_max (default: $default_io_capacity_max): " io_cap_max_input
    innodb_io_capacity_max="${io_cap_max_input:-$default_io_capacity_max}"
    if ! [[ "$innodb_io_capacity_max" =~ ^[0-9]+$ ]] || (( innodb_io_capacity_max <= 0 )); then
      echo "Invalid innodb_io_capacity_max. Must be a positive integer." >&2
      exit 1
    fi
    if (( innodb_io_capacity_max < innodb_io_capacity )); then
      echo "innodb_io_capacity_max must be >= innodb_io_capacity." >&2
      exit 1
    fi

    read -rp "innodb_flush_log_at_timeout (default: $default_flush_log_timeout): " flush_timeout_input
    innodb_flush_log_at_timeout="${flush_timeout_input:-$default_flush_log_timeout}"
    if ! [[ "$innodb_flush_log_at_timeout" =~ ^[0-9]+$ ]] || (( innodb_flush_log_at_timeout <= 0 )); then
      echo "Invalid innodb_flush_log_at_timeout. Must be a positive integer." >&2
      exit 1
    fi

    read -rp "innodb_lock_wait_timeout (default: $default_lock_wait_timeout): " lock_timeout_input
    innodb_lock_wait_timeout="${lock_timeout_input:-$default_lock_wait_timeout}"
    if ! [[ "$innodb_lock_wait_timeout" =~ ^[0-9]+$ ]] || (( innodb_lock_wait_timeout <= 0 )); then
      echo "Invalid innodb_lock_wait_timeout. Must be a positive integer." >&2
      exit 1
    fi

    read -rp "innodb_adaptive_hash_index [0/1] (default: $default_adaptive_hash): " ahi_input
    innodb_adaptive_hash_index="${ahi_input:-$default_adaptive_hash}"
    if ! [[ "$innodb_adaptive_hash_index" =~ ^[01]$ ]]; then
      echo "Invalid innodb_adaptive_hash_index. Allowed: 0 or 1." >&2
      exit 1
    fi

    read -rp "innodb_sort_buffer_size (default: $default_sort_buffer_size): " sort_buffer_input
    innodb_sort_buffer_size="${sort_buffer_input:-$default_sort_buffer_size}"
    if ! validate_size_format "$innodb_sort_buffer_size"; then
      echo "Invalid innodb_sort_buffer_size format. Use numbers with optional K/M/G suffix." >&2
      exit 1
    fi

    read -rp "innodb_table_locks [ON/OFF] (default: $default_table_locks): " table_locks_input
    innodb_table_locks="${table_locks_input:-$default_table_locks}"
    innodb_table_locks_upper=${innodb_table_locks^^}
    case "$innodb_table_locks_upper" in
      ON|OFF|1|0) ;;
      *)
        echo "Invalid innodb_table_locks. Allowed: ON, OFF, 1, 0." >&2
        exit 1
        ;;
    esac

    set_config_value innodb_buffer_pool_size "$innodb_buffer_pool_size"
    set_config_value innodb_log_file_size "$innodb_log_file_size"
    set_config_value innodb_flush_log_at_trx_commit "$flush_trx"
    set_config_value innodb_file_per_table "$file_per_table"
    set_config_value innodb_flush_method "$flush_method_upper"
    set_config_value innodb_read_io_threads "$innodb_read_io_threads"
    set_config_value innodb_write_io_threads "$innodb_write_io_threads"
    set_config_value innodb_io_capacity "$innodb_io_capacity"
    set_config_value innodb_io_capacity_max "$innodb_io_capacity_max"
    set_config_value innodb_flush_log_at_timeout "$innodb_flush_log_at_timeout"
    set_config_value innodb_lock_wait_timeout "$innodb_lock_wait_timeout"
    set_config_value innodb_adaptive_hash_index "$innodb_adaptive_hash_index"
    set_config_value innodb_sort_buffer_size "$innodb_sort_buffer_size"
    set_config_value innodb_table_locks "$innodb_table_locks_upper"
    echo "InnoDB parameters configured."
    ;;
  MYISAM)
    set_storage_engine "$engine_choice"
    echo "default_storage_engine set to: $engine_choice"

    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || true)
    if [[ -n "${mem_kb:-}" && "$mem_kb" =~ ^[0-9]+$ ]]; then
      default_key_buffer="$((mem_kb / 4 / 1024))M"
    else
      default_key_buffer="256M"
    fi
    default_read_buffer="128K"
    default_read_rnd_buffer="256K"

    read -rp "key_buffer_size (default: $default_key_buffer): " key_buffer_input
    key_buffer_size="${key_buffer_input:-$default_key_buffer}"
    if ! validate_size_format "$key_buffer_size"; then
      echo "Invalid key_buffer_size format. Use numbers with optional K/M/G suffix." >&2
      exit 1
    fi

    read -rp "read_buffer_size (default: $default_read_buffer): " read_buffer_input
    read_buffer_size="${read_buffer_input:-$default_read_buffer}"
    if ! validate_size_format "$read_buffer_size"; then
      echo "Invalid read_buffer_size format. Use numbers with optional K/M/G suffix." >&2
      exit 1
    fi

    read -rp "read_rnd_buffer_size (default: $default_read_rnd_buffer): " read_rnd_buffer_input
    read_rnd_buffer_size="${read_rnd_buffer_input:-$default_read_rnd_buffer}"
    if ! validate_size_format "$read_rnd_buffer_size"; then
      echo "Invalid read_rnd_buffer_size format. Use numbers with optional K/M/G suffix." >&2
      exit 1
    fi

    set_config_value key_buffer_size "$key_buffer_size"
    set_config_value read_buffer_size "$read_buffer_size"
    set_config_value read_rnd_buffer_size "$read_rnd_buffer_size"
    echo "MyISAM buffers configured: key_buffer_size=$key_buffer_size, read_buffer_size=$read_buffer_size, read_rnd_buffer_size=$read_rnd_buffer_size"
    ;;
  MEMORY)
    set_storage_engine "$engine_choice"
    echo "default_storage_engine set to: $engine_choice"
    ;;
  *)
    echo "Invalid storage engine choice. Allowed: InnoDB, MyISAM, MEMORY." >&2
    exit 1
    ;;
esac

systemctl restart mysql

mysql --version
systemctl is-active --quiet mysql && echo "MySQL is running." || echo "MySQL is not running."
