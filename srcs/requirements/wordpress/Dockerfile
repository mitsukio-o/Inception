FROM debian:bookworm
RUN apt-get update && \
    apt-get install -y --no-install-recommends php-fpm php-mysql curl mariadb-client  ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY conf/www.conf   /etc/php/8.2/fpm/pool.d/www.conf
COPY tools/init.sh   /usr/local/bin/init.sh
RUN chmod +x         /usr/local/bin/init.sh
EXPOSE 9000
CMD ["/usr/local/bin/init.sh"]
