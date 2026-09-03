FROM debian:bookworm

# php-cli is needed explicitly: wp-cli is a PHP script, and php-fpm alone does
# not provide the `php` command.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      php-fpm php-cli php-mysql php-gd php-mbstring php-xml php-zip \
      curl ca-certificates mariadb-client && \
    rm -rf /var/lib/apt/lists/*

# wp-cli installs WordPress from tools/init.sh, so the browser setup wizard is
# never shown. It is a single PHP archive, not a package.
RUN curl -fsSL -o /usr/local/bin/wp \
      https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x /usr/local/bin/wp

COPY conf/www.conf   /etc/php/8.2/fpm/pool.d/www.conf
COPY tools/init.sh   /usr/local/bin/init.sh
RUN chmod +x         /usr/local/bin/init.sh

# Documentation only; it is what `docker ps` reports. The port php-fpm really
# binds is `listen` in conf/www.conf, and nginx connects to it with
# fastcgi_pass in nginx/conf/nginx.conf. Change all three together.
EXPOSE 9000

CMD ["/usr/local/bin/init.sh"]
