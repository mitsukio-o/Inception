#!/bin/bash
set -e

# mysqld drops its unix socket and pid file here, and the package does not
# create the directory in a container.
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

# The presence of the system database is what distinguishes a fresh volume from
# one that already holds data. Everything below runs once, on the first boot.
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "[init] first run: initializing database"

    # --skip-test-db suppresses the anonymous accounts ''@'localhost' and
    # ''@'<hostname>' and the `test` database. Anonymous accounts are matched
    # before named ones for the same host, so leaving them in place is what
    # would let `mariadb -u root` succeed with no password at all.
    mysql_install_db --user=mysql --datadir=/var/lib/mysql --skip-test-db

    # --bootstrap runs this SQL against the data directory without opening a
    # socket or a port, so the database is never reachable while it has no
    # root password.
    #
    # The WordPress account is granted on '%' rather than 'localhost' because
    # it connects from another container, which is another address on the
    # bridge network; a localhost grant matches only the unix socket and
    # 127.0.0.1 and would never apply. root keeps 'localhost' for the opposite
    # reason: it should be usable only from inside this container.
    mysqld --user=mysql --bootstrap << EOF
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

# exec replaces this shell, so mysqld becomes PID 1 and receives the SIGTERM
# that docker stop sends. The port it listens on is `port` in
# conf/50-server.cnf, not anything in this file.
exec mysqld --user=mysql
