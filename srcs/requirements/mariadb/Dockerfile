FROM debian:bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends mariadb-server && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/lib/mysql/*

#build context to path in image 
COPY conf/50-server.cnf  /etc/mysql/mariadb.conf.d/50-server.cnf
COPY tools/init.sh       /usr/local/bin/init.sh
RUN chmod +x            /usr/local/bin/init.sh

# Documentation only; it is what `docker ps` reports. The port mysqld really
# binds is `port` in conf/50-server.cnf, and DB_PORT in srcs/.env is what the
# clients use. Change all three together.
EXPOSE 3306
CMD ["/usr/local/bin/init.sh"]
