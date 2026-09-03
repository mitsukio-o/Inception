# Developer documentation

This document is for someone who wants to set the stack up from scratch or work
on it. For plain usage and verification, read [USER_DOC.md](USER_DOC.md).

## 1. Repository layout

```
.
├── Makefile                                # the only entrypoint: wraps docker compose
├── README.md  USER_DOC.md  DEV_DOC.md
└── srcs/                                   # everything docker compose needs
    ├── .env.example                        # committed template — every variable, no values
    ├── .env                                # real values. NOT committed (.gitignore)
    ├── docker-compose.yml                  # services, network, volumes
    └── requirements/
        ├── mariadb/
        │   ├── Dockerfile
        │   ├── conf/50-server.cnf          # replaces /etc/mysql/mariadb.conf.d/50-server.cnf
        │   └── tools/init.sh               # provision on first boot, then exec mysqld
        ├── nginx/
        │   ├── Dockerfile                  # also generates the self-signed certificate
        │   └── conf/nginx.conf             # replaces /etc/nginx/nginx.conf entirely
        └── wordpress/
            ├── Dockerfile
            ├── conf/www.conf               # replaces /etc/php/8.2/fpm/pool.d/www.conf
            └── tools/init.sh               # download + configure WordPress, then exec php-fpm
```

The split is deliberate: `conf/` holds files baked into the image at build time,
`tools/` holds what runs at container start. A `Dockerfile` therefore never
contains configuration inline, and no password is ever written into an image
layer.

`nginx` has no `tools/` because it needs no provisioning — its certificate is
generated during the build and its configuration is static.

## 2. Prerequisites

- A Linux machine. The subject requires a virtual machine.
- `docker` and the `docker compose` v2 plugin.
- `make`.

Install on Debian:

```bash
sudo apt-get update
sudo apt-get install -y make docker.io docker-compose-v2
sudo usermod -aG docker "$USER"      # then log out and back in
```

The `usermod` only takes effect on a new login session — group membership is
resolved at login, not per command.

## 3. Setting up from scratch

### 3.1 Configuration

```bash
cp srcs/.env.example srcs/.env
$EDITOR srcs/.env
```

| Variable              | Used by            | Meaning                                          |
| --------------------- | ------------------ | ------------------------------------------------ |
| `MYSQL_DATABASE`      | mariadb, wordpress | the database WordPress uses                      |
| `MYSQL_USER`          | mariadb, wordpress | the account WordPress connects with               |
| `MYSQL_PASSWORD`      | mariadb, wordpress | that account's password                          |
| `MYSQL_ROOT_PASSWORD` | mariadb            | the MariaDB `root` password                      |
| `DB_HOST`             | wordpress          | hostname of the database container (`mariadb`)   |
| `DB_PORT`             | wordpress          | the port mysqld listens on                       |
| `DOMAIN_NAME`         | wordpress          | the site address the installer stores in the database |
| `WP_TITLE`            | wordpress          | the site title                                   |
| `WP_ADMIN_USER`       | wordpress          | the administrator login                          |
| `WP_ADMIN_PASSWORD`   | wordpress          | the administrator password                       |
| `WP_ADMIN_EMAIL`      | wordpress          | the administrator email address                  |
| `WP_USER`             | wordpress          | the second, non-administrator account            |
| `WP_USER_PASSWORD`    | wordpress          | that account's password                          |
| `WP_USER_EMAIL`       | wordpress          | that account's email address                     |

> **`WP_ADMIN_USER` must not contain `admin` in any casing.** The subject
> forbids it, and it is checked. `administrator`, `Admin-kmitsuki` and
> `admin123` are all rejected; the login used elsewhere in the project is not.

> **`DOMAIN_NAME` is not the only place the domain appears.** It is what the
> installer writes into `wp_options`, so it has to agree with `server_name` in
> `nginx.conf` and with the certificate `CN`; §3.4 lists all of them.

> **`DB_PORT` must agree with `port` in
> `srcs/requirements/mariadb/conf/50-server.cnf`.** It is the client half of
> the same number: `wp-config.php` receives `DB_HOST:DB_PORT`, and the wait
> loop passes it to `mysqladmin` as `-P`.

> **The database host variable must not be called `MYSQL_HOST`.**
> `MYSQL_HOST` is read by the MariaDB *client* as its default host. `env_file:`
> hands the same file to every service, so that name would also be injected into
> the `mariadb` container. `mariadb -uroot` run inside that container would then
> connect over TCP to `mariadb` — its own address — instead of using the local
> unix socket, and the session would be matched as `root@<container-ip>` rather
> than `root@localhost`. The password set on `root@localhost` would not apply,
> and if any anonymous account existed the login would succeed **with no
> password at all**. `DB_HOST` avoids the whole class of problem.

> **Passwords must not contain `/`, `&`, `\` or `'`.**
> The values are substituted into `wp-config.php` with `sed` and into the SQL
> that creates the database user. `/` terminates the `sed` expression, `&`
> expands to the matched text, `\` starts an escape, and `'` closes the string
> literal in both PHP and SQL. Everything else — including
> `! @ # $ % ^ * ( ) - _ + = . , : ; ? < > [ ] { } | ~ "` — is safe. This is a
> constraint of the configuration file, which is operator-controlled, not of
> user input.

### 3.2 Host preparation

`make` performs the one host-side step itself, in the `up` target:

```makefile
mkdir -p /home/kmitsuki/data/mariadb /home/kmitsuki/data/wordpress
```

These are the two directories the named volumes bind to. Without them the
`local` driver refuses to mount and the containers fail with
`failed to mount local volume: no such file or directory`. `mkdir -p` succeeds
on an existing directory, so the target is idempotent.

The browser also needs to resolve the domain to the machine:

```bash
echo "127.0.0.1 kmitsuki.42.fr" | sudo tee -a /etc/hosts
```

### 3.3 First launch

```bash
make
```

That is the whole procedure. It creates the two host directories, builds the
three images, starts the containers, and provisions both volumes:

- `mariadb` creates the database and the WordPress account, replaces the
  `unix_socket` authentication on `root` with a password, and starts `mysqld`.
- `wordpress` downloads WordPress, writes `wp-config.php` with eight freshly
  generated security keys, waits for the database to accept queries, then runs
  `wp core install` and creates the second account.

The first run takes a few minutes: three images are built and WordPress is
downloaded. Later starts take seconds, because both init scripts find the
volume already provisioned and go straight to their `exec`.

When it finishes, <https://kmitsuki.42.fr> serves a configured site. **The
WordPress setup wizard is never shown.** If it appears, the install step did not
run, and the log says why:

```bash
docker logs wordpress | grep '^\[init\]'
#   [init] first run: downloading wordpress
#   [init] installing wordpress
```

On every later start the same two lines read:

```
#   [init] existing wordpress found
#   [init] existing installation found: skipping setup
```

Both accounts come from `srcs/.env` and exist as soon as `make` returns: an
administrator (`WP_ADMIN_USER`) and an author (`WP_USER`). The author role is
deliberate — an author can publish posts and leave comments, which a subscriber
cannot.

The installation is guarded by `wp core is-installed`, which asks the database
rather than the filesystem. That is what makes the step safe to re-run: a volume
that already holds a site is never touched, so the accounts and the content
survive a complete teardown.


### 3.4 Changing the domain or the login

The domain appears in three places. Two are baked into the image at build time;
the third is written into the database by the installer.

1. `srcs/requirements/nginx/conf/nginx.conf` — `server_name`
2. `srcs/requirements/nginx/Dockerfile` — the `CN=` of the self-signed certificate
3. `srcs/.env` — `DOMAIN_NAME`, which `wp core install` stores in `wp_options`

plus the `/etc/hosts` entry on the machine running the browser.

The login appears in the data paths, in two more files:

4. `Makefile` — the `mkdir -p /home/<login>/data/...` line
5. `srcs/docker-compose.yml` — the two `device:` paths

`DOMAIN_NAME` is read only while the site is being installed, so on a stack that
already holds data the stored address has to be changed by hand as well —
otherwise every request is redirected back to the old one:

```bash
docker exec wordpress wp --path=/var/www/html --allow-root \
  option update home "https://new.domain"
docker exec wordpress wp --path=/var/www/html --allow-root \
  option update siteurl "https://new.domain"
```

The same two rows, in SQL:

```bash
docker exec -it mariadb mariadb -u<MYSQL_USER> -p <MYSQL_DATABASE> \
  -e "UPDATE wp_options SET option_value='https://new.domain' WHERE option_name IN ('siteurl','home');"
```


### 3.5 Changing a port

Every port in the stack has a process that *listens* on it and something that
*connects* to it, and both sides live in different files. Changing one side only
is the single most common way to break the stack, so the tables below list every
file a given port appears in.

`EXPOSE` never changes behaviour — it only records the port in the image
metadata, which is what `docker ps` reports in its `PORTS` column. It is listed
anyway, because leaving it stale makes `docker ps` lie.

**The published HTTPS port.** The only port that exists outside the machine.

| File                      | Change                       |
| ------------------------- | ---------------------------- |
| `srcs/docker-compose.yml` | `ports: - "8443:443"`        |

The left number is the host, the right number is the port inside the container.
NGINX keeps listening on 443, so nothing else moves.

```bash
make re
curl -kI https://kmitsuki.42.fr:8443
```

**The port NGINX listens on.** Now the right-hand side of `ports:` has to follow,
because that number is the one inside the container.

| File                                      | Change                 |
| ----------------------------------------- | ---------------------- |
| `srcs/requirements/nginx/conf/nginx.conf` | `listen 8443 ssl;`     |
| `srcs/requirements/nginx/Dockerfile`      | `EXPOSE 8443`          |
| `srcs/docker-compose.yml`                 | `ports: - "8443:8443"` |

**The FastCGI port.** PHP-FPM listens, NGINX connects.

| File                                          | Change                        |
| --------------------------------------------- | ----------------------------- |
| `srcs/requirements/wordpress/conf/www.conf`   | `listen = 9001`               |
| `srcs/requirements/nginx/conf/nginx.conf`     | `fastcgi_pass wordpress:9001;`|
| `srcs/requirements/wordpress/Dockerfile`      | `EXPOSE 9001`                 |

Changing only one of the first two gives a very specific symptom: static files
still load, every PHP request returns `502 Bad Gateway`, and `docker logs nginx`
shows `connect() failed ... upstream: fastcgi://<ip>:<old port>`. That message
names the side that was not updated.

This port is internal to the bridge network and is never published, so nothing
outside the stack is affected by the change.

**The database port.** The server side and the client side, plus `EXPOSE` for
consistency.

| File                                           | Change                         |
| ---------------------------------------------- | ------------------------------ |
| `srcs/requirements/mariadb/conf/50-server.cnf` | `port = 3307`                  |
| `srcs/.env`                                    | `DB_PORT=3307`                 |
| `srcs/requirements/mariadb/Dockerfile`         | `EXPOSE 3307`                  |

`DB_PORT` is the only place the client side is written. `wp-config.php` receives
it as `DB_HOST:DB_PORT`, a form WordPress accepts, and the wait loop passes it to
`mysqladmin` as `-P` — separately, because `mysqladmin` reads `-h` as a host name
and does not parse `host:port`. Neither init script needs editing.

Changing only the server side still lets the stack come up, which is what makes
the mistake confusing: `mysqladmin` never answers, the loop runs its full 60
iterations, and about two minutes later php-fpm starts and serves
`Error establishing a database connection`. A slow start followed by that page
is the signature.

One thing a rebuild cannot reach is `wp-config.php`: it lives on the volume and
is written only when absent, so a site that already exists keeps the old value.
Either update it in place —

```bash
docker exec wordpress sed -i \
  "s/'DB_HOST', *'[^']*'/'DB_HOST', 'mariadb:3307'/" /var/www/html/wp-config.php
docker restart wordpress
```

— or start from an empty data directory, which destroys the site:

```bash
make clean && sudo rm -rf /home/kmitsuki/data/* && make
```

This port is internal to the bridge network and is never published, so nothing
outside the stack is affected by the change.


**Picking a number.** Anything from 1024 to 65535 that is free on the machine
works; `sudo ss -tlnp` lists what is already taken. Three numbers are special:
`22` carries the SSH session and taking it over ends the connection, `80` must
stay closed because the infrastructure is HTTPS-only, and the ports already in
use inside the stack (443, 9000, 3306) collide with themselves. Ports below 1024
need root, which the containers happen to have, so they work — 443 is one — but
they are worth avoiding otherwise.

Note that the three network layers are independent: a port used by the host
machine, by the virtual machine, and inside a container are unrelated even when
the number is the same. Only the left-hand side of `ports:` competes with other
programs on the virtual machine.

### 3.6 Changing other configuration values

| To change                       | Edit                                                | Then                              |
| ------------------------------- | --------------------------------------------------- | --------------------------------- |
| accepted TLS versions           | `ssl_protocols` in `nginx.conf`                     | `make re`                         |
| the certificate subject         | the `-subj` argument in `nginx/Dockerfile`          | `make re`                         |
| PHP upload size, memory limit   | `php_admin_value[...]` lines in `www.conf`          | `make re`                         |
| the number of PHP workers       | `pm.*` directives in `www.conf`                     | `make re`                         |
| MariaDB tuning, character set   | `50-server.cnf`                                     | `make re`                         |
| the domain name                 | four places — see §3.4                              | `make re`                         |
| database name, user, password   | `srcs/.env`                                         | empty data directory, then `make` |
| where the data is stored        | `device:` in `docker-compose.yml`, `mkdir` in the `Makefile` | `make re`                |
| the site title, users, plugins  | the WordPress dashboard                             | nothing                           |

The line in that table that catches people is the credentials one. `.env` is read
when the *volume* is provisioned, not when the container starts, so editing a
password on a stack that already has data changes nothing — the database keeps
the account it was created with. Change it in MariaDB instead, or reprovision.

A PHP setting is added to the pool file rather than to a new `php.ini`, because
`www.conf` is already copied into the image:

```ini
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 512M
```


## 4. Building and launching

```bash
make          # mkdir + docker compose up -d --build
make down     # docker compose down
make re       # down + up
make clean    # docker compose down --rmi all --volumes
make fclean   # same as clean; the host data directory is deliberately preserved
```

Every target is a thin wrapper around

```
docker compose -f srcs/docker-compose.yml …
```

Compose derives the project name from the directory holding the compose file,
which is always `srcs`. That is why the resources are named `srcs_mariadb_data`,
`srcs_wordpress_data` and `srcs_inception` regardless of where the repository is
cloned — the names stay stable, and a re-clone into a different directory still
picks up the same volumes.

Each service builds an image tagged `<service>:inception`. The repository name
matches the service name as the subject requires, and the tag is explicit —
`latest` is forbidden.

## 5. Container and volume management

```bash
docker compose -f srcs/docker-compose.yml ps
docker compose -f srcs/docker-compose.yml logs -f nginx
docker compose -f srcs/docker-compose.yml restart wordpress
docker compose -f srcs/docker-compose.yml up -d --build nginx    # rebuild one service

docker exec -it nginx     bash
docker exec -it mariadb   mariadb -uroot -p
docker exec -it wordpress bash
```

Useful checks:

```bash
docker network inspect srcs_inception                  # the three containers, one subnet
docker volume inspect srcs_wordpress_data --format '{{.Options.device}}'
docker exec nginx nginx -t                             # vhost syntax
docker exec wordpress php-fpm8.2 -t                    # php-fpm syntax
docker exec wordpress php -l /var/www/html/wp-config.php
docker exec nginx sh -c 'tr "\0" " " < /proc/1/cmdline' # PID 1 is the daemon itself
```

### Rebuilding after a change

- Changing a `conf/` file or a `Dockerfile` → `make re`. The layer cache means
  only the affected image is rebuilt.
- Changing an `init.sh` → same, `make re`.
- Changing anything that only runs on the **first** boot — the WordPress
  download, the SQL bootstrap, the salt generation — has no effect while the
  volumes hold state. To exercise it you must start from an empty data
  directory:
  ```bash
  make clean && sudo rm -rf /home/kmitsuki/data/* && make
  ```
  This destroys the site. `make fclean` deliberately does **not** do it.

### Confirming that a change took effect

Work outwards, in this order. Each step tells you which of the previous ones is
at fault.

**1. Did the edited file reach the image?**

```bash
docker exec nginx     grep fastcgi_pass /etc/nginx/nginx.conf
docker exec wordpress grep '^listen'    /etc/php/8.2/fpm/pool.d/www.conf
docker exec mariadb   grep -E '^port|^bind-address' /etc/mysql/mariadb.conf.d/50-server.cnf
```

If the old value is still there, the image was not rebuilt. Files under `conf/`
are copied in by `COPY` at build time, so `docker compose restart` — and
`docker compose up -d` without `--build` — keep serving the previous copy.
`make re` rebuilds.

**2. Is the process actually reachable on the new port?**

Ask the container that will do the connecting, which needs no extra package —
`bash` opens a TCP connection through `/dev/tcp`:

```bash
docker exec nginx     bash -c 'exec 3<>/dev/tcp/wordpress/9000 && echo reachable'
docker exec wordpress bash -c 'exec 3<>/dev/tcp/mariadb/3306   && echo reachable'
```

Anything other than `reachable` means the daemon is not listening there. If
`iproute2` is installed in the image, `docker exec <service> ss -tlnp` shows the
same thing as a list.

**3. Does the whole path work?**

```bash
curl -kI https://kmitsuki.42.fr
#   HTTP/1.1 200 OK
```

`502 Bad Gateway` here with both checks above passing means NGINX and PHP-FPM
disagree about the port. `docker logs nginx` prints the address it tried.


## 6. Where the data lives, and why it persists

| Volume                | Mounted at                                       | Host path                       |
| --------------------- | ------------------------------------------------ | ------------------------------- |
| `srcs_mariadb_data`   | `mariadb:/var/lib/mysql`                         | `/home/kmitsuki/data/mariadb`   |
| `srcs_wordpress_data` | `wordpress:/var/www/html`, `nginx:/var/www/html` | `/home/kmitsuki/data/wordpress` |

Both are **named volumes**, declared in the top-level `volumes:` section — never
an inline host path on a service. The subject additionally requires the data to
sit under `/home/kmitsuki/data`, which is expressed by handing the `local`
driver a bind device:

```yaml
volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/kmitsuki/data/mariadb
```

The volume stays a Docker-managed object — it appears in `docker volume ls`, and
`docker volume inspect srcs_mariadb_data` reports the required path — while its
bytes land where the subject asks.

### What survives what

| Action                                                              | Volume objects | `/home/kmitsuki/data` | The site   |
| ------------------------------------------------------------------- | -------------- | --------------------- | ---------- |
| `make down`, `make re`                                              | kept           | kept                  | kept       |
| `make clean`, `make fclean`                                         | **removed**    | kept                  | kept       |
| `docker rm` + `docker rmi` + `docker volume rm` + `docker network rm` | **removed**    | kept                  | kept       |
| reboot of the virtual machine                                       | kept           | kept                  | kept       |
| `sudo rm -rf /home/kmitsuki/data/*`                                 | —              | **emptied**           | **gone**   |

The third row is the one worth understanding. Because the bytes live outside
Docker's own storage area, **`docker volume rm` removes the volume object
without touching the directory it was bound to** — the driver only unmounts.
Recreating the volume with the same `device:` finds the same files. That is what
lets every container, image, volume and network be destroyed and the site come
back unchanged.

Only the last row actually loses data, and it is the one Docker cannot do on its
own: a plain `rm` on the host filesystem.

### How a container finds existing data again

There are three guards, one for each thing that may already exist:

```sh
[ ! -d "/var/lib/mysql/mysql" ]   # mariadb:   is there a system database?
[ ! -f "wp-config.php" ]          # wordpress: are the files and the config there?
wp core is-installed              # wordpress: does the database hold a site?
```

The first two ask the filesystem; the third asks the database, and that
difference matters. The two volumes are separate directories and can be in
different states — a re-downloaded WordPress with an intact database, or an
intact `wp-config.php` pointing at an empty one — so "are the files present" and
"is the site installed" have to be answered independently. Asking the database
directly is also what makes the install step safe to re-run.

On a first boot all three say *nothing here* and the scripts provision. On every
later boot all three say *already done* and the scripts go straight to their
`exec`. The init log states which path was taken:

```bash
docker logs mariadb   | grep '^\[init\]'
docker logs wordpress | grep '^\[init\]'
```

### Across a reboot

`restart: always` on each service means the Docker daemon brings the containers
back by itself when the machine comes up; nothing has to be run by hand. Running
`make` again after a reboot is equally safe — it rebuilds nothing that has not
changed, and the init scripts take the *already done* path.

### Starting over

`/home/kmitsuki/data` is created by `make`, not by Docker, because the `local`
driver refuses to mount a bind target that does not exist. If the directory is
emptied while the stack is down, the next `make` provisions everything again
from `srcs/.env`: a new database, a fresh WordPress, and the two accounts
recreated with the names and passwords in that file. Nothing carries over from
the previous installation, which is why `srcs/.env` — the one file that is
deliberately not committed — is what makes the stack reproducible.


## 7. How each service is built

### mariadb

```
Dockerfile        apt-get install mariadb-server, wipe /var/lib/mysql
conf/50-server.cnf  bind-address = 0.0.0.0 so the other container can connect
tools/init.sh     first boot only:
                    mysql_install_db --skip-test-db
                    mysqld --bootstrap  <<  CREATE DATABASE / CREATE USER /
                                            GRANT / ALTER USER root
                  always:  exec mysqld --user=mysql
```

`--skip-test-db` matters. Without it `mysql_install_db` also creates the
anonymous accounts `''@'localhost'` and `''@'<hostname>'` and a `test` database.
Anonymous accounts are matched before named ones for the same host, so their
presence is what would let `mariadb -u root` succeed **with no password**.

The WordPress account is created as `'<MYSQL_USER>'@'%'`, not `@'localhost'`.
WordPress runs in a separate container, so it arrives over TCP from another
address on the `srcs_inception` bridge; a `localhost` grant — which MariaDB
matches only for the unix socket and `127.0.0.1` — would never apply to it.
`root` keeps `@'localhost'` for the opposite reason: it should be usable only
from inside the database container, never over the network.

`bind-address = 0.0.0.0` looks permissive but is not: the container has exactly
one network interface, on the private `srcs_inception` bridge, and the service
publishes no port. The boundary is the network namespace, not the bind address.

### nginx

```
Dockerfile     apt-get install nginx openssl
               openssl req -x509 ... -subj "/...CN=kmitsuki.42.fr"   (build time)
conf/nginx.conf  replaces /etc/nginx/nginx.conf entirely
CMD            nginx -g "daemon off;"
```

Replacing `nginx.conf` wholesale rather than dropping a file into
`sites-enabled/` is deliberate: the shipped default site listens on port 80, and
the replacement never includes `sites-enabled/`, so port 80 does not exist in
the configuration at all.

Two directives carry most of the weight:

```nginx
ssl_protocols TLSv1.2 TLSv1.3;              # nothing older is offered
try_files $uri $uri/ /index.php?$args;      # WordPress permalinks
```

`try_files` serves a real file if one exists — which is how CSS, JavaScript and
images are returned without ever reaching PHP — and otherwise hands the request
to `index.php`, which is what makes `/2026/08/hello-world/` work. With the
`=404` fallback instead, every URL except the home page would 404 as soon as
permalinks are enabled.

`include snippets/fastcgi-php.conf;` is Debian's own snippet; it ends with
`include fastcgi.conf;`, which is the file that sets
`SCRIPT_FILENAME $document_root$fastcgi_script_name` — the parameter PHP-FPM
needs in order to know which file to execute.

### wordpress

```
Dockerfile     apt-get install php-fpm php-cli php-mysql php-gd php-mbstring
                              php-xml php-zip curl ca-certificates mariadb-client
               wp-cli.phar -> /usr/local/bin/wp
conf/www.conf  listen = 9000   (not the default unix socket — see below)
tools/init.sh  first boot only:  download WordPress, write wp-config.php,
                                 replace the 8 security keys with random values
               once per site:    wp core install, then wp user create
               always:           bounded wait for MariaDB, then exec php-fpm8.2 -F
```

WordPress is installed from the command line rather than through the browser,
because the site has to be complete as soon as `make` returns — the setup wizard
being reachable is itself a failure. `wp-cli` is a single PHP archive fetched at
build time, so nothing joins the package set except `php-cli`, which it needs in
order to run and which was previously present only as a transitive dependency of
`php-fpm`.

Two options on the wrapper are not decoration:

```sh
wp() {
    php -d memory_limit=512M /usr/local/bin/wp \
        --path=/var/www/html --allow-root "$@"
}
```

`--allow-root` because `init.sh` runs as root — php-fpm's master starts as root
and drops only its workers to `www-data`, so at this point there is no
unprivileged user to become. `-d memory_limit=512M` because the pool's 128M is
not enough for `wp core install`; giving it on the command line keeps the higher
limit out of `www.conf`, where it would apply to every request the site ever
serves.

Both accounts are created here, from `srcs/.env`:

```sh
wp core install --url="https://${DOMAIN_NAME}" --title="${WP_TITLE}" \
                --admin_user="${WP_ADMIN_USER}" ... --skip-email
wp user create "${WP_USER}" "${WP_USER_EMAIL}" --role=author ...
```

`--skip-email` stops WordPress from trying to send a notification from a
container that has no mail transport, which would otherwise delay the install.
`author` is the lowest role that can both publish a post and leave a comment.

`listen = 9000` rather than the Debian default, which is a unix socket
(`/run/php/php8.2-fpm.sock`): NGINX is a separate container with its own network
namespace, so neither a socket in this container nor its `127.0.0.1` is
reachable from there. Binding to all interfaces is what lets
`fastcgi_pass wordpress:9000;` work.

`php-fpm8.2 -F` runs in the foreground. Without `-F` the master would fork and
the original process would exit, which Docker reads as "the container's work is
done" and stops it. Combined with `exec`, php-fpm becomes PID 1 and receives
`SIGTERM` from `docker stop` directly.

The security keys are regenerated because `wp-config-sample.php` ships all eight
of them as the literal string `put your unique phrase here`. Left as-is, the
signing keys for login cookies and nonces would be a publicly known constant:

```sh
salt=$(head -c 64 /dev/urandom | base64 | tr -d '\n/+=|&' | head -c 64)
```

base64 emits `A-Za-z0-9+/=`; `tr` strips `+`, `/` and `=` from that alphabet,
plus `|` and `&` as a guard — the delimiter used in the `sed` command, and the
one character `sed` expands inside a replacement. What is left is alphanumeric,
so it is always safe to substitute.

The wait loop is bounded on purpose:

```sh
for i in $(seq 1 60); do
    mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT}" --silent && break
    sleep 2
done
```

`depends_on` only guarantees that the MariaDB *container* started, not that the
daemon accepts queries. An unbounded `while` would satisfy that need too, but a
`for` over a finite sequence can never become an infinite loop, which the
subject explicitly prohibits in entrypoint scripts. If the database never
answers, `wp core install` fails, `set -e` ends the script, and `restart: always`
tries the whole sequence again — a container that keeps restarting is a clearer
symptom than one serving a broken page.


## 8. Constraints to respect when editing

- **One service per container**, and that service is **PID 1**. Every init
  script ends with `exec`, so `docker stop` delivers `SIGTERM` to the daemon
  itself instead of being killed after the grace period.
- **No process kept alive artificially.** `tail -f`, `sleep infinity`,
  `while true`, `nginx & bash` are grounds for immediate failure at evaluation.
- **No `network_mode: host`, no `links:`.** Services find each other by
  container name through the embedded DNS of the user-defined bridge network.
- **Only `nginx` publishes a port**, and only `443`.
- **No `latest` tag**, on base images or on built images.
- **No password in a `Dockerfile` or in an image layer**, and `srcs/.env` stays
  in `.gitignore`.
- **`mysql_install_db` keeps `--skip-test-db`**, and the database host variable
  keeps the name `DB_HOST`. Undoing either re-opens password-less `root` login.

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `env file .../srcs/.env not found` | fresh clone | `cp srcs/.env.example srcs/.env` |
| `failed to mount local volume` | data directory missing | `make` creates it; check the path in `docker-compose.yml` |
| WordPress shows the installation wizard | the data directory is empty | complete the setup once (§3.3) |
| `502 Bad Gateway` | php-fpm down, or `listen` is a socket / `127.0.0.1` | `docker logs wordpress`; check `www.conf` |
| Every page but the home page is `404` | `try_files` missing the `/index.php` fallback | check `location /` in `nginx.conf` |
| `mariadb -uroot` logs in with no password | `--skip-test-db` removed, or the host variable renamed to `MYSQL_HOST` | restore both, then reprovision from an empty data directory |
| `Error establishing a database connection` | `.env` password no longer matches the stored one | change it in MariaDB, or reprovision |
| `permission denied ... docker.sock` | not in the `docker` group yet | log out and back in |
