#!/bin/bash
set -e

mkdir -p /run/php
mkdir -p /var/www/html
cd /var/www/html

if [ ! -f "wp-config.php" ]; then
    echo "[init] first run: setting up wordpress"
    cd /tmp
    curl -O https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -r wordpress/* /var/www/html/
    cd /var/www/html
    cp -r wp-config-sample.php wp-config.php
    sed -i "s/database_name_here/${MYSQL_DATABASE}/" wp-config.php
    sed -i "s/username_here/${MYSQL_USER}/" wp-config.php
    sed -i "s/password_here/${MYSQL_PASSWORD}/" wp-config.php
    sed -i "s/localhost/${DB_HOST}/" wp-config.php
    chown -R www-data:www-data /var/www/html
else
    echo "[init] existing wordpress found"
fi

# -h means hostname
while ! mysqladmin ping -h mariadb --silent; do
    echo "waiting for mariadb"
    sleep 2
done

exec php-fpm8.2 -F
