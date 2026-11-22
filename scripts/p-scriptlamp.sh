#!/bin/bash

# cargamos las variables del .env quitandole antes los finales de linea de windows (\r)
# set -a hace que todas las variables que cargamos se exporten solas
set -a
source <(sed 's/\r$//' /vagrant/scripts/.env)
# desactivamos la importacion de variables
set +a

# con esta linea hacemos que apt no se pare a preguntarnos nada durante la instalacion
export DEBIAN_FRONTEND=noninteractive

# actualizamos la lista de paquetes e instalamos los necesarios-->
# apache2 (servidor web), mariadb-server (servidor de bd), php y libapache2-mod-php (para que apache ejecute php),
# las extensiones de php que pide prestashop (mysql, curl, gd, intl, mbstring, xml, zip y bcmath),
# unzip y curl (para descargar y descomprimir prestashop) y ufw (firewall)
apt-get update
apt-get install -y apache2 mariadb-server php libapache2-mod-php php-mysql php-curl php-gd \
  php-intl php-mbstring php-xml php-zip php-bcmath unzip curl ufw


# ajustamos las directivas de php que pide prestashop (las comprobamos despues con phppsinfo)
# en un fichero propio dentro de conf.d para no tocar el php.ini original,
# tanto para apache como para la linea de comandos (cli), ya que el instalador de prestashop lo lanzamos por cli
PHP_V=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
for SAPI in apache2 cli; do
cat > /etc/php/$PHP_V/$SAPI/conf.d/99-prestashop.ini <<EOF
memory_limit = 512M
max_input_vars = 5000
post_max_size = 128M
upload_max_filesize = 128M
date.timezone = Europe/Madrid
EOF
done


# creamos una bd con la variable de vagrantfile (utf8mb4 que es la que pide prestashop)
# y un usuario que solo puede conectarse desde la propia maquina, dandole permisos totales solo sobre esa bd
mysql <<EOF
CREATE DATABASE IF NOT EXISTS $DB_N CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '$DB_U'@'localhost';
CREATE USER '$DB_U'@'localhost' IDENTIFIED BY '$DB_P';
GRANT ALL PRIVILEGES ON $DB_N.* TO '$DB_U'@'localhost';
FLUSH PRIVILEGES;
EOF


# instalamos phpmyadmin sin que nos pregunte nada-->
# con debconf le dejamos respondidas las preguntas del instalador
# (crear su bd, su contraseña y que se configure con apache)
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password $PMA_P" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password $PMA_P" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
apt-get install -y phpmyadmin


# activamos los modulos de apache que necesitamos-->
# rewrite (urls legibles de prestashop y redireccion a https), headers (para modificar cabeceras) y ssl (para servir https con el certificado)
a2enmod rewrite headers ssl


# creamos el sitio http (puerto 80), con AllowOverride All para que funcione el .htaccess de prestashop
# cuando el certificado este listo, el script de letsencrypt lo cambia por el sitio https
cat > /etc/apache2/sites-available/prestashop.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMINIO
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF


# descargamos phppsinfo (script oficial de prestashop que comprueba los requisitos) en la raiz del servidor web,
# habiendo borrado "index.html" (el cual nos crea apache por defecto),
# y le cambiamos el usuario y la contraseña que trae por defecto (prestashop/prestashop) por los del vagrantfile
rm -f /var/www/html/index.html
curl -fsSL -o /var/www/html/phppsinfo.php https://raw.githubusercontent.com/PrestaShop/php-ps-info/master/phppsinfo.php
sed -i \
  -e "s/const DEFAULT_LOGIN = '[^']*';/const DEFAULT_LOGIN = '$PSINFO_U';/" \
  -e "s/const DEFAULT_PASSWORD = '[^']*';/const DEFAULT_PASSWORD = '$PSINFO_P';/" \
  /var/www/html/phppsinfo.php

# hacemos al usuario de apache propietario de los archivos de la web
chown -R www-data:www-data /var/www/html


# activamos nuestro sitio y desactivamos el de por defecto
# para acabar pasando un configtest y reiniciando apache para que se guarden los cambios
# (si ya tenemos el certificado no lo activamos, para no pisar el sitio https al volver a lanzar este script)
a2dissite 000-default
if [ ! -d /etc/letsencrypt/live/$DOMINIO ]; then
  a2ensite prestashop
fi
apache2ctl configtest
systemctl restart apache2


# configuramos el firewall (equivalente al grupo de seguridad de aws)--> ssh solo desde el host de vagrant
# y http/https desde cualquier origen
ufw --force reset
ufw default deny incoming
ufw allow from $IP_VAGRANT to any port 22 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
