#!/bin/bash
set -e

mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "[init] first run: initializing database"
    #set where to initialize
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
    mysqld --user=mysql --bootstrap << EOF

#DB initialization and root user setting
USE mysql;
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF

else
    echo "[init] existing data found: skipping initialization"
fi

exec mysqld --user=mysql
