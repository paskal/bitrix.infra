#!/bin/sh

# Create TXT record
RECORD_ID=$(curl -s -X POST "https://pddimp.yandex.ru/api2/admin/dns/add" \
     -H "PddToken: $API_KEY" \
     -d "domain=$CERTBOT_DOMAIN&type=TXT&content=$CERTBOT_VALIDATION&ttl=300&subdomain=_acme-challenge" \
	 | python -c "import sys,json;print(json.load(sys.stdin)['record']['record_id'])")

# Save info for cleanup
echo $RECORD_ID > /tmp/CERTBOT_$CERTBOT_DOMAIN

# Sleep to make sure the change has time to propagate over to DNS
sleep 4800
