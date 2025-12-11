# Bitrix infrastructure as a code [![Build Status](https://github.com/paskal/bitrix.infra/workflows/build/badge.svg)](https://github.com/paskal/bitrix.infra/actions/workflows/ci-build.yml) [![PHP Build Status](https://github.com/paskal/bitrix.infra/workflows/build-php/badge.svg)](https://github.com/paskal/bitrix.infra/actions/workflows/ci-build-php.yml) [![Pull Status](https://github.com/paskal/bitrix.infra/workflows/pull/badge.svg)](https://github.com/paskal/bitrix.infra/actions/workflows/ci-pull.yml)

This repository contains infrastructure code behind Bitrix-based [site](https://favor-group.ru) of my father's metal decking business operating in multiple cities.

It's a Bitrix website completely enclosed within docker-compose to be as portable and maintainable as possible, and a set of scripts around its maintenance like dev site redeploy or production site backup.

## Is it fast?

You bet! Here is a performance on Yandex.Cloud server with Intel Cascade Lake 8 vCPUs, 16Gb of RAM and 120Gb SSD 4000 read\write IOPS and 60Mb/s bandwidth.

<img width="1100" alt="image" src="https://user-images.githubusercontent.com/712534/172490266-88710b9f-3776-4c5b-9852-590181d1d204.png">

## Getting Started

Follow these steps to get your Bitrix environment up and running:

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/paskal/bitrix.infra.git
    cd bitrix.infra
    ```

2.  **Create Environment Files:**
    Navigate to the `private/environment/` directory. You will need to create several environment files based on the templates or examples provided. These include:
    *   `mysql.env`
    *   `ftp.env`
    *   `dnsrobocert.env` (Note: this file is for the `certbot` service, which uses DNSroboCert technology)
    *   `zabbix.env`
    *   `updater.env`
    Detailed information about the required variables for each file can be found in the "[File structure > /private > private/environment](#privateenvironment)" section of this Readme.

3.  **Set File Permissions:**
    Before starting the containers for the first time, it's crucial to set the correct file and directory permissions. Run the provided script:
    ```bash
    sudo ./scripts/fix-rights.sh
    ```
    This script ensures that services like MySQL, PHP, and Nginx have the necessary access rights. See the "[File system permissions](#file-system-permissions)" section for more details.

4.  **Start the Services:**
    Use Docker Compose to start the services. For a basic setup with only core services, run:
    ```bash
    docker-compose up -d
    ```
    This project primarily uses pre-built Docker images from a container registry (like GitHub Container Registry - GHCR). Therefore, running `docker-compose build` or adding the `--build` flag is generally not necessary for standard usage. Docker Compose will automatically pull the specified images if they are not present locally. You would typically only need to use `--build` if you have made custom modifications to the Dockerfiles and need to rebuild the images locally.

    To manage optional services, refer to the "[Managing Optional Services with Profiles](#managing-optional-services-with-profiles)" section.

## How to make use of it

You couldn't use it as-is without alterations. However, I tried to make everything as generic as possible to make adoption for another project easy. To use it, read through [docker-compose.yml](docker-compose.yml)
and then read the rest of this Readme. For information about maintenance and utility scripts, see [scripts/README.md](scripts/README.md).

[bitrixdock](https://github.com/bitrixdock/bitrixdock) (Russian) project was an inspiration for this one and had way better setup instructions. Please start with it if you don't know what to do with many files in that repo.

### File system permissions

All files touched by MySQL use UID/GID 1001, and PHP and Nginx use UID/GID 1000.
**It is crucial to run the `sudo ./scripts/fix-rights.sh` script after cloning the repository and creating your environment files, and before running `docker-compose up` for the first time.** This script sets the permissions appropriately for all containers to run correctly.

It might be easier to switch everything to User and Group 1000 for consistency later.

### Relevant parts of Bitrix config

Documentation: sessions [1](https://training.bitrix24.com/support/training/course/?COURSE_ID=68&LESSON_ID=24868) [2](https://training.bitrix24.com/support/training/course/?COURSE_ID=68&LESSON_ID=24870) (ru [1](https://dev.1c-bitrix.ru/learning/course/index.php?COURSE_ID=43&LESSON_ID=14026&LESSON_PATH=3913.3435.4816.14028.14026), [2](https://dev.1c-bitrix.ru/learning/course/?COURSE_ID=32&LESSON_ID=9421)), [cache](https://training.bitrix24.com/support/training/course/?COURSE_ID=68&CHAPTER_ID=05962&LESSON_PATH=5936.5959.5962) ([ru](https://dev.1c-bitrix.ru/learning/course/?COURSE_ID=43&LESSON_ID=2795))

<details><summary>bitrix/php_interface/dbconn.php</summary>

```php
// Enable cron-based agent execution
define('BX_CRONTAB_SUPPORT', true);

// Database connection (legacy, also configured in .settings.php)
$DBType = "mysql";
$DBHost = "localhost";
$DBName = "<DBNAME>";
$DBLogin = "<DBUSER>";
$DBPassword = "<DBPASSWORD>";

// Temporary files directory
define('BX_TEMPORARY_FILES_DIRECTORY', '/tmp');

// Standard Bitrix configuration
define("BX_UTF", true);
define("BX_FILE_PERMISSIONS", 0644);
define("BX_DIR_PERMISSIONS", 0755);
@umask(~(BX_FILE_PERMISSIONS|BX_DIR_PERMISSIONS)&0777);
define("BX_DISABLE_INDEX_PAGE", true);
```

</details>

<details><summary>bitrix/.settings.php</summary>

```php
  'session' => array (
  'value' =>
  array (
    'mode' => 'separated',
    'lifetime' => 14400,
    'handlers' =>
    array (
      'kernel'  => 'encrypted_cookies',
      'general' =>
      array (
        'type' => 'memcache',
        'host' => 'memcached-sessions',
        'port' => '11211',
      ),
    ),
  ),
  'readonly' => true,
  ),
  'connections' =>
  array (
    'value' =>
    array (
      'default' =>
      array (
        'className' => '\\Bitrix\\Main\\DB\\MysqliConnection',
        'host' => 'localhost',
        'database' => '<DBNAME>',
        'login' => '<DBUSER>',
        'password' => '<DBPASSWORD>',
        'options' => 3,
      ),
    ),
    'readonly' => true,
  ),
```

</details>

<details><summary>bitrix/.settings_extra.php</summary>

```php
<?php
return array(
  'cache' => array(
    'value' => array(
      // For PHP 8.0+ use memcached instead of deprecated memcache.
      // The php-memcached extension is actively maintained, works with libmemcached
      // and provides better performance on modern PHP versions.
      'type' => 'memcached',
      'memcached' => array(
        'host' => 'memcached',
        'port' => '11211',
      ),

      // The igbinary serializer reduces cache size by ~50% compared to
      // the standard PHP serializer and is faster at deserialization.
      // Value 2 = Memcached::SERIALIZER_IGBINARY
      // Requires php-igbinary extension to be installed
      'serializer' => 2,

      // Lock mode (use_lock) prevents simultaneous cache regeneration
      // by multiple processes. Under high load, only one process
      // generates cache, others receive stale data.
      // Requires Bitrix main module version 24.0.0 or higher.
      // More info: https://dev.1c-bitrix.ru/learning/course/?COURSE_ID=43&LESSON_ID=3485
      'use_lock' => true,

      'sid' => $_SERVER["DOCUMENT_ROOT"]."#01"
    ),
  ),
);
?>
```

</details>

## What's inside?

### Core

- [Nginx](https://www.nginx.com/) [![Image Size](https://img.shields.io/docker/image-size/paskal/nginx)](https://hub.docker.com/r/paskal/nginx) with [brotli](https://github.com/google/ngx_brotli) proxying requests to php-fpm and serving static assets directly
- [php-fpm](https://www.php.net/manual/en/install.fpm.php) (7 [![Image Size 7](https://img.shields.io/docker/image-size/paskal/bitrix-php/7)](https://hub.docker.com/r/paskal/bitrix-php) 8 [![Image Size 8](https://img.shields.io/docker/image-size/paskal/bitrix-php/8)](https://hub.docker.com/r/paskal/bitrix-php) 8.1 [![Image Size 8.1](https://img.shields.io/docker/image-size/paskal/bitrix-php/8.1)](https://hub.docker.com/r/paskal/bitrix-php) 8.2 [![Image Size 8.2](https://img.shields.io/docker/image-size/paskal/bitrix-php/8.2)](https://hub.docker.com/r/paskal/bitrix-php) 8.3 [![Image Size 8.3](https://img.shields.io/docker/image-size/paskal/bitrix-php/8.3)](https://hub.docker.com/r/paskal/bitrix-php) 8.4 [![Image Size 8.4](https://img.shields.io/docker/image-size/paskal/bitrix-php/8.4)](https://hub.docker.com/r/paskal/bitrix-php)) for bitrix with msmtp for mail sending
- [Percona MySQL](https://www.percona.com/software/mysql-database/percona-server) [![Image Size](https://img.shields.io/docker/image-size/percona/percona-server/8.0)](https://hub.docker.com/r/percona/percona-server) because of it's monitoring capabilities
- [memcached](https://memcached.org/) [![Image Size](https://img.shields.io/docker/image-size/_/memcached/1-alpine)](https://hub.docker.com/r/_/memcached) for bitrix cache and user sessions

### Optional

- PHP cron container (`php-cron`) with same settings as PHP serving web requests
- [adminer](https://www.adminer.org/) (`adminer`) [![Image Size](https://img.shields.io/docker/image-size/_/adminer)](https://hub.docker.com/r/_/adminer) as phpmyadmin alternative for work with MySQL
- [pure-ftpd](https://www.pureftpd.org/project/pure-ftpd/) (`ftp`) [![Image Size](https://img.shields.io/docker/image-size/stilliard/pure-ftpd)](https://hub.docker.com/r/stilliard/pure-ftpd) for ftp access
- [DNSroboCert](https://github.com/adferrand/dnsrobocert) (`certbot`) [![Image Size](https://img.shields.io/docker/image-size/adferrand/dnsrobocert)](https://hub.docker.com/r/adferrand/dnsrobocert) for Let's Encrypt HTTPS certificate generation using the `adferrand/dnsrobocert` image.
- [zabbix-agent2](https://www.zabbix.com/zabbix_agent) (`zabbix-agent`) [![Image Size](https://img.shields.io/docker/image-size/paskal/zabbix-agent2)](https://hub.docker.com/r/paskal/zabbix-agent2) for monitoring
- Webhooks server (`updater`) for automated tasks.

## File structure

### /config

- `cron/php-cron.cron` is a list of cron tasks to run in php-cron container, only `cron_events.php` is required for Bitrix and others are specific to this site,
  [must](https://manpages.ubuntu.com/manpages/jammy/man8/cron.8.html) be owned by root:root and have access rights 0644 - fixable by running `scripts/fix-rights.sh`

- `cron/host.cron` is a list of cron tasks to run on the host machine

- `mysql/my.cnf` is a MySQL configuration, applied on top of package-provided my.cnf

- `nginx` directory contains the build Dockerfile, as well as following (HTTPS) configuration:
    - bitrix proxy, separate for dev and prod
    - adminer proxy
    - HTTP to HTTPS redirects
    - stub status page listening on localhost for Zabbix monitoring

- `php` directory contains the build Dockerfiles (e.g., `Dockerfile.8.1`, `Dockerfile.8.2`, `Dockerfile.8.3`, `Dockerfile.8.4`) and php configuration, applied on top of package-provided one.

### /logs

`mysql`, `nginx`, `php` logs. cron and msmtp logs will be written to the `php` directory.

### /scripts

Maintenance and utility scripts for the infrastructure. See [scripts/README.md](scripts/README.md) for detailed documentation of each script.

### /web

Site files in directories `web/prod` and `web/dev`.

<span id="privateenvironment"></span>
### /private

- `private/environment` is a directory with environment files for docker-compose

    - `private/environment/mysql.env` should contain the [following variables](https://hub.docker.com/r/percona/percona-server):

      ```bash
      MYSQL_ROOT_PASSWORD=mysql_root_password
      MYSQL_USER=bitrix_user
      MYSQL_PASSWORD=bitrix_mysql_password
      ```

    - `private/environment/ftp.env` should contain the [following variables](https://hub.docker.com/r/stilliard/pure-ftpd):

      ```bash
      FTP_USER_NAME=ftp_username
      FTP_USER_PASS=ftp_password
      ```

    - `private/environment/dnsrobocert.env` should contain Yandex Cloud DNS API key for the `certbot` service (which uses the [adferrand/dnsrobocert](https://hub.docker.com/r/adferrand/dnsrobocert) image):

      ```
      # Run `yc components update` once to get the key, and `update-dns-token.sh` script will renew it automatically afterwards
      AUTH_KEY=insert_key_there
      DNS_ZONE_ID=insert_zone_id_there
      ```
    - `private/environment/updater.env` should contain a secret key for the updater service:
      ```bash
      KEY=your_secret_key_here
      ```

  - `private/environment/zabbix.env` should contain the [following variables](https://hub.docker.com/r/zabbix/zabbix-agent2):

    ```bash
    ZBX_HOSTNAME=myhostname
    ZBX_SERVER_HOST=zabbix.example.com
    ```

    MySQL setup if you want to use Zabbix for monitoring of the database:
    ```sql
    drop user if exists 'zbx_monitor'@'localhost';
    create user if not exists `zbx_monitor`@`localhost` identified by 'generate_random_password_here';
    grant process, replication client, show databases, show view on *.* to `zbx_monitor`@`localhost`;
    ```

- `private/letsencrypt` directory will be filled with certificates after the `certbot` service (using DNSroboCert technology) runs.

- `private/mysql-data` directory will be filled with database data automatically after the start of mysql container

- `private/mysqld` directory will contain MySQL unix socket for connections without network

- `private/msmtprc` is a file with [msmtp configuration](https://wiki.archlinux.org/index.php/Msmtp)

## Managing Optional Services with Profiles

This project uses Docker Compose profiles to manage optional services. This allows you to run only the services you need, saving resources. The core services (`nginx`, `php`, `php-cron`, `mysql`, `memcached`, `memcached-sessions`) will always start.

**⚠️ Breaking Change Notice**: If you were previously running services like `adminer`, `zabbix-agent`, `updater`, or `ftp`, they will no longer start automatically with `docker-compose up -d`. You must now explicitly enable them using profiles (see examples below) or set the `COMPOSE_PROFILES` environment variable.

Here are the available profiles and the services they enable:

*   **`certs`**: Enables the `certbot` service (using DNSroboCert technology via the `adferrand/dnsrobocert` image) for managing SSL certificates.
*   **`monitoring`**: Enables `zabbix-agent` for Zabbix monitoring.
*   **`dbadmin`**: Enables `adminer` for database administration.
*   **`hooks`**: Enables `updater` for handling webhooks.
*   **`ftp`**: Enables `ftp` for FTP access.

**Examples:**

*   To run only the core services:
    ```bash
    docker-compose up -d
    ```

*   To run core services plus `adminer` and `ftp`:
    ```bash
    docker-compose --profile dbadmin --profile ftp up -d
    ```

*   Alternatively, you can set profiles using the `COMPOSE_PROFILES` environment variable:
    ```bash
    COMPOSE_PROFILES=dbadmin,ftp docker-compose up -d
    ```
    Or export it for the session:
    ```bash
    export COMPOSE_PROFILES=dbadmin,ftp
    docker-compose up -d
    ```

*   To run all services, including all defined profiles:
    ```bash
    docker-compose --profile "*" up -d
    ```
    As mentioned in "Getting Started," this project uses pre-built images. If you've made custom changes to Dockerfiles or need to ensure you have the absolute latest build not yet reflected in the pre-built images, you can add the `--build` flag (e.g., `docker-compose --profile "*" up --build -d`).

## Advanced Usage

### Switching PHP Versions

This project is configured to support multiple PHP versions. Dockerfiles for different versions (e.g., 8.1, 8.2, 8.3, 8.4) are available in the `config/php/` directory.

To switch the PHP version used by the `php` and `php-cron` services:

1.  **Edit `docker-compose.yml`:**
    *   Locate the `php` service definition.
    *   Modify the `build.context` and `build.dockerfile` to point to the desired Dockerfile. For example, to switch to PHP 8.4:
        ```yaml
        php:
          build:
            context: ./config/php
            dockerfile: Dockerfile.8.4 # Changed from Dockerfile.8.3
          image: ghcr.io/paskal/bitrix-php:8.4 # Update image tag
          # ... rest of the service definition
        ```
    *   Repeat the same changes for the `php-cron` service definition, ensuring the `image` tag is also updated.

2.  **Rebuild the PHP images:**
    This is a scenario where you *would* need to build the images:
    ```bash
    docker-compose build php php-cron
    # Or, if you are starting the services at the same time:
    # docker-compose up -d --build php php-cron 
    # (or simply 'docker-compose up -d --build' if you want to ensure all buildable services are updated)
    ```
    After building, you can start the services as usual:
    ```bash
    docker-compose up -d
    ```


For a more dynamic approach to switching PHP versions, you could consider:
*   Using an environment variable (e.g., `PHP_VERSION`) in your `docker-compose.yml` to specify the Dockerfile path and image tag. You would then set this variable in your shell or a `.env` file.
*   Utilizing Docker Compose override files to specify different PHP configurations.

## Routine operations

<details>
<summary>Disaster recovery</summary>

To start the recovery you should have a machine with the latest Ubuntu with static external IP with DDoS protection attached to it, created [in the Yandex.Cloud](https://console.cloud.yandex.ru/folders/b1gm2f812hg4h5s5jsgn/compute). It should be created with 100Gb of disk space, 12Gb of RAM and 8 cores.

SSH to the machine you want to set up as a new server and then execute the following, then follow the instructions of the script:

```shell
# that is preparation for backup restoration
sudo mkdir -p /web
sudo chown $USER:$(id -g -n) /web
sudo apt-get update >/dev/null
sudo apt-get -y install git >/dev/null
git clone https://github.com/paskal/bitrix.infra.git /web
cd /web
# backup restoration, it's safe to run it multiple times
sudo ./scripts/disaster-recovery.sh
```

</details>


<details>
<summary>Recovery of files</summary>

Presume you have a machine with problems, and you want to roll back the changes:

```shell
# restore to directory /web/prod2
# -t 2D means restore from the backup made 2 days
# last argument /web/web/prod2 is the directory to restore to, we're not restoring to the original dir
# so that you can rename it first and then rename this directory to prod
sudo HOME="/home/$(logname)" duplicity -t 2D \
    --no-encryption \
    --s3-endpoint-url https://storage.yandexcloud.net \
    --log-file /web/logs/duplicity.log \
    --archive-dir /root/.cache/duplicity \
    --file-to-restore web/prod  "boto3+s3://favor-group-backup/duplicity_web_favor-group" /web/web/prod2
```
</details>

<details>
<summary>Dev site renewal from backup</summary>

The `renew-dev.sh` script can recreate the dev site either from current production or from an existing backup.

**From current production (default):**
```shell
sudo ./scripts/renew-dev.sh
```

**From a specific backup date:**
```shell
sudo ./scripts/renew-dev.sh --date
```

When using `--date`, the script will:
1. List available backup dates from `/web/backup/`
2. Prompt you to select a date (format: YYYY-MM-DD)
3. List available backup files for that date
4. Prompt you to select a specific backup file
5. Restore the database from that backup instead of creating a new dump

This is useful for:
- Testing changes against historical data
- Reverting problematic database changes by comparing with old backups
- Debugging issues that appeared after a specific date

**Example workflow for reverting SEO changes:**
```shell
# 1. Restore dev from a backup before the problematic change
sudo ./scripts/renew-dev.sh --date
# Select 2025-10-31 (or earlier backup)

# 2. Use the LLM revert tool at https://favor-group.ru/local/tools/seo_llm_revert.php
# Enter 'dev_favor_group_ru' as the backup database
# Compare and selectively revert changes
```

</details>

<details>
<summary>Cleaning (mem)cache</summary>

There are two memcached instances in use, one for site cache and another for sessions. Here are the commands to clean them completely:

```shell
# to flush site cache
echo "flush_all" | docker exec -i memcached /usr/bin/nc 127.0.0.1 11211
# to flush all user sessions
echo "flush_all" | docker exec -i memcached-sessions /usr/bin/nc 127.0.0.1 11211
```

[Here](https://github.com/memcached/memcached/wiki/Commands) is the complete list of commands you can send to it.

</details>

<details>
<summary>Manual certificate renewal</summary>

DNS verification of a wildcard certificate is set up automatically through Yandex Cloud DNS via the `certbot` service (which uses DNSroboCert technology via the `adferrand/dnsrobocert` image).

To renew the certificate manually, if needed, you can run the following command which uses the `certbot` command available within the `certbot` service's container (which runs `adferrand/dnsrobocert`):

```shell
# Note: The service is certbot, and the command inside is also certbot
docker-compose run --rm --entrypoint "\
  certbot certonly \
    --email email@example.com \
    -d example.com -d *.example.com \
    --agree-tos \
    --manual \
    --preferred-challenges dns" certbot
```

To add required TXT entries, head to DNS entries page of your provider (Yandex Cloud).
The `certbot` service is configured to handle renewals automatically.

</details>
