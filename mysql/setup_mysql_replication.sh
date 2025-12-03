#!/usr/bin/env bash
# ============================================================
#  说明: MySQL/MariaDB 主从复制配置脚本
#  作者: RobertHU
#  日期: 2023-05-09
#
#  用法: sudo ./setup_mysql_replication.sh
#        或设置环境变量: MYSQL_ROOT_PASSWORD="pwd" sudo ./setup_mysql_replication.sh
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
#  功能:
#    - 配置主库 (master): 设置 server_id, binlog, 创建复制用户
#    - 配置从库 (slave): 设置 server_id, relay_log, 启动复制
# ============================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行（例如 sudo $0）" >&2
  exit 1
fi

# 检测服务名
MYSQL_SERVICE="mysql"
if systemctl list-unit-files 2>/dev/null | grep -q '^mysqld.service'; then
  MYSQL_SERVICE="mysqld"
elif systemctl list-unit-files 2>/dev/null | grep -q '^mariadb.service'; then
  MYSQL_SERVICE="mariadb"
fi

# 查找配置文件
CONFIG_FILE=""
for f in /etc/mysql/mysql.conf.d/mysqld.cnf /etc/my.cnf /etc/mysql/my.cnf; do
  if [[ -f "$f" ]]; then
    CONFIG_FILE="$f"
    break
  fi
done
if [[ -z "$CONFIG_FILE" ]]; then
  echo "未找到 MySQL 配置文件" >&2
  exit 1
fi

set_config_value() {
  local key="$1"
  local value="$2"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
    sed -i "s/^[#[:space:]]*${key}[[:space:]]*=.*/${key} = ${value}/" "$CONFIG_FILE"
  else
    printf "\n[mysqld]\n%s = %s\n" "$key" "$value" >> "$CONFIG_FILE"
  fi
}

escape_sql() {
  local input="$1"
  printf "%s" "${input//\'/\'\'}"  
}

mysql_cli=(mysql --protocol=socket -uroot)
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  mysql_cli+=("-p${MYSQL_ROOT_PASSWORD}")
else
  read -rsp "请输入 MySQL root 密码（若已免密可直接回车）: " root_pwd
  echo
  if [[ -n "$root_pwd" ]]; then
    mysql_cli+=("-p${root_pwd}")
  fi
fi

echo "配置主从复制脚本（支持 master/slave）"
read -rp "请输入角色 [master/slave]: " role
role=${role,,}
if [[ "$role" != "master" && "$role" != "slave" ]]; then
  echo "角色无效，必须为 master 或 slave" >&2
  exit 1
fi

read -rp "请输入要同步的数据库名（用于 binlog/replicate 过滤）: " db_name
if [[ -z "${db_name:-}" ]]; then
  echo "数据库名不能为空" >&2
  exit 1
fi

# 公共配置：使用行格式 binlog
set_config_value binlog_format ROW

if [[ "$role" == "master" ]]; then
  echo "配置主库参数"
  read -rp "server_id（默认 1）: " srv_id
  srv_id=${srv_id:-1}
  if ! [[ "$srv_id" =~ ^[0-9]+$ ]]; then
    echo "server_id 必须为数字" >&2
    exit 1
  fi
  set_config_value server_id "$srv_id"
  set_config_value log_bin /var/log/mysql/mysql-bin.log
  set_config_value binlog_do_db "$db_name"

  systemctl restart "$MYSQL_SERVICE"

  read -rp "复制用户名称（默认 repl）: " repl_user
  repl_user=${repl_user:-repl}
  read -rsp "复制用户密码: " repl_pass
  echo
  if [[ -z "$repl_pass" ]]; then
    echo "复制用户密码不能为空" >&2
    exit 1
  fi
  read -rp "复制用户允许来源主机（默认 %）: " repl_host
  repl_host=${repl_host:-%}

  repl_user_esc=$(escape_sql "$repl_user")
  repl_pass_esc=$(escape_sql "$repl_pass")
  repl_host_esc=$(escape_sql "$repl_host")

  "${mysql_cli[@]}" --execute="CREATE USER IF NOT EXISTS '$repl_user_esc'@'$repl_host_esc' IDENTIFIED BY '$repl_pass_esc'; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$repl_user_esc'@'$repl_host_esc'; FLUSH PRIVILEGES;"

  master_status=$("${mysql_cli[@]}" --batch --skip-column-names --execute="SHOW MASTER STATUS;" || true)
  master_file=$(echo "$master_status" | awk '{print $1}')
  master_pos=$(echo "$master_status" | awk '{print $2}')

  echo "主库配置完成。请在从库执行 CHANGE MASTER："
  echo "MASTER_HOST=<master_ip> MASTER_PORT=3306 MASTER_USER=$repl_user MASTER_PASSWORD=****** MASTER_LOG_FILE=$master_file MASTER_LOG_POS=$master_pos"
  echo "同时在从库 my.cnf 配置 replicate-do-db=$db_name"

else
  echo "配置从库参数"
  read -rp "server_id（默认 2）: " srv_id
  srv_id=${srv_id:-2}
  if ! [[ "$srv_id" =~ ^[0-9]+$ ]]; then
    echo "server_id 必须为数字" >&2
    exit 1
  fi
  read -rp "master 主机地址: " master_host
  read -rp "master 端口（默认 3306）: " master_port
  master_port=${master_port:-3306}
  read -rp "master 复制用户: " repl_user
  read -rsp "master 复制用户密码: " repl_pass
  echo
  read -rp "master binlog 文件名（SHOW MASTER STATUS 的 File）: " master_log_file
  read -rp "master binlog 位置（Position）: " master_log_pos

  if [[ -z "$master_host" || -z "$repl_user" || -z "$repl_pass" || -z "$master_log_file" || -z "$master_log_pos" ]]; then
    echo "主机/用户/密码/binlog 文件/位置均不能为空" >&2
    exit 1
  fi
  if ! [[ "$master_port" =~ ^[0-9]+$ ]] || ! [[ "$master_log_pos" =~ ^[0-9]+$ ]]; then
    echo "端口和位置必须为数字" >&2
    exit 1
  fi

  set_config_value server_id "$srv_id"
  set_config_value relay_log /var/log/mysql/mysql-relay-bin
  set_config_value read_only 1
  set_config_value super_read_only 1
  set_config_value replicate_do_db "$db_name"

  systemctl restart "$MYSQL_SERVICE"

  repl_user_esc=$(escape_sql "$repl_user")
  repl_pass_esc=$(escape_sql "$repl_pass")
  master_host_esc=$(escape_sql "$master_host")
  master_log_file_esc=$(escape_sql "$master_log_file")

  "${mysql_cli[@]}" --execute="STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='$master_host_esc', MASTER_PORT=$master_port, MASTER_USER='$repl_user_esc', MASTER_PASSWORD='$repl_pass_esc', MASTER_LOG_FILE='$master_log_file_esc', MASTER_LOG_POS=$master_log_pos, GET_MASTER_PUBLIC_KEY=1; START SLAVE;"
  echo "已执行 CHANGE MASTER 并启动从库。建议检查：SHOW SLAVE STATUS\\G"
fi