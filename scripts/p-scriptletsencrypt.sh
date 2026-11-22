#!/bin/bash

# cargamos las variables del .env quitandole antes los finales de linea de windows (\r)
# set -a hace que todas las variables que cargamos se exporten solas
set -a
source <(sed 's/\r$//' /vagrant/scripts/.env)
# desactivamos la importacion de variables
set +a

# si no hay token en la variable de entorno paramos y avisamos
# el token se exporta en powershell antes de "vagrant up" como se dice en el vagrantfile
# set -e hace que el script se pare en el primer error para no activar https sin certificado
set -e

if [ -z "${DUCKDNS_TOKEN:-}" ]; then
    echo "Exporta DUCKDNS_TOKEN en PowerShell con: \$env:DUCKDNS_TOKEN = \"tu_token_de_duckdns\" y vuelve a ejecutar este aprovisionamiento"
    exit 1
fi


# actualizamos la lista de paquetes e instalamos certbot (cliente de let's encrypt)
# y curl (lo usan los hooks para hablar con duckdns)
apt-get update
apt-get install -y certbot curl


# guardamos el token en un fichero con permisos solo para root
DIR_HOOKS=/etc/letsencrypt/duckdns
mkdir -p $DIR_HOOKS
echo "$DUCKDNS_TOKEN" > $DIR_HOOKS/token
chmod 600 $DIR_HOOKS/token


# creamos el hook de autenticacion, un script que certbot ejecuta automaticamente
# cuando let's encrypt nos pide demostrar que el dominio es nuestro-->
# certbot le pasa un valor (CERTBOT_VALIDATION) que tenemos que publicar como registro TXT
# en el dominio, y este script lo publica en duckdns usando el token
cat > $DIR_HOOKS/auth.sh <<'EOF'
#!/bin/bash
TOKEN=$(cat /etc/letsencrypt/duckdns/token)
SUBDOMINIO="${CERTBOT_DOMAIN%.duckdns.org}"
RESPUESTA=$(curl -s "https://www.duckdns.org/update?domains=${SUBDOMINIO}&token=${TOKEN}&txt=${CERTBOT_VALIDATION}")
if [ "$RESPUESTA" != "OK" ]; then
    echo "error al actualizar duckdns--> $RESPUESTA"
    exit 1
fi
# en vez de esperar un tiempo fijo, comprobamos cada 15 segundos si google y cloudflare
# ya ven el TXT nuevo (maximo 10 minutos), asi let's encrypt no lo encuentra vacio
for i in $(seq 1 40); do
    G=$(curl -s "https://dns.google/resolve?name=_acme-challenge.${CERTBOT_DOMAIN}&type=TXT")
    C=$(curl -s -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=_acme-challenge.${CERTBOT_DOMAIN}&type=TXT")
    if echo "$G" | grep -q "$CERTBOT_VALIDATION" && echo "$C" | grep -q "$CERTBOT_VALIDATION"; then
        echo "TXT visible tras $((i*15)) segundos"
        # margen extra para el resto de servidores dns
        sleep 30
        exit 0
    fi
    sleep 15
done
echo "el TXT no se ha propagado en 10 minutos"
exit 1
EOF

# hook de limpieza--> borra el registro TXT al terminar
cat > $DIR_HOOKS/cleanup.sh <<'EOF'
#!/bin/bash
TOKEN=$(cat /etc/letsencrypt/duckdns/token)
SUBDOMINIO="${CERTBOT_DOMAIN%.duckdns.org}"
curl -s "https://www.duckdns.org/update?domains=${SUBDOMINIO}&token=${TOKEN}&txt=removed&clear=true" || true
EOF

# le damos permisos de ejecucion a ambos scripts
chmod +x $DIR_HOOKS/auth.sh $DIR_HOOKS/cleanup.sh


# pedimos el certificado a let's encrypt con la prueba dns-01-->
# en vez de comprobar el dominio por el puerto 80 (nuestra ip es privada y no llegaria),
# let's encrypt comprueba un registro TXT que publican nuestros hooks en duckdns
# certonly (solo saca el certificado, la configuracion de apache la hacemos despues),
# manual + hooks (auth.sh publica el TXT y cleanup.sh lo borra al terminar),
# deploy-hook (recarga apache cada vez que se emite o renueva el certificado),
# -d (dominio del certificado), agree-tos (acepta los terminos),
# register-unsafely-without-email (cuenta sin email) y non-interactive (para que no pregunte nada)
certbot certonly --manual --preferred-challenges dns \
  --manual-auth-hook $DIR_HOOKS/auth.sh \
  --manual-cleanup-hook $DIR_HOOKS/cleanup.sh \
  --manual-public-ip-logging-ok \
  --deploy-hook "systemctl reload apache2" \
  -d "$DOMINIO" --agree-tos --register-unsafely-without-email --non-interactive


# creamos el sitio https--> el puerto 80 redirige a https y el 443 usa el certificado
# y sirve prestashop desde la misma raiz que el sitio http
cat > /etc/apache2/sites-available/prestashop-ssl.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMINIO
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMINIO

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMINIO/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMINIO/privkey.pem

    DocumentRoot /var/www/html

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF


# cambiamos del http al https
# para acabar pasando un configtest y reiniciando apache para que se guarden los cambios
a2dissite prestashop
a2ensite prestashop-ssl
apache2ctl configtest
systemctl restart apache2


# y por ultimo comprobamos que la renovacion automatica del certificado funcionara
certbot renew --dry-run