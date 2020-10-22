## Certificate renewal

To renew the certificate, run the following command and follow the interactive promt:

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

