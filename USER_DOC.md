# User documentation

This document is for someone who wants to *use* the stack: run it, browse the
site, administer WordPress, and check that everything is healthy. To set it up
from scratch or modify it, read [DEV_DOC.md](DEV_DOC.md).

## 1. What the stack provides

`make` starts three containers on a private Docker network:

| Container   | What it does                                                       | Reachable from |
| ----------- | ------------------------------------------------------------------ | -------------- |
| `nginx`     | Serves the website over HTTPS and forwards PHP to WordPress          | your browser, port 443 |
| `wordpress` | Runs WordPress on PHP-FPM — the site, its pages, the admin dashboard | `nginx` only   |
| `mariadb`   | Stores all WordPress content: posts, pages, comments, users          | `wordpress` only |

From the outside there is exactly one door: **https://kmitsuki.42.fr**. Port 80
is not served, and the database is not exposed to the host at all.

Two named volumes keep the data:

| Volume                | Contents                    | On the host                     |
| --------------------- | --------------------------- | ------------------------------- |
| `srcs_wordpress_data` | WordPress files and uploads | `/home/kmitsuki/data/wordpress` |
| `srcs_mariadb_data`   | The database                | `/home/kmitsuki/data/mariadb`   |

Anything written on the site survives `make down`, `make clean`, and a reboot of
the machine.

## 2. Starting and stopping

All commands are run from the root of the repository.

```bash
make          # build the images if needed, then start everything in the background
make down     # stop and remove the containers — data is kept
make re       # down + up
```

The very first `make` on a new machine takes a few minutes: it builds three
images and downloads WordPress. Later starts take seconds, because the init
scripts detect that the volumes are already provisioned and go straight to
serving.

```bash
make clean    # remove containers, volumes and images — the host data is still kept
make fclean   # identical to clean; the data directory is deliberately preserved
```

> **Neither `clean` nor `fclean` deletes your site.** The volumes are backed by
> `/home/kmitsuki/data`, and removing a volume object does not touch the
> directory it is bound to. Deleting the content is a deliberate manual step:
> `sudo rm -rf /home/kmitsuki/data/*`.

## 3. Accessing the website and the administration panel

- Website: <https://kmitsuki.42.fr>
- Administration panel: <https://kmitsuki.42.fr/wp-admin>

The TLS certificate is self-signed, so on the first visit the browser warns that
the connection is not trusted. That is expected — the certificate was generated
by the `nginx` image itself, not by a public certificate authority. Choose
"Advanced" then "Proceed"; the connection is still encrypted with TLSv1.2 or
TLSv1.3.

If the browser cannot resolve `kmitsuki.42.fr`, the machine is missing its
`/etc/hosts` entry:

```bash
echo "127.0.0.1 kmitsuki.42.fr" | sudo tee -a /etc/hosts
```

Two WordPress accounts exist:

| Account    | Role          | Can do                                              |
| ---------- | ------------- | --------------------------------------------------- |
| `kmitsuki` | administrator | everything: pages, themes, plugins, users, settings |
| `user2`    | author        | write and publish their own posts, leave comments   |

## 4. Where the credentials are

Every credential lives in one file: **`srcs/.env`**. It is listed in
`.gitignore`, so it is never committed — it exists only on the machine that runs
the stack.

```bash
cat srcs/.env
```

| Variable              | Used for                                        |
| --------------------- | ----------------------------------------------- |
| `MYSQL_ROOT_PASSWORD` | the MariaDB `root` account                      |
| `MYSQL_PASSWORD`      | the MariaDB account WordPress connects with     |
| `MYSQL_USER`          | the name of that account                        |
| `MYSQL_DATABASE`      | the database WordPress uses                     |
| `DB_HOST`             | hostname of the database container (`mariadb`)  |

The WordPress account passwords are not in `.env`; they were set during the
WordPress setup and are stored, hashed, in the database. Reset one with:

```bash
docker exec -it mariadb mariadb -uroot -p wordpress \
  -e "UPDATE wp_users SET user_pass = MD5('newpassword') WHERE user_login='kmitsuki';"
```

If `srcs/.env` does not exist — for instance on a freshly cloned repository —
create it from the committed template:

```bash
cp srcs/.env.example srcs/.env
$EDITOR srcs/.env
```

> **Passwords must not contain `/`, `&`, `\` or `'`.** The values are
> substituted into `wp-config.php` and into the SQL that creates the database
> user, so those four characters would break the generated files. Every other
> printable character — including `! @ # $ % ^ * ( ) - _ + = . , : ; ? < > [ ] { } | ~ "` —
> is fine. This is a documented constraint of the configuration file, not of
> WordPress itself.

Changing a password in `.env` only has an effect the first time a volume is
provisioned. On a stack that already has data, change it in MariaDB or in
WordPress directly.

## 5. Checking that everything works

### Quick health check

```bash
COMPOSE="docker compose -f srcs/docker-compose.yml"

$COMPOSE ps             # the three containers should all be "Up"
$COMPOSE logs -f        # follow the logs of all three
docker logs wordpress   # or just one
```

### The full verification, one command at a time

Every command below is followed by the output that means "correct".

**The web server answers on HTTPS and nothing answers on HTTP**

```bash
curl -kI https://kmitsuki.42.fr
#   HTTP/1.1 200 OK

curl -I http://kmitsuki.42.fr
#   curl: (7) Failed to connect ... Connection refused        ← nothing listens on 80
```

**The site is configured — the WordPress installation page is not shown**

```bash
curl -sk https://kmitsuki.42.fr | grep -o '<title>[^<]*</title>'
#   <title>Inception</title>          ← not "WordPress › Installation"
```

**Only TLSv1.2 and TLSv1.3 are accepted**

```bash
openssl s_client -connect kmitsuki.42.fr:443 </dev/null 2>/dev/null | grep Protocol
#   Protocol  : TLSv1.3

curl -k --tlsv1.2 --tls-max 1.2 -o /dev/null -w '%{http_code}\n' https://kmitsuki.42.fr
#   200

curl -k --tlsv1.1 --tls-max 1.1 https://kmitsuki.42.fr
#   curl: (35) ... unsupported protocol      ← refused, which is correct
```

**The certificate is used and matches the domain**

```bash
docker exec nginx openssl x509 -in /etc/nginx/ssl/inception.crt -noout -subject
#   subject=C = JP, ST = Tokyo, L = Tokyo, O = 42, OU = 42, CN = kmitsuki.42.fr
```

**The network exists and holds the three containers**

```bash
docker network ls | grep inception
#   ...  srcs_inception  bridge  local

docker network inspect srcs_inception --format '{{len .Containers}}'
#   3
```

**Only NGINX publishes a port**

```bash
docker ps --format '{{.Names}}\t{{.Ports}}'
#   nginx       0.0.0.0:443->443/tcp
#   wordpress   9000/tcp        ← not published
#   mariadb     3306/tcp        ← not published
```

**Both volumes exist and store their data under `/home/kmitsuki/data`**

```bash
docker volume ls | grep srcs
docker volume inspect srcs_mariadb_data   --format '{{.Options.device}}'
#   /home/kmitsuki/data/mariadb
docker volume inspect srcs_wordpress_data --format '{{.Options.device}}'
#   /home/kmitsuki/data/wordpress
```

**Each image contains only its own service**

```bash
grep -i nginx srcs/requirements/mariadb/Dockerfile
#   (no output)          <- the database image installs mariadb-server and nothing else
```

**MariaDB refuses `root` without a password, and accepts it with one**

```bash
docker exec mariadb mariadb -uroot
#   ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)

docker exec -it mariadb mariadb -uroot -p
#   ...  MariaDB [(none)]>        ← password taken from MYSQL_ROOT_PASSWORD
```

**The WordPress database account works and the database is not empty**

```bash
docker exec -it mariadb sh -c \
  'mariadb -u"$MYSQL_USER" -p "$MYSQL_DATABASE" -e "SHOW TABLES;"'
#   wp_commentmeta, wp_comments, wp_options, wp_posts, wp_users ... (12 tables)
```

**Two WordPress users exist and the administrator is not called "admin"**

```bash
docker exec -it mariadb sh -c \
  'mariadb -u"$MYSQL_USER" -p "$MYSQL_DATABASE" -e "SELECT ID, user_login FROM wp_users;"'
#   1  kmitsuki
#   2  user2
```

> **What these three checks mean.** The `root` password is the
> `MYSQL_ROOT_PASSWORD` from `srcs/.env`. The WordPress account is created as
> `'<MYSQL_USER>'@'%'` rather than `@'localhost'`, because it connects from a
> *different container* — that is a TCP connection from another address on the
> `srcs_inception` bridge, so a `localhost` grant would never match it.
> `mysql_install_db` is run with `--skip-test-db`, so no anonymous account and
> no `test` database are created; anonymous accounts are matched before named
> ones for the same host, and their absence is what makes the first command
> above fail as it should.

**Each container runs its own daemon as PID 1**

```bash
for c in nginx wordpress mariadb; do
  printf '%-10s ' "$c"; docker exec "$c" sh -c 'tr "\0" " " < /proc/1/cmdline'; echo
done
#   nginx      nginx: master process nginx -g daemon off;
#   wordpress  php-fpm: master process (/etc/php/8.2/fpm/php-fpm.conf)
#   mariadb    mysqld --user=mysql
```

**Persistence — the whole point of the volumes**

```bash
# write something on the site, then
make down && make
# or reboot the machine and run make again
```
The post is still there. Even a full teardown keeps it:
```bash
make clean && make      # containers, volumes and images destroyed and rebuilt
```

## 6. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `env file .../srcs/.env not found` | the repository was just cloned | `cp srcs/.env.example srcs/.env` and fill it in |
| `failed to mount local volume: no such file or directory` | `/home/kmitsuki/data/*` missing | `make` creates it; check the path in `srcs/docker-compose.yml` |
| The browser cannot resolve the domain | `/etc/hosts` entry missing | `echo "127.0.0.1 kmitsuki.42.fr" \| sudo tee -a /etc/hosts` |
| `502 Bad Gateway` | php-fpm not up yet, or not listening on 9000 | `docker logs wordpress`; check `listen = 9000` in `www.conf` |
| Every page except the home page is `404` | `try_files` not falling back to `/index.php` | check `location /` in `nginx.conf` |
| `Error establishing a database connection` | the password in `.env` no longer matches the one stored in the database | change it in MariaDB, or start from an empty data directory |
| Port 443 already in use | another web server on the host | stop it, or change the published port |
