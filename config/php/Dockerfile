FROM phpdockerio/php74-fpm:latest
# https://github.com/bitrixdock/bitrixdock/blob/master/php74/Dockerfile

RUN apt-get update \
    && apt-get -y --allow-downgrades --no-install-recommends install \
    php7.4-memcached \
    php7.4-memcache \
    php7.4-mbstring \
    php7.4-mysql \
    php7.4-intl \
    php7.4-interbase \
    php7.4-soap \
    php7.4-gd \
    php7.4-imagick \
    php7.4-opcache \
    php7.4-zip \
    php-pear php7.4-dev libmcrypt-dev gcc make autoconf libc-dev pkg-config \
    msmtp \
    msmtp-mta \
    sudo \
    cron \
    && pecl install mcrypt-1.0.4 \
    && apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/*

# msmtp to allow email sending
# msmtp-mta to allow sendmail usage with msmtp
# sudo to allow create logfile with www-data user
# cron to run cronjobs in a separate container

RUN usermod -u 1000 www-data
RUN groupmod -g 1000 www-data

EXPOSE 9000
