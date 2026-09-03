*This project has been created as part of the 42 curriculum by kmitsuki.*

# Inception

## Description

Inception is a system administration project. The goal is to build a small but
complete web infrastructure from scratch inside a virtual machine, using Docker
and Docker Compose, without pulling any ready-made application image.

The stack is three containers, each built from its own hand-written Dockerfile
and each running exactly one service:

| Service     | Contents                                   | Reachable from     |
| ----------- | ------------------------------------------ | ------------------ |
| `nginx`     | NGINX + OpenSSL, TLS termination           | the host, port 443 |
| `wordpress` | WordPress + PHP-FPM (no web server inside) | `nginx` only       |
| `mariadb`   | MariaDB                                    | `wordpress` only   |

NGINX is the only entrypoint into the infrastructure, on port 443 only, and it
accepts TLSv1.2 / TLSv1.3 exclusively. WordPress and MariaDB publish no port at
all, so they cannot be reached from outside the Docker network. Two named
volumes hold the website files and the database, both backed by
`/home/kmitsuki/data` on the host, so all state survives `make down`, `make
clean` and a reboot of the machine.

All three images are built locally from `debian:bookworm`, the penultimate
stable Debian release.

```
                                   WWW
                                    │
                                  :443
   host (virtual machine)  ─────────┼─────────────────────────────────
                                    │
   docker network "inception"       │
                          ┌─────────┴────────┐
                          │      nginx       │  TLSv1.2 / TLSv1.3
                          └────┬────────┬────┘
                       FastCGI │        │ serves static files
                         :9000 │        │
                          ┌────┴─────┐  │
                          │ wordpress├──┴──►  volume  wordpress_data
                          └────┬─────┘         /home/kmitsuki/data/wordpress
                         :3306 │
                          ┌────┴─────┐
                          │ mariadb  ├──────►  volume  mariadb_data
                          └──────────┘         /home/kmitsuki/data/mariadb
```

## Instructions

Requirements: a Linux virtual machine with `docker`, the `docker compose` v2
plugin and `make`.

```bash
cp srcs/.env.example srcs/.env    # then fill in your own values
make                              # build the images, start, and install the site
```

| Command      | Effect                                                    | Data |
| ------------ | --------------------------------------------------------- | ---- |
| `make`       | create the data directories, build the images, start       | kept |
| `make down`  | stop and remove the containers                             | kept |
| `make re`    | `down` then `up`                                           | kept |
| `make clean` | also remove the volumes and the images                     | kept |
| `make fclean`| same as `clean`; the host data is deliberately preserved   | kept |

Then open <https://kmitsuki.42.fr>. The site is already configured — WordPress
is installed during the first `make`, so the setup wizard is never shown, and
both accounts named in `srcs/.env` already exist. The certificate is
self-signed, so the browser shows a warning once — accept it.
`http://kmitsuki.42.fr` is not served at all, because nothing listens on port
80.

See [USER_DOC.md](USER_DOC.md) to use and verify the stack, and
[DEV_DOC.md](DEV_DOC.md) to set it up from scratch or work on it.

## Project description

### Use of Docker

Each service is described by its own `Dockerfile` under
`srcs/requirements/<service>/`, and all three are built by `docker compose`,
which is only ever invoked through the `Makefile`.

A container runs exactly one service, and that service is **PID 1**. Both
init scripts end with `exec`, so the signal sent by `docker stop` reaches the
daemon itself. There is no `tail -f`, no `sleep infinity`, no `while true` and
no background process keeping a container alive artificially. The only loop in
the project is a bounded `for i in $(seq 1 60)` that waits for MariaDB and
always terminates.

Sources included in the project:

- `srcs/docker-compose.yml` — services, network, named volumes.
- `srcs/.env` — every configuration value and credential (never committed).
- `srcs/.env.example` — the committed template listing every variable.
- `srcs/requirements/*/Dockerfile` — the three image definitions.
- `srcs/requirements/*/conf/` — NGINX vhost, MariaDB server config, PHP-FPM pool.
- `srcs/requirements/*/tools/init.sh` — first-boot provisioning, the WordPress
  installation, then `exec`.

### Main design choices

- **Debian bookworm** for all three images: the penultimate stable release, and
  the same distribution as the host, which keeps package names and paths
  predictable.
- **Idempotent init scripts.** Each one first asks whether the work has already
  been done — `/var/lib/mysql/mysql` for the database, `wp-config.php` for the
  files, and `wp core is-installed`, which asks the database rather than the
  filesystem, for the site itself. On the first boot they provision; on every
  later boot they go straight to `exec`. This is what makes persistence work,
  and it is why `make clean` can delete every container, image and volume
  without losing the site.
- **WordPress is installed from the command line, not the browser.** `wp-cli`
  runs `wp core install` and creates the second account from the values in
  `srcs/.env`, so a stack brought up on an empty data directory is a configured
  site rather than a setup wizard. The step is skipped whenever the database
  already holds an installation.
- **`--skip-test-db` when initialising MariaDB.** Without it,
  `mysql_install_db` creates anonymous accounts and a `test` database. The
  anonymous accounts are what would let `mariadb -u root` succeed with no
  password at all.
- **The database host variable is called `DB_HOST`, not `MYSQL_HOST`.**
  `MYSQL_HOST` is read by the MariaDB *client* as its default host; since
  `env_file` hands the same file to every service, that name would make
  `mariadb -uroot` inside the database container connect over TCP to itself
  instead of using the local socket, and the session would be matched as
  `root@<container-ip>` rather than `root@localhost`.
- **WordPress security keys are generated at first boot** from `/dev/urandom`,
  so the eight `AUTH_KEY` / `*_SALT` constants are unique per installation
  instead of the placeholder string shipped in `wp-config-sample.php`.
- **`fclean` preserves `/home/kmitsuki/data`.** The site content is the result
  of real work; a single mistyped target should not be able to destroy it.
  Removing the data is a deliberate, manual `rm -rf`.
- **No password in any Dockerfile or image layer**, and `srcs/.env` is listed in
  `.gitignore` so no credential is ever committed.

### Virtual Machines vs Docker

A virtual machine virtualises *hardware*: the hypervisor gives each guest
virtual CPUs, memory and disks, and the guest boots its own kernel and a
complete operating system. Isolation is excellent, but every guest duplicates
gigabytes of disk, hundreds of megabytes of RAM, and tens of seconds of boot
time.

A container virtualises the *operating system*. All containers share the host
kernel and are isolated by kernel features: namespaces (pid, net, mnt, uts, ipc,
user) restrict what a process can see, cgroups restrict what it can consume, and
a union filesystem gives it its own root. The image ships only userland
libraries and binaries, so a container starts in milliseconds, weighs megabytes,
and is reproducible from a `Dockerfile`.

The trade-off is that a shared kernel means weaker isolation than a hypervisor.
This project runs Docker *inside* a VM precisely because the two are
complementary: the VM provides the machine boundary, containers provide
per-service isolation and reproducibility inside it.

### Secrets vs Environment Variables

Environment variables are convenient and universally supported, but they leak.
They appear in `docker inspect`, they can be read from `/proc/<pid>/environ` by
anyone able to read it, they are baked permanently into an image layer when set
with `ENV`, and they are inherited automatically by every child process.

Docker secrets avoid all of that by mounting the value as a read-only file under
`/run/secrets/<name>`, on a tmpfs that never touches the disk, and only inside
the containers that declare it.

This project uses an `.env` file, which the subject makes mandatory, and keeps
that file out of the repository entirely: `srcs/.env` is listed in `.gitignore`,
and only `srcs/.env.example` — a template with no values — is committed. So no
credential is ever pushed, which is the property that actually matters. The
variables are passed with `env_file:` rather than `ENV`, so nothing is written
into an image layer either.

The remaining exposure is `docker inspect` on the running host, which is the
gap Docker secrets would close. The reason for not using them here is that the
variables are also plain configuration (database name, user names, host name),
and splitting one file into "config in `.env`, credentials in `secrets/`" adds a
second mechanism without removing the `.env` the subject requires.

### Docker Network vs Host Network

`network_mode: host` removes network namespacing entirely: the container binds
directly on the host interfaces. Every port a container opens becomes a host
port, two containers can no longer use the same port number, and nothing
prevents the outside world from reaching MariaDB.

A user-defined bridge network is a private, isolated segment with its own subnet
and an embedded DNS server. That embedded DNS is why `wordpress` reaches the
database at the hostname `mariadb` and why NGINX reaches PHP-FPM at
`wordpress:9000` — no IP addresses, no `links:`, and nothing breaks when Docker
hands out different addresses after a restart.

Nothing is reachable from the host unless it is explicitly published, and only
`nginx` publishes `443:443`. That single line is what makes "NGINX is the only
entrypoint" true by construction rather than by convention.

### Docker Volumes vs Bind Mounts

A bind mount attaches an arbitrary host path into a container. It is tied to the
host filesystem layout, it inherits host ownership and permissions, and Docker
does not manage its lifecycle — `docker volume ls` does not know it exists.

A named volume is a first-class Docker object: created, listed, inspected and
removed through the Docker API, and referenced by name rather than by path. This
project uses two named volumes, `mariadb_data` and `wordpress_data`, declared in
the top-level `volumes:` section — never an inline host path on a service.

The subject additionally requires their data to live under
`/home/kmitsuki/data`. That is expressed with `driver_opts` on the *volume
object*, which is how the `local` driver is told where to put its data:

```yaml
volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/kmitsuki/data/mariadb
```

The volume stays a named, Docker-managed object — `docker volume inspect
srcs_mariadb_data` lists it and reports the required path — while its bytes land
exactly where the subject asks. Because the bytes live outside Docker's own
storage, `docker volume rm` removes the volume object without touching the
content, which is what makes the data survive a full teardown.

## Resources

- Docker documentation — <https://docs.docker.com/>
- Compose file reference — <https://docs.docker.com/reference/compose-file/>
- Dockerfile best practices — <https://docs.docker.com/build/building/best-practices/>
- Debian packages — <https://packages.debian.org/bookworm/>
- MariaDB knowledge base — <https://mariadb.com/kb/en/documentation/>
- `mysql_install_db` options — <https://mariadb.com/kb/en/mysql_install_db/>
- MariaDB authentication plugins — <https://mariadb.com/kb/en/authentication-plugin-unix-socket/>
- NGINX `ngx_http_ssl_module` — <https://nginx.org/en/docs/http/ngx_http_ssl_module.html>
- NGINX `try_files` — <https://nginx.org/en/docs/http/ngx_http_core_module.html#try_files>
- PHP-FPM configuration — <https://www.php.net/manual/en/install.fpm.configuration.php>
- WordPress `wp-config.php` — <https://developer.wordpress.org/apis/wp-config-php/>
- `namespaces(7)`, `cgroups(7)`, `signal(7)` — Linux man pages

### Use of AI

AI was used for three things. It was not used as a code generator — every file
in `srcs/` was written by hand, and every change was verified by hand
afterwards.

- **Looking things up.** Debian bookworm package names for the PHP extensions,
  the current `mysql_install_db` options, what Debian's
  `snippets/fastcgi-php.conf` actually includes, and wording checks on the
  subject and the evaluation sheet. Always confirmed against the official
  documentation.
- **Debugging when I got stuck.** Three problems where I could see the symptom
  but not the cause: `mariadb -u root` succeeding without a password, the eight
  WordPress security keys still holding their placeholder value, and every page
  but the home page returning `404` once permalinks were enabled. AI helped me
  form a hypothesis; I reproduced each one and wrote the fix myself.
- **Documentation.** Section structure and English translation of `README.md`,
  `USER_DOC.md` and `DEV_DOC.md`.
