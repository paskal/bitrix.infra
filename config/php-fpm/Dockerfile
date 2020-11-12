FROM phpdockerio/php74-fpm:latest
# https://github.com/bitrixdock/bitrixdock/blob/master/php74/Dockerfile

RUN apt-get update \
    && apt-get -y --no-install-recommends install \
    php7.4-memcached \
    php7.4-memcache \
    php7.4-mbstring \
    php7.4-mysql \
    php7.4-intl \
    php7.4-xdebug \
    php7.4-interbase \
    php7.4-soap \
    php7.4-gd \
    php7.4-imagick \
    php7.4-opcache \
    php7.4-zip \
    php-pear php-dev libmcrypt-dev gcc make autoconf libc-dev pkg-config \
    && pecl install mcrypt-1.0.3 \
    && apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/*

EXPOSE 9000