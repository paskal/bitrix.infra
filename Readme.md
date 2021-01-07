# [favor-group.ru](https://favor-group.ru) infrastructure as a code

This repository contains infrastructure code behind Bitrix-based [favor-group.ru](https://favor-group.ru), a site
of my father's metal decking business operating in Moscow, Sankt-Petesburg and Tula.

It's a Bitrix web-site completely enclosed within docker-compose to be as portable and maintainable as possible,
as well as set of scripts around its maintenance like dev site redeploy or prouction site backup.

## How to make use of it

It couldn't be used as-is without alterations elsewhere, however I tried to make everything as generic
as possible to make adoption for other project easy. To use it, read trough [docker-compose.yml](docker-compose.yml)
and then read the rest of this Readme.

## What's inside?

- [certbot](https://certbot.eff.org/) for certificate generation
- [Nginx](https://www.nginx.com/) with [pagespeed](https://developers.google.com/speed/pagespeed/module), proxying requests to php-fpm and serving static assets directly
- [php-fpm](https://www.php.net/manual/en/install.fpm.php) for bitrix with msmtp for mail sending
- PHP cron container with same settings as PHP serving web requests
- [Percona MySQL](https://www.percona.com/software/mysql-database/percona-server) because of it's monitoring capabilities
- [adminer](https://www.adminer.org/) as phpmyadmin alternative for work with MySQL
- [Percona Monitoring and Management](https://www.percona.com/doc/percona-monitoring-and-management/2.x/index.html) client for MySQL metrics
- [memcached](https://memcached.org/) for bitrix cache
- [pure-ftpd](https://www.pureftpd.org/project/pure-ftpd/) for ftp access
- [zabbix-agent](https://www.zabbix.com/zabbix_agent) for monitoring

## File structure

### /config

- `cron/tasks.cron` is a list of cron tasks, only `cron_events.php` is required for Bitrix and others are specific to this site

- `mysql/my.cnf` is a MySQL configuration, applied on top of package-provided my.cnf

- `nginx` directory contains build Dockerfile, as well as following (HTTPS) configuration:
  - pagespeed setup
  - bitrix proxy, separate for dev and prod
  - adminer proxy
  - HTTP to HTTPS redirects
  - stub status page listening on localhost for Zabbix monitoring

- `php-fpm` directory contains build Dockerfile and php configuration, applied on top of package-provided one

### /logs

cron, mysql, php, nginx and msmtp logs.

### /scripts

Bunch of scripts, see their source code for purpose and comments.

### /web

Site files, in this case in folders `web/favor-group.ru` and `web/dev.favor-group.ru`.

### /private

- `private/environment` is a directory with environment files for docker-compose

    - `private/environment/mysql.env` should contain `MYSQL_ROOT_PASSWORD`, `MYSQL_USER` and `MYSQL_PASSWORD`.

    - `private/environment/ftp.env` should contain `FTP_USER_NAME`, `FTP_USER_PASS`.

- `private/pmm/pmm-agent.yaml` should contain agent setup which is done according to
  [this doc](https://gist.github.com/paskal/48f10a0a584f4849be6b0889ede9262b).
  Server counterpart sets up by the same doc and is running [there](https://github.com/paskal/terrty/).

- `private/letsencrypt` directory will be filled with certificates after certbot run (see instruction below)

- `private/mysql-data` directory will be filled with database data automatically after the start of mysql container

- `private/mysqlq` directory will contain MySQL unix socket for connections without network

- `private/msmtprc` is a file with [msmtp configuration](https://wiki.archlinux.org/index.php/Msmtp)

## Certificate renewal

At this moment DNS verification of wildcard certificate is not yet set up.
To renew the certificate, run the following command and follow the interactive prompt:

```shell
docker-compose run --rm --entrypoint "\
  certbot certonly \
    --email msk@favor-group.ru \
    -d favor-group.ru -d *.favor-group.ru \
    --agree-tos \
    --manual \
    --preferred-challenges dns" certbot
```

In order to add required TXT entries, head to [DNS edit page](https://fornex.com/my/dns/favor-group.ru/).

## Permissions

Everything touched by MySQL uses UID/GID 1001, and PHP and Nginx uses UID/GID 1000.

It would be easier to switch everything to User and Group 1000 for consistency later.


## Relevant parts of Bitrix config

<details><summary>bitrix/php_interface/dbconn.php</summary>

```php
define('BX_CRONTAB_SUPPORT', true);

define("BX_USE_MYSQLI", true);
define("DBPersistent", true);
define("DELAY_DB_CONNECT", true);
$DBType = "mysql";
$DBHost = "localhost";
$DBName = "<DBNAME>";
$DBLogin = "<DBUSER>";
$DBPassword = "<DBPASSWORD>";
define('BX_TEMPORARY_FILES_DIRECTORY', '/tmp');

define("BX_CACHE_TYPE", "memcache");
define("BX_CACHE_SID", "prod"); // or "dev" in case of dev config
define("BX_MEMCACHE_HOST", "memcached");
define("BX_MEMCACHE_PORT", "11211");
```

</details>

<details><summary>bitrix/.settings.php</summary>

```php
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
        'options' => 2.0,
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
      'type' => 'memcache',
      'memcache' => array(
        'host' => 'memcached',
        'port' => '11211',
      ),
      'sid' => "prod" // or "dev" in case of dev config
    ),
  ),
);
?>
```

</details>
