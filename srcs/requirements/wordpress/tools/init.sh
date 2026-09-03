#!/bin/bash
set -e

# wp-cli runs as root here, before php-fpm drops its workers to www-data, so
# --allow-root is required. The default 128M memory limit is not enough for
# `wp core install`.
wp() {
    php -d memory_limit=512M /usr/local/bin/wp \
        --path=/var/www/html --allow-root "$@"
}

mkdir -p /run/php
mkdir -p /var/www/html
cd /var/www/html

if [ ! -f "wp-config.php" ]; then
    echo "[init] first run: downloading wordpress"
    cd /tmp
    curl -O https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -r wordpress/* /var/www/html/
    cd /var/www/html
    cp wp-config-sample.php wp-config.php
    sed -i "s/database_name_here/${MYSQL_DATABASE}/" wp-config.php
    sed -i "s/username_here/${MYSQL_USER}/" wp-config.php
    sed -i "s/password_here/${MYSQL_PASSWORD}/" wp-config.php
    # WordPress accepts DB_HOST in the form host:port, so the port needs no
    # separate constant. To move the database to another port, change DB_PORT
    # in srcs/.env and `port` in mariadb/conf/50-server.cnf.
    sed -i "s/localhost/${DB_HOST}:${DB_PORT}/" wp-config.php
    # wp-config-sample.php ships all eight keys as the same placeholder string,
    # which would make the login-cookie and nonce signatures a known constant.
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
               AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        salt=$(head -c 64 /dev/urandom | base64 | tr -d '\n/+=|&' | head -c 64)
        sed -i "s|define( '${key}',.*|define( '${key}', '${salt}' );|" wp-config.php
    done
else
    echo "[init] existing wordpress found"
fi

# depends_on only guarantees that the container started, not that mysqld accepts
# queries. -P is passed separately because mysqladmin reads -h as a host name
# and does not parse "host:port". A `for` over a finite sequence can never
# become an infinite loop.
for i in $(seq 1 60); do
    mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT}" --silent && break
    echo "waiting for mariadb ($i/60)"
    sleep 2
done

# Installing writes into the database, so it is skipped whenever the volume
# already holds a site. This is what lets the stack be torn down completely and
# come back with its content intact.
if wp core is-installed 2>/dev/null; then
    echo "[init] existing installation found: skipping setup"
else
    echo "[init] installing wordpress"
    wp core install \
        --url="https://${DOMAIN_NAME}" \
        --title="${WP_TITLE}" \
        --admin_user="${WP_ADMIN_USER}" \
        --admin_password="${WP_ADMIN_PASSWORD}" \
        --admin_email="${WP_ADMIN_EMAIL}" \
        --skip-email
    wp user create "${WP_USER}" "${WP_USER_EMAIL}" \
        --role=author --user_pass="${WP_USER_PASSWORD}"
fi

chown -R www-data:www-data /var/www/html

exec php-fpm8.2 -F
