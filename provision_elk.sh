#!/bin/bash
##Script de aprovisionamiento de la VM Elasticsearch.

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
  #'-z' comprueba si la cadena especificada está vacía y devuelve true si lo está y false si la cadena no está vacía.
  if [ -z "$(sudo blkid /dev/$devices)" ]; then
    available_device=$devices
    break
  fi
done <<< "$devices" #Pasa como input al while el siguiente elemento de la lista.

if [ -z "$available_device" ]; then
  echo "No available devices were found."
  exit
fi

#Automatizamos el comando 'parted' con un heredoc. Entre 'mkpart' y 'ext4' no estamos definiendo el nombre de 
#la particion (no lo necesitamos). Como si le dieramos a 'enter'.
echo "Performing partitioning of the extra disk..." 
parted /dev/$available_device >/dev/null 2>&1 <<ME
mklabel
gpt
mkpart

ext4 
2048s
2097118s
quit
ME

partition_available_device="${available_device}1"

#Creación del volúmen lógico que almacenará la BBDD.
echo "Creating the logical volume to store de database..."
#Creación del volumen fisico. Le indicamos que la particion sdc1 del disco sdc hará parte de todo el montaje de lvm.
pvcreate /dev/$partition_available_device >/dev/null 2>&1
#Creamos el volume group.
vgcreate sysadmin_vg /dev/$partition_available_device >/dev/null 2>&1
#Creación del volúmen lógico con todo el tamaño disponible. Aqui el sistema crea la variable 'sysadmin_vg-diskELK' sin UUID.
lvcreate -l 100%FREE sysadmin_vg -n diskELK >/dev/null 2>&1

#Formateo del volúmen lógico.
echo "Formatting the logical volume..."
#Aqui el sistema asigna un UUID a la variable 'sysadmin_vg-diskELK' que es el mismo UUID del File System.
mkfs.ext4 /dev/sysadmin_vg/diskELK >/dev/null 2>&1

#Obteniendo el UUID asociado al volúmen lógico formateado (UUID de 'sysadmin_vg-diskELK').
echo "Setting the logical volume's mount point persistently..."
VLM_UUID=$(blkid | grep "sysadmin_vg-diskELK" | cut -d\" -f2) && 
#Hacemos el cambio persistente añadiendo la entrada correspondiente en el fichero /etc/fstab.
echo "UUID=$VLM_UUID /var/lib/elasticsearch ext4 defaults 0 0" >> /etc/fstab
#Creamos el punto de montaje.
mkdir /var/lib/elasticsearch
#Con '-a' indicamos que vamos a montar todos los file systems listados en '/etc/fstab'.
mount -a

##Actualización de repositorios.
echo "Downloading the latest package indices and other package information from the configured sources..."
apt update >/dev/null 2>&1

#Instalando Nginx y dependencias de JRE.
#NGINX es un web server y reverse proxy, un software diseñado para recibir y procesar solicitudes HTTP y generar respuestas HTTP. 
#Se encarga de escuchar las solicitudes HTTP entrantes, determinar cómo manejar la solicitud y generar una respuesta HTTP para enviar
#de vuelta al cliente. Si hacemos una solicitud HTTP a http://localhost:8081 desde el host, el host se conectará al servidor Nginx
#que se está ejecutando en el guest. Si el servidor Nginx está configurado como un proxy inverso, reenviará la solicitud al servidor web
#que se esté ejecutando en el guest. Por ejemplo, si el servidor Nginx está configurado para enrutar las solicitudes
#para un determinado dominio o URL a un servidor web que se esté ejecutando en el mimso guest, recibirá la solicitud del
#host, la reenviará al servidor web(por ejemplo kibana) y luego pasará la respuesta del servidor web de vuelta al host.
echo "Installing Nginx and Java JRE dependencies (please be patient, it may take a couple of minutes)..."
apt install -y nginx default-jre >/dev/null 2>&1

#Habilitando Nginx.
echo "Enabling Nginx..."
if ! systemctl enable nginx --now; then echo "***Nginx could not be enabled***"; fi

#Descargando e instalando el Elastic Stack.
echo "Downloading and installing the Elastick Stack..."
##Nos descargamos la clave GPG de la web y la agregamos al keyring local.
#La clave GPG se utiliza para autenticar los paquetes del Elastic Stack cuando se instalan mediante apt pudiendo asi
#verificar la integridad de los paquetes y asegurarse de que provienen de una fuente segura.
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-7.x.list >/dev/null 2>&1
apt update >/dev/null 2>&1

#Instalando Logstash.
echo "Installing Logstash..."
apt install -y logstash >/dev/null 2>&1

#Instalando Elasticsearch.
echo "Installing Elasticsearch..."
apt install -y elasticsearch >/dev/null 2>&1

#Instalando Kibana.
echo "Installing Kibana..."
apt install -y kibana >/dev/null 2>&1

#Aplicando configuración personalizada para Logstash.
echo "Customizing Logstash configuration..."
tee /etc/logstash/conf.d/02-beats-input.conf >/dev/null 2>&1 <<END
    input {
     beats {
      port => 5044
     }
    }
END
tee /etc/logstash/conf.d/30-elasticsearch-output.conf >/dev/null 2>&1 <<AAA
    output {
     elasticsearch {
      hosts => ["localhost:9200"]
      manage_template => false
      index => "%{[@metadata][beat]}-%{[@metadata][version]}-%{+YYYY.MM.dd}"
     }
    }
AAA

cp /vagrant/logstash-syslog-filter.conf /etc/logstash/conf.d/10-syslog-filter.conf

#Habilitando Logstash.
echo "Enabling Logstash (please be patient, it could take a couple of minutes)..."
if ! systemctl enable logstash --now; then echo "***Logstash could not be enabled***"; fi

#Habilitando Elasticsearch.
echo "Enabling Elastic Search (please be patient, it could take a couple of minutes)..."
#Cambia el propietario y el grupo del directorio /var/lib/elasticsearch y de todo su contenido (-R de recursivo) a 'elasticsearch'.
chown -R elasticsearch:elasticsearch /var/lib/elasticsearch
#Los permisos 754 especifican permisos de lectura, ejecución y búsqueda para el dueño del archivo o directorio (7), permisos
#de lectura y ejecución para el dueño del grupo (5) y permisos de lectura y ejecución para otros usuarios (4)."
chmod -R 754 /var/lib/elasticsearch
if ! systemctl enable elasticsearch --now; then echo "***Elastic Search could not be enabled***"; fi

#Habilitando Kibana.
echo "Enabling Kibana (please be patient, it could take a couple of minutes)..."
if ! systemctl enable kibana --now; then echo "***Kibana could not be enabled***"; fi

#Modificando la instancia default en Nginx para redirigir el puerto 80 al puerto de Kibana.
echo "Modifying the Nginx default instance to redirect port 80 to the kibana port and applying a basic authentication..."
#Guardamos una copia del file 'default' creando un nuevo file 'default.bak'. La extensión '.bak' es una convención común
#para indicar que el archivo es una copia de seguridad.
cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak

#Escribimos el texto especificado en el archivo 'default', reemplazando su contenido anterior.
#Redirigimos las peticiones al puerto 80 al puerto de kibana. 
#Escucha conexiones entrantes en el puerto 80, que es el puerto predeterminado para el tráfico HTTP. 
#Cuando se recibe una solicitud, el server block verifica la directiva server_name para ver si la solicitud está destinada a kibana.demo.com 
#o localhost. Si la solicitud coincide con cualquiera de estos nombres de dominio, el server block procesa la solicitud. Si no es 
#así, la solicitud se pasa al siguiente bloque de servidor en la configuración de Nginx.
#También hay una directiva auth_basic que habilita una autenticación básica.
#La directiva auth_basic_user_file especifica la ubicación del archivo de contraseñas que Nginx debe usar para la autenticación básica.
#El location block define el proxy inverso para Kibana. Especifica que todas las solicitudes deben ser procesadas por proxy 
#a http://localhost:5601, que es la URL de Kibana. La directiva proxy_pass le dice a Nginx que reenvíe la solicitud a esta URL.
tee /etc/nginx/sites-available/default >/dev/null 2>&1 <<GOAL
# Managed by installation script - Do not change
 server {
   listen 80;
   server_name kibana.demo.com localhost;
   auth_basic "Restricted Access";
   auth_basic_user_file /etc/nginx/htpasswd.users;
   location / {
     proxy_pass http://localhost:5601;
     proxy_http_version 1.1;
     proxy_set_header Upgrade \$http_upgrade;
     proxy_set_header Connection 'upgrade';
     proxy_set_header Host \$host;
     proxy_cache_bypass \$http_upgrade;
   }
 }
GOAL

#Todo lo que hay en el directorio 'sysadmin-Paolo' se cargará automaticamente en el directorio '/vagrant' que es
#un directorio compartido entre el host y el guest.
#El fichero '.kibana' almacena en texto plano la contraseña que será encriptada por el comando 'openssl'.
#Finalmente guardaremos la contraseña encriptada en el fichero 'htpasswd.users' 
echo "Generating password file for Kibana..."
echo "kibanaadmin:$(openssl passwd -apr1 -in /vagrant/.kibana)" | tee -a /etc/nginx/htpasswd.users >/dev/null 2>&1
if ! systemctl restart nginx; then echo "***Nginx could not be restarted***"; fi
if ! systemctl restart kibana; then echo "***Kibana could not be restarted***"; fi

echo "****The configuration is complete. VM2 - Elasticsearch in service****"

exit 0