#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行（例如 sudo $0）" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mysql-server

# 确保 MySQL 开机自启并立即启动
systemctl enable --now mysql

# 若提供 MYSQL_ROOT_PASSWORD 则设置 root 密码
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  mysql --protocol=socket -uroot --execute="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD//\'/'"'"'}'; FLUSH PRIVILEGES;"
  echo "已根据环境变量 MYSQL_ROOT_PASSWORD 设置 root 密码。"
fi

CONFIG_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "未找到 MySQL 配置文件：$CONFIG_FILE" >&2
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

mysql_cli=(mysql --protocol=socket -uroot)
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  mysql_cli+=("-p${MYSQL_ROOT_PASSWORD}")
fi

echo "远程访问配置："
read -rp "是否限制为指定 IP 访问? (y/N): " limit_remote
if [[ "${limit_remote:-}" =~ ^[Yy]$ ]]; then
  read -rp "请输入允许访问的 IP 地址: " allowed_ip
  if [[ -z "${allowed_ip:-}" ]]; then
    echo "未提供 IP，已退出。" >&2
    exit 1
  fi
  set_bind_address "$allowed_ip"
  echo "MySQL 监听地址已设为: $allowed_ip"
else
  set_bind_address "0.0.0.0"
  echo "MySQL 监听地址已设为: 0.0.0.0（不限制 IP）"
fi

CPU_CORES=$(nproc)
MAX_THREAD_CONCURRENCY=$((CPU_CORES * 2))

echo "thread_concurrency 配置："
echo "默认（推荐）：$MAX_THREAD_CONCURRENCY（CPU 核数的 2 倍）。自定义值必须小于 $MAX_THREAD_CONCURRENCY。"
read -rp "请输入 thread_concurrency（< $MAX_THREAD_CONCURRENCY），回车使用默认: " tc_input

if [[ -n "${tc_input:-}" ]]; then
  if ! [[ "$tc_input" =~ ^[0-9]+$ ]]; then
    echo "thread_concurrency 必须是数字。" >&2
    exit 1
  fi
  if (( tc_input <= 0 || tc_input >= MAX_THREAD_CONCURRENCY )); then
    echo "thread_concurrency 需大于 0 且小于 $MAX_THREAD_CONCURRENCY。" >&2
    exit 1
  fi
  thread_concurrency="$tc_input"
else
  thread_concurrency="$MAX_THREAD_CONCURRENCY"
fi

set_thread_concurrency "$thread_concurrency"
echo "thread_concurrency 已设置为: $thread_concurrency"

default_max_connections="200"
open_files_limit_info=$("${mysql_cli[@]}" --silent --skip-column-names --execute "SHOW VARIABLES LIKE 'open_files_limit';" 2>/dev/null | awk 'NR==1{print $2}')
echo "最大连接数配置（过大可能导致内存耗尽；依据 Max_used_connections/max_connections 经验：<10% 可能过大，>85% 需考虑提升）。"
if [[ -n "${open_files_limit_info:-}" ]]; then
  echo "当前 MySQL open_files_limit: $open_files_limit_info（需 >= max_connections）。"
fi
read -rp "请输入 max_connections（默认: $default_max_connections）: " max_conn_input
max_connections="${max_conn_input:-$default_max_connections}"
if ! [[ "$max_connections" =~ ^[0-9]+$ ]] || (( max_connections <= 0 )); then
  echo "max_connections 必须为正整数。" >&2
  exit 1
fi
set_config_value max_connections "$max_connections"
echo "max_connections 已设置为: $max_connections"

cat <<'EOF'
存储引擎选项：
- InnoDB : 支持事务/行级锁/崩溃恢复（推荐）。
- MyISAM : 表级锁，无事务，读性能好。
- MEMORY : 数据存内存，极快但不持久。

存储引擎对比：
功能               MyISAM   MEMORY   InnoDB   Archive
存储限制           265TB    RAM      65TB     无明确限制
支持事务           No       No       Yes      No
支持全文索引       Yes      No       No       No
支持 B-Tree 索引   Yes      Yes      Yes      No
支持哈希索引       No       Yes      No       No
支持数据缓存       No       N/A      Yes      No
支持外键           No       No       Yes      No
EOF

default_engine="InnoDB"
read -rp "请选择存储引擎 [InnoDB/MyISAM/MEMORY]（默认: ${default_engine}）: " engine_input
engine_choice=${engine_input:-$default_engine}
engine_choice=${engine_choice^^}

case "$engine_choice" in
  INNODB)
    set_storage_engine "$engine_choice"
    echo "已选择 InnoDB 引擎，default_storage_engine 已设置。"

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

    echo "InnoDB 参数调优（回车使用默认）："

    read -rp "innodb_buffer_pool_size（建议物理内存的 60%-80%，默认: $default_buffer_pool）: " bp_input
    innodb_buffer_pool_size="${bp_input:-$default_buffer_pool}"
    if ! validate_size_format "$innodb_buffer_pool_size"; then
      echo "innodb_buffer_pool_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    read -rp "innodb_log_file_size（典型 256M-1G，默认: $default_log_file_size）: " log_input
    innodb_log_file_size="${log_input:-$default_log_file_size}"
    if ! validate_size_format "$innodb_log_file_size"; then
      echo "innodb_log_file_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    read -rp "innodb_flush_log_at_trx_commit [0/1/2]（默认: $default_flush_at_trx_commit）: " flush_trx_input
    flush_trx="${flush_trx_input:-$default_flush_at_trx_commit}"
    if ! [[ "$flush_trx" =~ ^[0-2]$ ]]; then
      echo "innodb_flush_log_at_trx_commit 只能为 0/1/2。" >&2
      exit 1
    fi

    read -rp "innodb_file_per_table [0/1]（默认: $default_file_per_table）: " fpt_input
    file_per_table="${fpt_input:-$default_file_per_table}"
    if ! [[ "$file_per_table" =~ ^[01]$ ]]; then
      echo "innodb_file_per_table 只能为 0 或 1。" >&2
      exit 1
    fi

    read -rp "innodb_flush_method [O_DIRECT/fsync/O_DSYNC]（默认: $default_flush_method）: " fm_input
    flush_method="${fm_input:-$default_flush_method}"
    flush_method_upper=${flush_method^^}
    case "$flush_method_upper" in
      O_DIRECT|FSYNC|O_DSYNC) ;;
      *)
        echo "innodb_flush_method 只能为 O_DIRECT、fsync、O_DSYNC。" >&2
        exit 1
        ;;
    esac

    read -rp "innodb_read_io_threads（默认: $default_io_threads）: " read_io_input
    innodb_read_io_threads="${read_io_input:-$default_io_threads}"
    if ! [[ "$innodb_read_io_threads" =~ ^[0-9]+$ ]] || (( innodb_read_io_threads <= 0 )); then
      echo "innodb_read_io_threads 必须为正整数。" >&2
      exit 1
    fi

    read -rp "innodb_write_io_threads（默认: $default_io_threads）: " write_io_input
    innodb_write_io_threads="${write_io_input:-$default_io_threads}"
    if ! [[ "$innodb_write_io_threads" =~ ^[0-9]+$ ]] || (( innodb_write_io_threads <= 0 )); then
      echo "innodb_write_io_threads 必须为正整数。" >&2
      exit 1
    fi

    read -rp "innodb_io_capacity（默认: $default_io_capacity）: " io_cap_input
    innodb_io_capacity="${io_cap_input:-$default_io_capacity}"
    if ! [[ "$innodb_io_capacity" =~ ^[0-9]+$ ]] || (( innodb_io_capacity <= 0 )); then
      echo "innodb_io_capacity 必须为正整数。" >&2
      exit 1
    fi

    read -rp "innodb_io_capacity_max（默认: $default_io_capacity_max）: " io_cap_max_input
    innodb_io_capacity_max="${io_cap_max_input:-$default_io_capacity_max}"
    if ! [[ "$innodb_io_capacity_max" =~ ^[0-9]+$ ]] || (( innodb_io_capacity_max <= 0 )); then
      echo "innodb_io_capacity_max 必须为正整数。" >&2
      exit 1
    fi
    if (( innodb_io_capacity_max < innodb_io_capacity )); then
      echo "innodb_io_capacity_max 必须大于等于 innodb_io_capacity。" >&2
      exit 1
    fi

    read -rp "innodb_flush_log_at_timeout（默认: $default_flush_log_timeout）: " flush_timeout_input
    innodb_flush_log_at_timeout="${flush_timeout_input:-$default_flush_log_timeout}"
    if ! [[ "$innodb_flush_log_at_timeout" =~ ^[0-9]+$ ]] || (( innodb_flush_log_at_timeout <= 0 )); then
      echo "innodb_flush_log_at_timeout 必须为正整数。" >&2
      exit 1
    fi

    read -rp "innodb_lock_wait_timeout（默认: $default_lock_wait_timeout）: " lock_timeout_input
    innodb_lock_wait_timeout="${lock_timeout_input:-$default_lock_wait_timeout}"
    if ! [[ "$innodb_lock_wait_timeout" =~ ^[0-9]+$ ]] || (( innodb_lock_wait_timeout <= 0 )); then
      echo "innodb_lock_wait_timeout 必须为正整数。" >&2
      exit 1
    fi

    read -rp "innodb_adaptive_hash_index [0/1]（默认: $default_adaptive_hash）: " ahi_input
    innodb_adaptive_hash_index="${ahi_input:-$default_adaptive_hash}"
    if ! [[ "$innodb_adaptive_hash_index" =~ ^[01]$ ]]; then
      echo "innodb_adaptive_hash_index 只能为 0 或 1。" >&2
      exit 1
    fi

    read -rp "innodb_sort_buffer_size（默认: $default_sort_buffer_size）: " sort_buffer_input
    innodb_sort_buffer_size="${sort_buffer_input:-$default_sort_buffer_size}"
    if ! validate_size_format "$innodb_sort_buffer_size"; then
      echo "innodb_sort_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    read -rp "innodb_table_locks [ON/OFF]（默认: $default_table_locks）: " table_locks_input
    innodb_table_locks="${table_locks_input:-$default_table_locks}"
    innodb_table_locks_upper=${innodb_table_locks^^}
    case "$innodb_table_locks_upper" in
      ON|OFF|1|0) ;;
      *)
        echo "innodb_table_locks 只能为 ON/OFF/1/0。" >&2
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
    echo "InnoDB 参数已配置。"
    ;;
  MYISAM)
    set_storage_engine "$engine_choice"
    echo "已选择 MyISAM 引擎，default_storage_engine 已设置。"

    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || true)
    if [[ -n "${mem_kb:-}" && "$mem_kb" =~ ^[0-9]+$ ]]; then
      default_key_buffer="$((mem_kb / 4 / 1024))M"
    else
      default_key_buffer="256M"
    fi
    default_read_buffer="128K"
    default_read_rnd_buffer="256K"

    read -rp "key_buffer_size（默认: $default_key_buffer）：建议约可用内存的 1/4: " key_buffer_input
    key_buffer_size="${key_buffer_input:-$default_key_buffer}"
    if ! validate_size_format "$key_buffer_size"; then
      echo "key_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    read -rp "read_buffer_size（默认: $default_read_buffer）: " read_buffer_input
    read_buffer_size="${read_buffer_input:-$default_read_buffer}"
    if ! validate_size_format "$read_buffer_size"; then
      echo "read_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    read -rp "read_rnd_buffer_size（默认: $default_read_rnd_buffer）: " read_rnd_buffer_input
    read_rnd_buffer_size="${read_rnd_buffer_input:-$default_read_rnd_buffer}"
    if ! validate_size_format "$read_rnd_buffer_size"; then
      echo "read_rnd_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    set_config_value key_buffer_size "$key_buffer_size"
    set_config_value read_buffer_size "$read_buffer_size"
    set_config_value read_rnd_buffer_size "$read_rnd_buffer_size"
    echo "MyISAM 缓冲区已配置: key_buffer_size=$key_buffer_size, read_buffer_size=$read_buffer_size, read_rnd_buffer_size=$read_rnd_buffer_size"
    ;;
  MEMORY)
    set_storage_engine "$engine_choice"
    echo "已选择 MEMORY 引擎，default_storage_engine 已设置。"

    default_max_heap="64M"
    default_tmp_table="64M"

    echo "MEMORY 引擎参数（建议 max_heap_table_size 与 tmp_table_size 保持一致，避免临时表落盘）："

    read -rp "max_heap_table_size（每张 MEMORY 表上限，默认: $default_max_heap）: " max_heap_input
    max_heap_table_size="${max_heap_input:-$default_max_heap}"
    if ! validate_size_format "$max_heap_table_size"; then
      echo "max_heap_table_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    read -rp "tmp_table_size（内部内存临时表上限，默认: $default_tmp_table）: " tmp_table_input
    tmp_table_size="${tmp_table_input:-$default_tmp_table}"
    if ! validate_size_format "$tmp_table_size"; then
      echo "tmp_table_size 格式无效，请用数字加可选 K/M/G 后缀。" >&2
      exit 1
    fi

    set_config_value max_heap_table_size "$max_heap_table_size"
    set_config_value tmp_table_size "$tmp_table_size"
    echo "MEMORY 参数已配置: max_heap_table_size=$max_heap_table_size, tmp_table_size=$tmp_table_size"
    ;;
  *)
    echo "存储引擎选择无效。可选: InnoDB, MyISAM, MEMORY。" >&2
    exit 1
    ;;
esac

echo "root 远程登录配置："
read -rp "是否允许 root 远程登录（host=%）? (y/N): " allow_root_remote
if [[ "${allow_root_remote:-}" =~ ^[Yy]$ ]]; then
  root_remote_pwd="${MYSQL_ROOT_PASSWORD:-}"
  if [[ -z "$root_remote_pwd" ]]; then
    read -rsp "请输入 root 密码（远程登录必填）: " root_remote_pwd
    echo
    if [[ -z "$root_remote_pwd" ]]; then
      echo "未提供 root 密码，无法配置远程登录。" >&2
      exit 1
    fi
  fi
  root_remote_pwd_escaped=${root_remote_pwd//\'/'"'"'}
  "${mysql_cli[@]}" --execute="CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$root_remote_pwd_escaped'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  echo "已允许 root 远程登录（host=%）。"
else
  root_local_pwd="${MYSQL_ROOT_PASSWORD:-}"
  if [[ -z "$root_local_pwd" ]]; then
    read -rsp "是否为 root 设置/更新密码（回车跳过保留当前）: " root_local_pwd
    echo
  fi
  root_local_clause=""
  if [[ -n "$root_local_pwd" ]]; then
    root_local_pwd_escaped=${root_local_pwd//\'/'"'"'}
    root_local_clause=" IDENTIFIED WITH mysql_native_password BY '$root_local_pwd_escaped'"
  fi
  "${mysql_cli[@]}" --execute="DROP USER IF EXISTS 'root'@'%'; CREATE USER IF NOT EXISTS 'root'@'localhost'${root_local_clause}; GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  echo "已限制 root 仅本地登录（host=localhost）。"
fi

read -rp "是否创建额外用户? (y/N): " create_extra_user
if [[ "${create_extra_user:-}" =~ ^[Yy]$ ]]; then
  read -rp "请输入新用户名: " new_user
  if [[ -z "${new_user:-}" ]]; then
    echo "未提供用户名，已退出。" >&2
    exit 1
  fi
  read -rsp "请输入新用户密码: " new_user_pwd
  echo
  if [[ -z "${new_user_pwd:-}" ]]; then
    echo "未提供密码，已退出。" >&2
    exit 1
  fi
  read -rp "新用户可访问的主机（默认 %）: " new_user_host
  new_user_host=${new_user_host:-%}
  new_user_pwd_escaped=${new_user_pwd//\'/'"'"'}
  "${mysql_cli[@]}" --execute="CREATE USER IF NOT EXISTS '$new_user'@'$new_user_host' IDENTIFIED WITH mysql_native_password BY '$new_user_pwd_escaped'; GRANT ALL PRIVILEGES ON *.* TO '$new_user'@'$new_user_host'; FLUSH PRIVILEGES;"
  echo "已创建用户 $new_user@$new_user_host 并授予权限。"
fi

systemctl restart mysql

mysql --version
systemctl is-active --quiet mysql && echo "MySQL 已运行。" || echo "MySQL 未运行。"
