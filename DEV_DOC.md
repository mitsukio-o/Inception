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

| Variable              | Used by            | Meaning                                        |
| --------------------- | ------------------ | ---------------------------------------------- |
| `MYSQL_DATABASE`      | mariadb, wordpress | the database WordPress uses                    |
| `MYSQL_USER`          | mariadb, wordpress | the account WordPress connects with            |
| `MYSQL_PASSWORD`      | mariadb, wordpress | that account's password                        |
| `MYSQL_ROOT_PASSWORD` | mariadb            | the MariaDB `root` password                    |
| `DB_HOST`             | wordpress          | hostname of the database container (`mariadb`) |

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

This builds the three images and starts the containers. On a brand-new data
directory, the first launch produces an empty WordPress: `init.sh` downloads
WordPress and writes `wp-config.php`, but the site itself has no title, no
administrator and no tables yet.

**Complete the WordPress setup once**, by opening
<https://kmitsuki.42.fr> in a browser and filling in the form:

- Site title
- Username — **must not contain `admin` or `Admin` in any casing**; the subject
  forbids it and the evaluation checks it
- Password, email

Then create the second account required by the subject:
**Dashboard → Users → Add New**, role `Author` (an author can publish posts and
leave comments; a subscriber cannot).

From that point on the state lives in `/home/kmitsuki/data`, and every later
start reuses it. `init.sh` sees `wp-config.php` and skips its whole setup block,
and MariaDB's `init.sh` sees `/var/lib/mysql/mysql` and skips its own.

### 3.4 Changing the domain or the login

The domain is baked in at build time, so it appears in two files:

1. `srcs/requirements/nginx/conf/nginx.conf` — `server_name`
2. `srcs/requirements/nginx/Dockerfile` — the `CN=` of the self-signed certificate

plus the `/etc/hosts` entry on the machine running the browser.

The login appears in the data paths, in two more files:

3. `Makefile` — the `mkdir -p /home/<login>/data/...` line
4. `srcs/docker-compose.yml` — the two `device:` paths

After changing the domain, the site URL stored in the database must be updated
too, or the browser will be redirected to the old one:

```bash
docker exec -it mariadb mariadb -uwpuser -p wordpress \
  -e "UPDATE wp_options SET option_value='https://new.domain' WHERE option_name IN ('siteurl','home');"
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

## 6. Where the data lives, and why it persists

| Volume                | Mounted at                                                   | Host path                       |
| --------------------- | ------------------------------------------------------------ | ------------------------------- |
| `srcs_mariadb_data`   | `mariadb:/var/lib/mysql`                                     | `/home/kmitsuki/data/mariadb`   |
| `srcs_wordpress_data` | `wordpress:/var/www/html`, `nginx:/var/www/html`             | `/home/kmitsuki/data/wordpress` |

Both are **named volumes**, declared in the top-level `volumes:` section — never
an inline host path on a service. The subject additionally requires the data to
sit under `/home/kmitsuki/data`, expressed by handing the `local` driver a bind
device:

```yaml
volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/kmitsuki/data/mariadb
```

The object stays Docker-managed — it appears in `docker volume ls`, and
`docker volume inspect` reports the required path — while its bytes land where
the subject asks.

Because those bytes live outside Docker's own storage area, **`docker volume rm`
removes the volume object without touching the directory it was bound to.** A
complete teardown (`docker rm`, `docker rmi`, `docker volume rm`,
`docker network rm`) followed by `make` therefore brings the site back exactly
as it was. This has been verified end to end.

Persistence then depends on the init scripts being **idempotent**. Each one asks
whether the volume is already provisioned before doing anything:

```sh
[ ! -d "/var/lib/mysql/mysql" ]   # mariadb: is there a system database?
[ ! -f "wp-config.php" ]          # wordpress: has the site been configured?
```

The first boot provisions and then `exec`s the daemon. Every later boot skips
straight to the `exec`, finds the existing data and serves it.

`restart: always` on each service means the containers come back on their own
after a crash or after the Docker daemon restarts — which is what makes the
stack survive a reboot of the virtual machine.

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
Dockerfile     apt-get install php-fpm php-mysql php-gd php-mbstring php-xml
                              php-zip curl mariadb-client ca-certificates
conf/www.conf  listen = 9000   (not the default unix socket — see below)
tools/init.sh  first boot only:  download WordPress, write wp-config.php,
                                 replace the 8 security keys with random values
               always:           bounded wait for MariaDB, then exec php-fpm8.2 -F
```

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

`tr` removes exactly the characters that would otherwise break the `sed`
replacement (`&`), its `|` delimiter, and the surrounding PHP string — leaving
an alphanumeric value that is always safe to substitute.

The wait loop is bounded on purpose:

```sh
for i in $(seq 1 60); do
    mysqladmin ping -h ${DB_HOST} --silent && break
    sleep 2
done
```

`depends_on` only guarantees that the MariaDB *container* started, not that the
daemon accepts queries. An unbounded `while` would satisfy that need too, but a
`for` over a finite sequence can never become an infinite loop, which the
subject explicitly prohibits in entrypoint scripts.

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
