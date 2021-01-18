# Build
FROM nginx:1.19.6 as build

WORKDIR /build

# install brotli build dependencies
RUN \
    apt-get update > /dev/null \
    && apt-get install gcc git libpcre3-dev libssl-dev make zlib1g-dev -y

# build brotli
RUN git clone https://github.com/google/ngx_brotli.git --recurse-submodules
RUN git clone https://github.com/nginx/nginx.git

WORKDIR /build/nginx

RUN git checkout release-1.19.6
RUN ./auto/configure \
  --add-dynamic-module=/build/ngx_brotli \
  --with-debug \
  --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx --modules-path=/usr/lib/nginx/modules --conf-path=/etc/nginx/nginx.conf --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp --http-scgi-temp-path=/var/cache/nginx/scgi_temp --user=nginx --group=nginx --with-compat --with-file-aio --with-threads --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_stub_status_module --with-http_sub_module --with-http_v2_module --with-mail --with-mail_ssl_module --with-stream --with-stream_realip_module --with-stream_ssl_module --with-stream_ssl_preread_module --with-cc-opt='-g -O2 -fdebug-prefix-map=/data/builder/debuild/nginx-1.19.6/debian/debuild-base/nginx-1.19.6=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'
RUN make modules

# Run
FROM nginx:1.19.6

LABEL name=paskal/nginx
LABEL maintainer="paskal.07@gmail.com"

# add compiled brotli module
COPY --from=build /build/nginx/objs/ngx_http_brotli_filter_module.so /usr/lib/nginx/modules/
COPY --from=build /build/nginx/objs/ngx_http_brotli_static_module.so /usr/lib/nginx/modules/

RUN usermod -u 1000 nginx
RUN groupmod -g 1000 nginx

# run nginx with configuration reload once in every 6 hours
CMD /bin/sh -c 'while :; do /bin/sleep 6h & wait ${!}; /usr/sbin/nginx -s reload; done & /usr/sbin/nginx -g "daemon off;"'
