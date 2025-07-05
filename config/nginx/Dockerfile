FROM alpine:edge

LABEL org.opencontainers.image.authors="Dmitry Verkhoturov <paskal.07@gmail.com>" \
      org.opencontainers.image.description="nginx with brotli installed and running as non-root user, with reload for cert renewal once in six hours" \
      org.opencontainers.image.documentation="https://github.com/paskal/bitrix.infra" \
      org.opencontainers.image.source="https://github.com/paskal/bitrix.infra" \
      org.opencontainers.image.title="bitrix-nginx" \
      org.opencontainers.image.vendor="Dmitry Verkhoturov"

# for shadow package
RUN echo https://dl-2.alpinelinux.org/alpine/edge/community/ >> /etc/apk/repositories

# shadow for usermod
# brotli for compression
RUN apk add --no-cache nginx-mod-http-brotli nginx-mod-http-lua shadow

RUN usermod -u 1000 nginx
RUN groupmod -g 1000 nginx

# run nginx with configuration reload once in every 6 hours
CMD /bin/sh -c 'while :; do /bin/sleep 6h & wait ${!}; /usr/sbin/nginx -s reload; done & /usr/sbin/nginx -g "daemon off;"'
