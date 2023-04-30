FROM zabbix/zabbix-agent2:latest

LABEL org.opencontainers.image.authors="Dmitry Verkhoturov <paskal.07@gmail.com>" \
      org.opencontainers.image.description="Zabbix Agent 2 with installed myqsl-client" \
      org.opencontainers.image.source="https://github.com/paskal/bitrix.infra.git"

USER 0

# mysql-client needed for executing SQL commands for logical checks on the database content
# mariadb-connector-c is needed to mitigate this error with newer MySQL 8 auth method:
# ERROR 1045 (28000): Plugin caching_sha2_password could not be loaded: Error loading shared library /usr/lib/mariadb/plugin/caching_sha2_password.so: No such file or directory
RUN apk add --no-cache mysql-client mariadb-connector-c

USER 1997
