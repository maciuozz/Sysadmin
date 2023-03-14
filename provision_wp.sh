#!/bin/bash
#Script de aprovisionamiento de la VM Wordpress.

#Habilita la sincronización con los servidores de internet del servicio de hora NTP.
timedatectl set-ntp on

#Crea una lista con los nombres de todos los dispotivos que empiezan por 'sd'.
#'-d' indica el nombre sin particion.
devices=$(lsblk -d  -o NAME | grep sd*)

#Variable que almacena el nombre del primer dispositivo disponible.
available_device=""

#Itera sobre cada dispositivo en la lista.
while read -r devices; do
  #Comprueba si el dispositivo está actualmente en uso. Si no lo está el comando 'blkid' devuelve una cadena vacia.
  #-z' comprueba si la cadena especificada está vacía y devuelve true si lo está y false si la cadena no está vacía.
  if [ -z "$(sudo blkid /dev/$devices)" ]; then
    available_device=$devices
    break
  fi
done <<< "$devices" #Pasa como input al while el siguiente elemento de la lista.

if [ -z "$available_device" ]; then
  echo "No available devices were found."
  exit
fi

#Particionado del disco extra.
echo "Performing partitioning of the extra disk..."
#'-s' indica script mode
parted -s /dev/$available_device mklabel gpt \
  mkpart part_BBDD ext4 2048s 2097118s

partition_available_device="${available_device}1"

#Creación del volúmen lógico que almacenará la BBDD.
echo "Creating the logical volume to store the database..."
#Creación del volumen fisico. Le indicamos que la particion sdc1 del disco sdc hará parte de todo el montaje de lvm.
pvcreate /dev/$partition_available_device >/dev/null 2>&1
#Creamos el volume group.
vgcreate sysadmin_vg /dev/$partition_available_device >/dev/null 2>&1
#Creamos el volumen logico con todo el tamaño disponible del volume group.
lvcreate -l 100%FREE sysadmin_vg -n disk_BBDD >/dev/null 2>&1

#El UUID de un volumen lógico identifica al volumen lógico en sí, no al file system/sistema de ficheros en él.
#El file system es lo que realmente contiene los archivos y directorios que deseamos acceder y por eso necesitamos
#formatear el volumen logico obteniendo el 'Filesystem UUID'.
echo "Formatting the logical volume..."
mkfs.ext4 /dev/sysadmin_vg/disk_BBDD >/dev/null 2>&1 > file_systemUUID 

#Obteniendo el 'Filesystem UUID'.
echo "Setting the logical volume's mount point persistently..."
VLM_UUID=$(grep "Filesystem UUID" file_systemUUID | cut -d ":" -f 2 | sed 's/^[ \t]*//' ) &&
#Hacemos el cambio persistente añadiendo la entrada correspondiente en el fichero /etc/fstab.
echo "UUID=$VLM_UUID /var/lib/mysql ext4 defaults 0 0" >> /etc/fstab
#Creamos el punto de montaje.
mkdir /var/lib/mysql
#Con '-a' indicamos que vamos a montar todos los file systems listados en '/etc/fstab'.
mount -a

#Actualización de repositorios.
echo "Updating the apt cache/local database of available packages..."
apt update >/dev/null 2>&1

#Instalando Nginx.
echo "Installing Nginx..."
apt install -y nginx >/dev/null 2>&1

#Instalando MariaDB.
echo "Installing MariaDB..."
apt install -y mariadb-server mariadb-common >/dev/null 2>&1

#Instalando dependencias de php. 
echo "Installing php dependencies..."
apt install -y php-fpm php-mysql expect php-curl php-gd \
php-intl php-mbstring php-soap php-xml php-xmlrpc php-zip >/dev/null 2>&1

#Configurando la instancia de wordpress en Nginx.
echo "Setting the WordPress instance in Nginx..."
#Creamos el file 'wordpress' con el contenido del heredoc. Configuramos Nginx para que sirva el contenido de WordPress que se 
#almacena en el directorio /var/www/wordpress.
tee /etc/nginx/sites-available/wordpress >/dev/null 2>&1 <<EOF 
# Managed by installation script - Do not change
server {
listen 80;
root /var/www/wordpress;
index index.php index.html index.htm index.nginx-debian.html;
server_name localhost;
location / {
try_files \$uri \$uri/ =404;
}
location ~ \.php\$ {
include snippets/fastcgi-php.conf;
fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
}
}
EOF

#Habilitando la instancia de wordpress en Nginx.
echo "Enabling the WordPress instance in Nginx..."
#En la carpeta 'sites-enabled' creamos el link simbolico al file 'wordpress'.
ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default

#Habilitando Nginx y php.
echo "Enabling Nginx and php..."
if ! systemctl enable nginx --now; then echo "***Nginx could not be activated***"; fi
if ! systemctl enable php8.1-fpm --now; then echo "***php8.1 could not be activated***"; fi

#Securizamos MariaDB.
#1)Establece la pwd para el usuario root de MariaDB.
#2)Elimina cualquier usuario con un nombre de usuario vacío.
#3)Elimina cualquier usuario root que no esté conectado desde localhost, es decir, desde el mismo equipo en el que se está ejecutando MariaDB. 
#Los valores 'localhost', '127.0.0.1' y '::1' se refieren a direcciones IP especiales que siempre se refieren al propio equipo.
#4)Elimina la base de datos test si existe.
#5)Elimina cualquier base de datos que comience con 'test' seguido de un guión bajo.
echo "Securing MariaDB..."
mDBrootpwd="p●s●d●m●"

mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$mDBrootpwd');
DELETE FROM mysql.user WHERE user='';
DELETE FROM mysql.user WHERE user='root' AND host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

#Crea la base de datos 'wordpress' y otorga todos los permisos al usuario 'wordpressuser' con contraseña 'keepcoding'. 
#La opción 'localhost' indica que este usuario solo podrá conectarse desde el propio equipo.
echo "Creating wordpress database and its administrator user..."
mysql -u root -p$mDBrootpwd <<HEREDOC
CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
GRANT ALL ON wordpress.* TO 'wordpressuser'@'localhost' IDENTIFIED BY 'keepcoding';
FLUSH PRIVILEGES;
HEREDOC

#Descargando y descomprimiento el CMS WordPress.
echo "Downloading and installing WordPress..."
cd /tmp && wget https://wordpress.org/latest.tar.gz >/dev/null 2>&1
cd /var/www/ && tar -xzvf /tmp/latest.tar.gz >/dev/null 2>&1

#WordPress requiere una base de datos para almacenar su contenido y configuraciones. Por defecto utiliza una base de datos MySQL o MariaDB.
#Configuramos la conexion de WordPress a MariaDB para que WordPress use MariaDB como base de datos. 
echo "Linking WordPress to MariaDB..."
cd /var/www/wordpress
#El archivo 'wp-config.php' es utilizado por WordPress para almacenar la información de conexión a la base de datos.
#'wp-config-sample.php' es un archivo de muestra que proporciona una plantilla para crear el archivo 'wp-config.php'.
#'sed' reemplaza las cadenas 'database_name_here', 'username_here' y 'password_here' por los valores 'wordpress', 'wordpressuser' y 'keepcoding',
#respectivamente. 'g' significa 'global'. Le dice al comando sed que realice la operación de búsqueda y reemplazo especificada en todas las 
#ocurrencias del patrón de búsqueda, en lugar de solo la primera ocurrencia.
cat wp-config-sample.php | sed -e 's/database_name_here/wordpress/g; s/username_here/wordpressuser/g; s/password_here/keepcoding/g' > wp-config.php
#Cambia el propietario y el grupo del directorio /var/www/wordpress y de todo su contenido a 'www-data'. 
#'www-data' es el usuario y grupo comúnmente utilizado para servidores web como Nginx y Apache.
#Esto es necesario típicamente si Nginx necesita leer o escribir en los archivos del directorio, como cuando sirve páginas
#de WordPress o carga archivos multimedia.
chown -R www-data:www-data /var/www/wordpress
if ! systemctl restart nginx --now; then echo "***Nginx could not be restarted***"; fi


#Descargando e instalando Filebeat.
echo "Downloading and installing Filebeat..."
#Nos descargamos la clave GPG de la web y la agregamos al keyring local.
#La clave GPG se utiliza para autenticar los paquetes del Elastic Stack cuando se instalan mediante apt pudiendo asi
#verificar la integridad de los paquetes y asegurarse de que provienen de una fuente segura.
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
#Creamos el file 'elastic-7.x.list' con la cadena/string 'deb https://artifacts.elastic.co/packages/7.x/apt stable main'
#y lo agregamos al repositorio 'sources.list.d' de apt.
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-7.x.list >/dev/null 2>&1
#El repositorio /etc/apt contiene archivos y repositorios de configuración y otros recursos para el comando apt (Advanced Package Tool). 
#'sources.list' en /etc/apt es el principal archivo de configuración de los repositorios de paquetes. Contiene una lista de los repositorios
#que están habilitados para el sistema. 'sources.list.d' en /etc/apt es un directorio que contiene archivos de configuración adicionales de 
#repositorios de paquetes. Cuando ejecutamos 'apt update' descarga las listas de paquetes de los repositorios especificados en el archivo
#'sources.list' y en el directorio 'sources.list.d' y las utiliza para actualizar la caché local de paquetes.
apt update >/dev/null 2>&1
#Instalamos Filebeat desde el repositorio Elastic Stack porque forma parte de el. Filebeat es un data shipper de log files.
#Lee archivos de registro y envía los datos a Logstash para su indexación y almacenamiento.
apt install -y filebeat >/dev/null 2>&1
filebeat modules enable system
filebeat modules enable nginx

#Configurando filebeat indicándole los ficheros de logs que queremos que monitorize.
echo "Customising Filebeat configuration..."
cd /etc/filebeat

echo -e "    - /var/log/nginx/*.log\n    - /var/log/mysql/*.log" > mypaths

#Guardamos una copia del file original 'filebeat.yml' en 'filebeat_backup.yml'.
#Crea un nuevo file 'filebeat_backup.yml' y copia el contenido de 'filebeat.yml'.
cp filebeat.yml filebeat_backup.yml

#Busca 'type: filestream' y sustituye 'filestream' con 'log'. '/' y '!' son delimitadores.
#Busca '  enabled: false' y sustituye 'false' con 'true'. Los '..' indican que la linea empieza con 2 espacios.
#Busca la variable '  paths' y le añade el contenido de la variable 'mypaths'. 'r' es para empezar añadiendo despues de la linea actual.
#Busca '#output.logstash:' y sustituye '#' con '' para descomentarlo.
#Busca '  #hosts: \["localhost:5044"\]' y lo sustituye con '  hosts: \["192.168.1.51:5044"\]'.
#Comenta 'output.elasticsearch:' porque queremos que el output sea logstash.
tee mycommands.sed >/dev/null 2>&1 <<END
/type: filestream/s/filestream/log/
/^..enabled: false/s/false/true/ 
/^..paths:/r mypaths
/#output.logstash:/s/#//
s/^..#hosts: \["localhost:5044"\]/  hosts: \["192.168.1.51:5044"\]/
s/^output.elasticsearch:/#output.elasticsearch:/
END

#sed -i -f mycommands.sed filebeat.yml - Alternativa sin guardar copia de backup.
#'-i' indica que vamos a modificar el mismo file de entrada, 'filebeat.yml', en lugar de enviar el resultado a otro tipo de salida.
#'-f' indica que le vamos a pasar el archivo 'mycommands.sed' que contiene las instrucciones que se deben aplicar.
#Aplicamos los cambios sobrescribiendo el archivo original 'filebeat.yml' y dejando 'filebeat_backup.yml' inalterado.
sed -f mycommands.sed filebeat_backup.yml > filebeat.yml

#Habilitando e iniciando Filebeat.
echo "Enabling Filebeat..."
if ! systemctl enable filebeat --now; then echo "***Filebeat could not be activated***"; fi

echo "****The configuration is complete. VM1 Wordpress in service****"

exit 0