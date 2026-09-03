FROM debian:bookworm

#install nginx and openssl

RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx openssl && \
    rm -rf /var/lib/apt/lists/*

#make certiification

RUN mkdir -p /etc/nginx/ssl && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/inception.key \
      -out /etc/nginx/ssl/inception.crt \
      -subj "/C=JP/ST=Tokyo/L=Tokyo/O=42/OU=42/CN=kmitsuki.42.fr"

COPY conf/nginx.conf /etc/nginx/nginx.conf
# Documentation only; it is what `docker ps` reports. The port nginx really
# binds is `listen` in conf/nginx.conf, and the right-hand side of `ports:`
# in srcs/docker-compose.yml has to match it. Change all three together.
EXPOSE 443
CMD ["nginx","-g","daemon off;"]
