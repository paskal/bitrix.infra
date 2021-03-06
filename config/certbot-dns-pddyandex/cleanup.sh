#!/bin/sh

if [ -f /tmp/CERTBOT_$CERTBOT_DOMAIN ]; then
        RECORD_ID=$(cat /tmp/CERTBOT_$CERTBOT_DOMAIN)
        rm -f /tmp/CERTBOT_$CERTBOT_DOMAIN
fi

# Remove the challenge TXT record from the zone
if [ -n "${RECORD_ID}" ]; then
	RESULT=$(curl -s -X POST "https://pddimp.yandex.ru/api2/admin/dns/del" \
     -H "PddToken: $API_KEY" \
     -d "domain=$CERTBOT_DOMAIN&record_id=$RECORD_ID" \
	 | python -c "import sys,json;print(json.load(sys.stdin)['success'])")
	echo $RESULT
fi
