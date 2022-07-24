FROM zabbix/zabbix-agent2:latest

LABEL org.opencontainers.image.authors="Dmitry Verkhoturov <paskal.07@gmail.com>" \
      org.opencontainers.image.description="Zabbix Agent 2 with installed myqsl-client" \
      org.opencontainers.image.source="https://github.com/paskal/bitrix.infra.git"

USER 0

RUN apk add --no-cache mysql-client

USER 1997
