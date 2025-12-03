# ============================================================
#  说明: MySQL/MariaDB 自动安装配置脚本
#  作者: RobertHU 
#  日期: 2023-05-09
#
#  用法: sudo ./install_mysql.sh
#        或设置环境变量: MYSQL_ROOT_PASSWORD="pwd" sudo ./install_mysql.sh
#
#  支持的 Linux 发行版:
#    - Ubuntu 18.04 / 20.04 / 22.04 / 24.04 LTS
#    - Debian 10 (Buster) / 11 (Bullseye) / 12 (Bookworm)
#    - CentOS 7 / 8 / Stream 8 / Stream 9
#    - RHEL 7 / 8 / 9 / 10
#    - Rocky Linux 8 / 9 / 10
#    - AlmaLinux 8 / 9
#
#  支持的数据库版本:
#    - MySQL 5.7.x / 8.0.x / 8.4.x
#    - MariaDB 10.3.x / 10.5.x / 10.6.x / 10.11.x / 11.x
#
#  配置流程:
#    1/7 - 环境检测与安装: 检测包管理器，安装 MySQL/MariaDB
#    2/7 - 服务检测与启动: 检测服务名(mysql/mysqld/mariadb)，启动服务
#    3/7 - 网络访问配置: 设置 bind-address(本地/远程访问)
#    4/7 - 性能参数配置: max_connections 等
#    5/7 - 存储引擎配置: InnoDB/MyISAM/MEMORY 引擎及其参数
#    6/7 - 用户权限配置: root 访问权限、额外用户创建
#    7/7 - 完成与验证: 重启服务，显示配置摘要
# ============================================================

#!/usr/bin/env bash
# 严格模式: -e 错误退出 | -u 未定义变量报错 | -o pipefail 管道失败传递
set -euo pipefail

# ---------------------- 终端颜色定义 ----------------------
# 用于美化输出，区分不同类型的信息
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color - 重置颜色

# ---------------------- 全局变量声明 ----------------------
# 包管理器相关
PKG_MGR=""                    # 包管理器类型: apt/dnf/yum
UPDATE_CMD=""                 # 更新缓存命令
INSTALL_CMD=""                # 安装包命令

# 服务相关
MYSQL_SERVICE="mysql"         # 服务名: mysql/mysqld/mariadb
CONFIG_FILE=""                # 配置文件路径

# MySQL 客户端连接
mysql_cli=()                  # mysql 命令行数组

# 系统信息
CPU_CORES=0                   # CPU 核数

# 用户输入变量
max_connections=""            # 最大连接数
engine_choice=""              # 存储引擎选择

# 默认值常量
readonly DEFAULT_MAX_CONNECTIONS="200"
readonly DEFAULT_ENGINE="InnoDB"
readonly DEFAULT_MAX_HEAP="64M"
readonly DEFAULT_TMP_TABLE="64M"
readonly DEFAULT_READ_BUFFER="128K"
readonly DEFAULT_READ_RND_BUFFER="256K"
readonly DEFAULT_FLUSH_AT_TRX_COMMIT="1"
readonly DEFAULT_FILE_PER_TABLE="1"
readonly DEFAULT_FLUSH_METHOD="O_DIRECT"
readonly DEFAULT_IO_CAPACITY="200"
readonly DEFAULT_IO_CAPACITY_MAX="2000"
readonly DEFAULT_LOCK_WAIT_TIMEOUT="50"
readonly DEFAULT_SORT_BUFFER_SIZE="256M"

# ---------------------- 输出辅助函数 ----------------------

# 打印分隔线和标题
print_section() {
  local title="$1"
  echo
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $title${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo
}

print_subsection() {
  local title="$1"
  echo
  echo -e "${YELLOW}───────────────────────────────────────${NC}"
  echo -e "${YELLOW}  $title${NC}"
  echo -e "${YELLOW}───────────────────────────────────────${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}" >&2
}

# ---------------------- 权限检查 ----------------------
# 该脚本需要 root 权限执行

if [[ $EUID -ne 0 ]]; then
  print_error "请使用 root 运行[例如 sudo $0]"
  exit 1
fi

print_section "1/7 环境检测与安装"

# ---------------------- 包管理器检测 ----------------------

if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
  UPDATE_CMD="apt-get update -y"
  INSTALL_CMD="apt-get install -y"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
  UPDATE_CMD="dnf makecache -y"
  INSTALL_CMD="dnf install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
  UPDATE_CMD="yum makecache -y"
  INSTALL_CMD="yum install -y"
else
  print_error "未检测到受支持的包管理器[apt/dnf/yum]，请手动安装 MySQL。"
  exit 1
fi


# ---------------------- 核心函数定义 ----------------------

# install_mysql: 根据包管理器安装 MySQL/MariaDB
# - apt 系统: 安装 mysql-server
# - dnf/yum 系统: 优先尝试 mysql-server，失败则安装 mariadb-server
install_mysql() {
  if [[ "$PKG_MGR" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    bash -c "$UPDATE_CMD"
    bash -c "$INSTALL_CMD mysql-server"
  else
    bash -c "$UPDATE_CMD"
    bash -c "$INSTALL_CMD mysql-server" || bash -c "$INSTALL_CMD mariadb-server"
  fi
}

# choose_config_file: 查找并设置 MySQL 配置文件路径
# 优先级: /etc/mysql/mysql.conf.d/mysqld.cnf > /etc/my.cnf > /etc/mysql/my.cnf
choose_config_file() {
  for f in /etc/mysql/mysql.conf.d/mysqld.cnf /etc/my.cnf /etc/mysql/my.cnf; do
    if [[ -f "$f" ]]; then
      CONFIG_FILE="$f"
      return
    fi
  done
  CONFIG_FILE="/etc/my.cnf"
  touch "$CONFIG_FILE"
  echo "[mysqld]" >> "$CONFIG_FILE"
}

# ensure_mysqld_section: 确保配置文件中存在 [mysqld] 段
ensure_mysqld_section() {
  if ! grep -Eq '^\[mysqld\]' "$CONFIG_FILE"; then
    printf "\n[mysqld]\n" >> "$CONFIG_FILE"
  fi
}

# set_config_value: 设置或更新 MySQL 配置参数
# 参数: $1=配置项名称, $2=配置值
# 如果配置已存在则更新，否则追加到文件末尾
set_config_value() {
  local key="$1"
  local value="$2"
  ensure_mysqld_section
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
    sed -i "s/^[#[:space:]]*${key}[[:space:]]*=.*/${key} = ${value}/" "$CONFIG_FILE"
  else
    printf "%s = %s\n" "$key" "$value" >> "$CONFIG_FILE"
  fi
}

# escape_sql: SQL 字符串转义，将单引号转为两个单引号
# 防止 SQL 注入
escape_sql() {
  local input="$1"
  printf "%s" "${input//\'/\'\'}"
}

# validate_size_format: 验证内存/存储大小格式
# 支持格式: 数字 + 可选后缀(K/M/G)
# 示例: 128M, 1G, 256K, 1024
validate_size_format() {
  local size="$1"
  [[ "$size" =~ ^[0-9]+[KkMmGg]?$ ]]
}

# 执行安装并选择配置文件
print_info "正在安装 MySQL/MariaDB..."
install_mysql
choose_config_file
print_success "安装完成，配置文件: $CONFIG_FILE"

print_section "2/7 服务检测与启动"

# ---------------------- 服务名检测 ----------------------
# 不同系统的服务名可能不同:
# - mysql.service: Debian/Ubuntu 的 MySQL
# - mysqld.service: RHEL/CentOS 的 MySQL
# - mariadb.service: MariaDB (常见于 RHEL 系统)

# 刷新 systemd 以识别新安装的服务
systemctl daemon-reload 2>/dev/null || true

if systemctl list-unit-files 2>/dev/null | grep -q 'mariadb.service'; then
  MYSQL_SERVICE="mariadb"
elif systemctl list-unit-files 2>/dev/null | grep -q 'mysqld.service'; then
  MYSQL_SERVICE="mysqld"
elif systemctl list-unit-files 2>/dev/null | grep -q 'mysql.service'; then
  MYSQL_SERVICE="mysql"
else
  # 备用检测：直接检查服务文件
  if [[ -f /usr/lib/systemd/system/mariadb.service ]] || [[ -f /etc/systemd/system/mariadb.service ]]; then
    MYSQL_SERVICE="mariadb"
  elif [[ -f /usr/lib/systemd/system/mysqld.service ]] || [[ -f /etc/systemd/system/mysqld.service ]]; then
    MYSQL_SERVICE="mysqld"
  fi
fi

print_info "检测到服务名: $MYSQL_SERVICE"

# 确保 MySQL 开机自启并立即启动
systemctl enable --now "$MYSQL_SERVICE"
print_success "服务已启动并设置开机自启"

# ---------------------- Root 密码设置 ----------------------
# 如果设置了 MYSQL_ROOT_PASSWORD 环境变量，则使用该密码更新 root
# 若提供 MYSQL_ROOT_PASSWORD 则设置/更新 root 密码
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  mysql --protocol=socket -uroot --execute="ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD//\'/\'\'}'; FLUSH PRIVILEGES;" || true
  print_success "已根据环境变量 MYSQL_ROOT_PASSWORD 设置/更新 root 密码"
fi

# 构建 mysql 命令行数组，用于后续 SQL 操作
mysql_cli=(mysql --protocol=socket -uroot)

mysql_cli=(mysql --protocol=socket -uroot)
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  mysql_cli+=("-p${MYSQL_ROOT_PASSWORD}")
fi

# 连接失败则提示输入密码
if ! "${mysql_cli[@]}" --execute "SELECT 1" >/dev/null 2>&1; then
  read -rsp "请输入 MySQL root 密码[若已免密可直接回车]: " root_pwd
  echo
  if [[ -n "$root_pwd" ]]; then
    mysql_cli=(mysql --protocol=socket -uroot "-p${root_pwd}")
  fi
fi

# ---------------------- 配置辅助函数 ----------------------

# set_bind_address: 设置 MySQL 绑定地址
# - 127.0.0.1: 仅本地访问
# - 0.0.0.0: 允许所有 IP 访问
# - 指定 IP: 仅允许该 IP 访问
set_bind_address() {
  local ip="$1"
  set_config_value bind-address "$ip"
}

# set_storage_engine: 设置默认存储引擎
# 可选: InnoDB(推荐), MyISAM, MEMORY
set_storage_engine() {
  local engine="$1"
  set_config_value default_storage_engine "$engine"
}

print_section "3/7 网络访问配置"

# ---------------------- 绑定地址配置 ----------------------
# 设置 MySQL 监听的网络接口
# - 限制 IP: 只允许指定 IP 访问
# - 不限制: 允许所有 IP 访问(0.0.0.0)

# 远程访问 - 对于 apt 系统，需额外禁用 MySQL X Protocol
if [[ "$PKG_MGR" == "apt" ]]; then
  set_config_value mysqlx-bind-address 127.0.0.1 || true
fi

print_subsection "绑定地址设置"
read -rp "是否限制为指定 IP 访问? (y/N): " limit_remote
if [[ "${limit_remote:-}" =~ ^[Yy]$ ]]; then
  read -rp "请输入允许访问的 IP 地址: " allowed_ip
  if [[ -z "${allowed_ip:-}" ]]; then
    print_error "未提供 IP，已退出。"
    exit 1
  fi
  set_bind_address "$allowed_ip"
  print_success "MySQL 监听地址已设为: $allowed_ip"
else
  set_bind_address "0.0.0.0"
  print_success "MySQL 监听地址已设为: 0.0.0.0 (不限制 IP)"
fi

print_section "4/7 性能参数配置"

# 获取 CPU 核数（用于计算 IO 线程默认值）
CPU_CORES=$(nproc)

# ---------------------- 最大连接数配置 ----------------------
# max_connections: 同时允许的最大客户端连接数
# 注意: 过大可能导致内存耗尽
# 经验值:
#   - Max_used_connections/max_connections < 10% : 可能设置过大
#   - Max_used_connections/max_connections > 85% : 需要提升
print_subsection "最大连接数配置"

open_files_limit_info=$("${mysql_cli[@]}" --silent --skip-column-names --execute "SHOW VARIABLES LIKE 'open_files_limit';" 2>/dev/null | awk 'NR==1{print $2}')
echo "最大连接数配置[过大可能导致内存耗尽；经验：Max_used_connections/max_connections <10% 可能过大，>85% 需考虑提升]。"
if [[ -n "${open_files_limit_info:-}" ]]; then
  echo "当前 MySQL open_files_limit: $open_files_limit_info[需 >= max_connections]。"
fi
read -rp "请输入 max_connections[默认: $DEFAULT_MAX_CONNECTIONS]: " max_conn_input
max_connections="${max_conn_input:-$DEFAULT_MAX_CONNECTIONS}"
if ! [[ "$max_connections" =~ ^[0-9]+$ ]] || (( max_connections <= 0 )); then
  print_error "max_connections 必须为正整数。"
  exit 1
fi
set_config_value max_connections "$max_connections"
print_success "max_connections 已设置为: $max_connections"

print_section "5/7 存储引擎配置"

# ---------------------- 存储引擎选择 ----------------------
cat <<'EOF'
存储引擎选项：
- InnoDB : 支持事务/行级锁/崩溃恢复[推荐]。
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

read -rp "请选择存储引擎 [InnoDB/MyISAM/MEMORY][默认: ${DEFAULT_ENGINE}]: " engine_input
engine_choice=${engine_input:-$DEFAULT_ENGINE}
engine_choice=${engine_choice^^}

case "$engine_choice" in
  INNODB)
    set_storage_engine "$engine_choice"
    print_success "已选择 InnoDB 引擎"

    print_subsection "InnoDB 参数调优"

    # 计算动态默认值
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || true)
    if [[ -n "${mem_kb:-}" && "$mem_kb" =~ ^[0-9]+$ ]]; then
      default_buffer_pool="$((mem_kb * 75 / 100 / 1024))M"
    else
      default_buffer_pool="1G"
    fi
    if [[ "${CPU_CORES:-}" =~ ^[0-9]+$ && "$CPU_CORES" -gt 0 ]]; then
      default_io_threads=$(( CPU_CORES > 4 ? CPU_CORES : 4 ))
    else
      default_io_threads=4
    fi

    print_info "回车使用默认值"
    echo

    read -rp "innodb_buffer_pool_size[建议物理内存的 60%-80%，默认: $default_buffer_pool]: " bp_input
    innodb_buffer_pool_size="${bp_input:-$default_buffer_pool}"
    if ! validate_size_format "$innodb_buffer_pool_size"; then
      print_error "innodb_buffer_pool_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    read -rp "innodb_flush_log_at_trx_commit [0/1/2][默认: $DEFAULT_FLUSH_AT_TRX_COMMIT]: " flush_trx_input
    flush_trx="${flush_trx_input:-$DEFAULT_FLUSH_AT_TRX_COMMIT}"
    if ! [[ "$flush_trx" =~ ^[0-2]$ ]]; then
      print_error "innodb_flush_log_at_trx_commit 只能为 0/1/2。"
      exit 1
    fi

    read -rp "innodb_file_per_table [0/1][默认: $DEFAULT_FILE_PER_TABLE]: " fpt_input
    file_per_table="${fpt_input:-$DEFAULT_FILE_PER_TABLE}"
    if ! [[ "$file_per_table" =~ ^[01]$ ]]; then
      print_error "innodb_file_per_table 只能为 0 或 1。"
      exit 1
    fi

    read -rp "innodb_flush_method [O_DIRECT/fsync/O_DSYNC][默认: $DEFAULT_FLUSH_METHOD]: " fm_input
    flush_method="${fm_input:-$DEFAULT_FLUSH_METHOD}"
    flush_method_upper=${flush_method^^}
    case "$flush_method_upper" in
      O_DIRECT|FSYNC|O_DSYNC) ;;
      *)
        print_error "innodb_flush_method 只能为 O_DIRECT、fsync、O_DSYNC。"
        exit 1
        ;;
    esac

    # IO 线程数
    read -rp "innodb_read_io_threads[默认: $default_io_threads]: " read_io_input
    innodb_read_io_threads="${read_io_input:-$default_io_threads}"
    if ! [[ "$innodb_read_io_threads" =~ ^[0-9]+$ ]] || (( innodb_read_io_threads <= 0 )); then
      print_error "innodb_read_io_threads 必须为正整数。"
      exit 1
    fi

    read -rp "innodb_write_io_threads[默认: $default_io_threads]: " write_io_input
    innodb_write_io_threads="${write_io_input:-$default_io_threads}"
    if ! [[ "$innodb_write_io_threads" =~ ^[0-9]+$ ]] || (( innodb_write_io_threads <= 0 )); then
      print_error "innodb_write_io_threads 必须为正整数。"
      exit 1
    fi

    read -rp "innodb_io_capacity[默认: $DEFAULT_IO_CAPACITY]: " io_cap_input
    innodb_io_capacity="${io_cap_input:-$DEFAULT_IO_CAPACITY}"
    if ! [[ "$innodb_io_capacity" =~ ^[0-9]+$ ]] || (( innodb_io_capacity <= 0 )); then
      print_error "innodb_io_capacity 必须为正整数。"
      exit 1
    fi

    read -rp "innodb_io_capacity_max[默认: $DEFAULT_IO_CAPACITY_MAX]: " io_cap_max_input
    innodb_io_capacity_max="${io_cap_max_input:-$DEFAULT_IO_CAPACITY_MAX}"
    if ! [[ "$innodb_io_capacity_max" =~ ^[0-9]+$ ]] || (( innodb_io_capacity_max <= 0 )); then
      print_error "innodb_io_capacity_max 必须为正整数。"
      exit 1
    fi
    if (( innodb_io_capacity_max < innodb_io_capacity )); then
      print_error "innodb_io_capacity_max 必须大于等于 innodb_io_capacity。"
      exit 1
    fi

    read -rp "innodb_lock_wait_timeout[默认: $DEFAULT_LOCK_WAIT_TIMEOUT]: " lock_timeout_input
    innodb_lock_wait_timeout="${lock_timeout_input:-$DEFAULT_LOCK_WAIT_TIMEOUT}"
    if ! [[ "$innodb_lock_wait_timeout" =~ ^[0-9]+$ ]] || (( innodb_lock_wait_timeout <= 0 )); then
      print_error "innodb_lock_wait_timeout 必须为正整数。"
      exit 1
    fi

    read -rp "sort_buffer_size[默认: $DEFAULT_SORT_BUFFER_SIZE]: " sort_buffer_input
    innodb_sort_buffer_size="${sort_buffer_input:-$DEFAULT_SORT_BUFFER_SIZE}"
    if ! validate_size_format "$innodb_sort_buffer_size"; then
      print_error "innodb_sort_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    # 应用 InnoDB 配置
    set_config_value innodb_buffer_pool_size "$innodb_buffer_pool_size"
    set_config_value innodb_flush_log_at_trx_commit "$flush_trx"
    set_config_value innodb_file_per_table "$file_per_table"
    set_config_value innodb_flush_method "$flush_method_upper"
    set_config_value innodb_read_io_threads "$innodb_read_io_threads"
    set_config_value innodb_write_io_threads "$innodb_write_io_threads"
    set_config_value innodb_io_capacity "$innodb_io_capacity"
    set_config_value innodb_io_capacity_max "$innodb_io_capacity_max"
    set_config_value innodb_lock_wait_timeout "$innodb_lock_wait_timeout"
    set_config_value sort_buffer_size "$innodb_sort_buffer_size"
    print_success "InnoDB 参数配置完成"
    ;;
  MYISAM)
    set_storage_engine "$engine_choice"
    print_success "已选择 MyISAM 引擎"

    # -------------------- MyISAM 参数调优 --------------------
    print_subsection "MyISAM 参数调优"

    # 计算动态默认值
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || true)
    if [[ -n "${mem_kb:-}" && "$mem_kb" =~ ^[0-9]+$ ]]; then
      default_key_buffer="$((mem_kb / 4 / 1024))M"
    else
      default_key_buffer="256M"
    fi

    read -rp "key_buffer_size[默认: $default_key_buffer]：建议约可用内存的 1/4: " key_buffer_input
    key_buffer_size="${key_buffer_input:-$default_key_buffer}"
    if ! validate_size_format "$key_buffer_size"; then
      print_error "key_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    read -rp "read_buffer_size[默认: $DEFAULT_READ_BUFFER]: " read_buffer_input
    read_buffer_size="${read_buffer_input:-$DEFAULT_READ_BUFFER}"
    if ! validate_size_format "$read_buffer_size"; then
      print_error "read_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    read -rp "read_rnd_buffer_size[默认: $DEFAULT_READ_RND_BUFFER]: " read_rnd_buffer_input
    read_rnd_buffer_size="${read_rnd_buffer_input:-$DEFAULT_READ_RND_BUFFER}"
    if ! validate_size_format "$read_rnd_buffer_size"; then
      print_error "read_rnd_buffer_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    set_config_value key_buffer_size "$key_buffer_size"
    set_config_value read_buffer_size "$read_buffer_size"
    set_config_value read_rnd_buffer_size "$read_rnd_buffer_size"
    print_success "MyISAM 参数配置完成"
    ;;
  MEMORY)
    set_storage_engine "$engine_choice"
    print_success "已选择 MEMORY 引擎"

    # -------------------- MEMORY 参数调优 --------------------
    print_subsection "MEMORY 参数调优"

    print_info "建议 max_heap_table_size 与 tmp_table_size 保持一致，避免临时表落盘"
    echo

    read -rp "max_heap_table_size[每张 MEMORY 表上限，默认: $DEFAULT_MAX_HEAP]: " max_heap_input
    max_heap_table_size="${max_heap_input:-$DEFAULT_MAX_HEAP}"
    if ! validate_size_format "$max_heap_table_size"; then
      print_error "max_heap_table_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    read -rp "tmp_table_size[内部内存临时表上限，默认: $DEFAULT_TMP_TABLE]: " tmp_table_input
    tmp_table_size="${tmp_table_input:-$DEFAULT_TMP_TABLE}"
    if ! validate_size_format "$tmp_table_size"; then
      print_error "tmp_table_size 格式无效，请用数字加可选 K/M/G 后缀。"
      exit 1
    fi

    set_config_value max_heap_table_size "$max_heap_table_size"
    set_config_value tmp_table_size "$tmp_table_size"
    print_success "MEMORY 参数配置完成"
    ;;
  *)
    print_error "存储引擎选择无效。可选: InnoDB, MyISAM, MEMORY。"
    exit 1
    ;;
esac

print_section "6/7 用户权限配置"

# ---------------------- Root 用户访问配置 ----------------------
# 远程登录: 创建 root@'%' 并同步更新 root@'localhost' 密码
# 仅本地: 删除 root@'%'，保留 root@'localhost'
print_subsection "Root 用户访问配置"
read -rp "是否允许 root 远程登录[host=%]? (y/N): " allow_root_remote
if [[ "${allow_root_remote:-}" =~ ^[Yy]$ ]]; then
  root_remote_pwd="${MYSQL_ROOT_PASSWORD:-}"
  if [[ -z "$root_remote_pwd" ]]; then
    read -rsp "请输入 root 密码[远程登录必填]: " root_remote_pwd
    echo
    if [[ -z "$root_remote_pwd" ]]; then
      print_error "未提供 root 密码，无法配置远程登录。"
      exit 1
    fi
  fi
  root_remote_pwd_escaped=${root_remote_pwd//\'/\'\'}
  "${mysql_cli[@]}" --execute="CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$root_remote_pwd_escaped'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  "${mysql_cli[@]}" --execute="ALTER USER 'root'@'localhost' IDENTIFIED BY '$root_remote_pwd_escaped'; FLUSH PRIVILEGES;"
  print_success "已允许 root 远程登录 [host=%]"
  print_info "root@localhost 密码已同步更新为远程登录密码"
else
  root_local_pwd="${MYSQL_ROOT_PASSWORD:-}"
  if [[ -z "$root_local_pwd" ]]; then
    read -rsp "是否为 root 设置/更新密码[回车跳过保留当前]: " root_local_pwd
    echo
  fi
  root_local_clause=""
  if [[ -n "$root_local_pwd" ]]; then
    root_local_pwd_escaped=${root_local_pwd//\'/\'\'}
    root_local_clause=" IDENTIFIED BY '$root_local_pwd_escaped'"
  fi
  "${mysql_cli[@]}" --execute="DROP USER IF EXISTS 'root'@'%'; CREATE USER IF NOT EXISTS 'root'@'localhost'${root_local_clause}; GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost'; FLUSH PRIVILEGES;"
  print_success "已限制 root 仅本地登录 [host=localhost]"
fi

# ---------------------- 额外用户创建 ----------------------
# 可选: 创建具有全部权限的额外用户
print_subsection "额外用户配置"
read -rp "是否创建额外用户? (y/N): " create_extra_user
if [[ "${create_extra_user:-}" =~ ^[Yy]$ ]]; then
  read -rp "请输入新用户名: " new_user
  if [[ -z "${new_user:-}" ]]; then
    print_error "未提供用户名，已退出。"
    exit 1
  fi
  read -rsp "请输入新用户密码: " new_user_pwd
  echo
  if [[ -z "${new_user_pwd:-}" ]]; then
    print_error "未提供密码，已退出。"
    exit 1
  fi
  read -rp "新用户可访问的主机[默认 %]: " new_user_host
  new_user_host=${new_user_host:-%}
  new_user_pwd_escaped=${new_user_pwd//\'/\'\'}
  "${mysql_cli[@]}" --execute="CREATE USER IF NOT EXISTS '$new_user'@'$new_user_host' IDENTIFIED BY '$new_user_pwd_escaped'; GRANT ALL PRIVILEGES ON *.* TO '$new_user'@'$new_user_host'; FLUSH PRIVILEGES;"
  print_success "已创建用户 $new_user@$new_user_host 并授予权限"
fi

print_section "7/7 完成与验证"

# ---------------------- 重启服务并验证 ----------------------
# 应用所有配置更改并显示最终状态
print_info "正在重启服务..."
systemctl restart "$MYSQL_SERVICE"

echo
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│                     安装配置完成                             │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "服务名" "$MYSQL_SERVICE"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "配置文件" "$CONFIG_FILE"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "存储引擎" "$engine_choice"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "最大连接数" "$max_connections"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "版本" "$(mysql --version 2>/dev/null | head -1)"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
if systemctl is-active --quiet "$MYSQL_SERVICE"; then
  echo -e "${CYAN}│${NC}  ${GREEN}✓ 服务状态: 运行中${NC}                                      ${CYAN}│${NC}"
else
  echo -e "${CYAN}│${NC}  ${RED}✗ 服务状态: 未运行${NC}                                      ${CYAN}│${NC}"
fi
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo