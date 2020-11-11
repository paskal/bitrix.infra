FROM nginx:1.18

LABEL name=paskal/jsonresume
LABEL maintainer="paskal.07@gmail.com"

# workaround for cases installed nginx is not the same version libnginx-mod-pagespeed depend upon
RUN \
    echo "deb https://nginx.org/packages/debian/ buster nginx" >> /etc/apt/sources.list.d/nginx.list \
    && echo "deb-src https://nginx.org/packages/debian/ buster nginx" >> /etc/apt/sources.list.d/nginx.list

# install libnginx-mod-pagespeed
RUN \
    apt-get update > dev/null \
    && curl -s https://packagecloud.io/install/repositories/DaryL/libnginx-mod-pagespeed/script.deb.sh | bash \
    && apt-get install -y nginx libnginx-mod-pagespeed \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /etc/nginx/conf.d/*

# run nginx with configuration reload once in every 6 hours
CMD /bin/sh -c 'while :; do /bin/sleep 6h & wait ${!}; /usr/sbin/nginx -s reload; done & /usr/sbin/nginx -g "daemon off;"'
