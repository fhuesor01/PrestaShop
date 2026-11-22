#!/bin/bash

# cargamos las variables del .env quitandole antes los finales de linea de windows (\r)
# set -a hace que todas las variables que cargamos se exporten solas
set -a
source <(sed 's/\r$//' /vagrant/scripts/.env)
# desactivamos la importacion de variables
set +a

# set -e hace que el script se pare en el primer error
set -e


# si ya tenemos el certificado de let's encrypt instalamos la tienda con https,
# si no, la instalamos con http para que no nos redirija a un https que no funciona
if [ -d /etc/letsencrypt/live/$DOMINIO ]; then
    PS_SSL=1
    PROTOCOLO=https
else
    PS_SSL=0
    PROTOCOLO=http
fi


# descargamos prestashop de la web oficial dentro de la carpeta tmp
# (desde la version 9 los zip ya no se publican en github)
rm -rf /tmp/prestashop
mkdir -p /tmp/prestashop
curl -fL -o /tmp/prestashop/prestashop.zip \
  "https://assets.prestashop3.com/dst/edition/corporate/$PS_V/prestashop_edition_classic_version_$PS_V.zip?source=vagrant"

# vaciamos la raiz del servidor web (asi tambien borramos phppsinfo, que muestra datos del servidor)
# el zip descargado trae dentro otro prestashop.zip, que es el que tiene la aplicacion,
# asi que descomprimimos el primero en tmp y el segundo en la raiz del servidor web
rm -rf /var/www/html/* /var/www/html/.htaccess
unzip -q /tmp/prestashop/prestashop.zip -d /tmp/prestashop/paquete
unzip -q /tmp/prestashop/paquete/prestashop.zip -d /var/www/html

# eliminamos la descarga de tmp
rm -rf /tmp/prestashop

# hacemos al usuario de apache propietario de los archivos de la web,
# para que prestashop pueda escribir en sus carpetas
chown -R www-data:www-data /var/www/html


# vaciamos la bd por si ya se habia instalado antes, asi podemos volver a lanzar este script sin errores
# (el usuario no hay que volver a crearlo, sus permisos van por el nombre de la bd)
mysql -e "DROP DATABASE IF EXISTS $DB_N; CREATE DATABASE $DB_N CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"


# instalamos prestashop por linea de comandos con index_cli.php (hace lo mismo que el asistente web pero sin navegador)
# lo ejecutamos como el usuario de apache (www-data) para que los archivos que genera tengan el propietario correcto-->
# domain y ssl (dominio de la tienda y si usa https), db_* (datos de la bd que creo el script de lamp),
# prefix (prefijo de las tablas, prestashop recomienda no usar el de por defecto "ps_"), name (nombre de la tienda),
# firstname, lastname, email y password (datos del administrador), country, language y timezone (tienda en español para españa)
cd /var/www/html/install
runuser -u www-data -- php index_cli.php \
  --domain="$DOMINIO" \
  --ssl=$PS_SSL \
  --db_server=localhost \
  --db_name="$DB_N" \
  --db_user="$DB_U" \
  --db_password="$DB_P" \
  --prefix=feli_ \
  --name="$PS_T" \
  --firstname="$PS_N" \
  --lastname="$PS_A" \
  --email="$PS_E" \
  --password="$PS_P" \
  --country=es \
  --language=es \
  --timezone=Europe/Madrid
cd /


# borramos la carpeta install, ya que prestashop no deja usar la tienda mientras exista
# y dejarla es un riesgo de seguridad
rm -rf /var/www/html/install

# si el instalador no ha renombrado la carpeta del panel de administracion, la renombramos nosotros
# con un nombre aleatorio, ya que dejarla como "admin" es un riesgo de seguridad
if [ -d /var/www/html/admin ]; then
    mv /var/www/html/admin /var/www/html/admin_feli$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
fi

# borramos la cache, volvemos a ajustar el propietario y reiniciamos apache para aplicar los cambios
rm -rf /var/www/html/var/cache/*
chown -R www-data:www-data /var/www/html
systemctl restart apache2


# mostramos por pantalla las direcciones de la tienda y del panel de administracion
CARPETA_ADMIN=$(basename $(ls -d /var/www/html/admin*))
echo "tienda--> $PROTOCOLO://$DOMINIO"
echo "panel de administracion--> $PROTOCOLO://$DOMINIO/$CARPETA_ADMIN"
