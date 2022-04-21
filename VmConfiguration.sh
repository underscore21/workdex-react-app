#!/bin/bash

dbms_mode=$1
numberOfCoreVms=$2
numberOfReplicaVms=$3
initialDiscoveryMembers=$4
hostMapping=$5
publicHostname=$6
nodeNumber=$7

echo "Turning off firewalld"
systemctl stop firewalld
systemctl disable firewalld


echo Adding neo4j yum repo...

# For Redhat
# rpm --import https://debian.neo4j.com/neotechnology.gpg.key
# echo "
# [neo4j]
# name=Neo4j Yum Repo
# baseurl=http://yum.neo4j.com/stable
# enabled=1
# gpgcheck=1" > /etc/yum.repos.d/neo4j.repo

# echo Installing Graph Database...
export NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
echo "neo4j-enterprise neo4j/question select I ACCEPT" | sudo debconf-set-selections
echo "neo4j-enterprise neo4j/license note" | sudo debconf-set-selections
# yum -y install neo4j-enterprise-4.4.3

# on UBUNTU 

sudo apt -y install apt-transport-https ca-certificates curl software-properties-common

curl -fsSL https://debian.neo4j.com/neotechnology.gpg.key | sudo apt-key add -

sudo add-apt-repository "deb https://debian.neo4j.com stable 4.4"

sudo apt-get -y install neo4j-enterprise=1:4.4.3
sudo systemctl enable neo4j.service

echo 'Configuring VM with certificates and mounting the data disk'

FILE=/var/lib/neo4j/certificates
cd /var/lib
if [ ! -d "$FILE" ]; then 
   mkdir neo4j/certificates
fi

echo 'Extract pfx file'
openssl pkcs12 -export -in ms-certificates/{VAULTNAME} -out neo4j/certificates/cert.pfx --password pass:
cd neo4j/certificates 

echo 'Extract public and private key'
openssl pkcs12 -in cert.pfx  -password pass: -clcerts -nokeys -out public.crt
openssl pkcs12 -in cert.pfx -password pass:  -nocerts -nodes -out private.key

echo 'Creating communication folders'
for certsource in bolt https; do
   sed -i s/#dbms.ssl.policy.${certsource}/dbms.ssl.policy.${certsource}/g /etc/neo4j/neo4j.conf
   if [ ! -d $certsource ]; then 
      mkdir $certsource
      mkdir $certsource/trusted
      mkdir $certsource/revoked
   fi
   cp public.crt $certsource/
   cp private.key $certsource/ ;
done

echo 'Permissions granted to the certificate folder'
chgrp -R neo4j *
chmod -R g+rx *

echo 'Cleaning the files'
rm public.crt
rm private.key
rm cert.pfx 
echo 'Certificates work is done'


echo 'Starting Prometheus Setup'
wget https://github.com/prometheus/prometheus/releases/download/v2.34.0/prometheus-2.34.0.linux-amd64.tar.gz
tar xvfz prometheus-*.tar.gz
cd prometheus-2.34.0.linux-amd64 
tee -a prometheus.yml << EOF
  - job_name: "prometheus_neo4j"

   # metrics_path defaults to '/metrics'
   # scheme defaults to 'http'.

    static_configs:
      - targets: ["localhost:2004"]
EOF

./prometheus --config.file=prometheus.yml &
#need to create it as a service on VM restarts 

echo 'Prometheus Setup Done'
# This link was followed to help mount the drive. https://docs.microsoft.com/en-us/azure/virtual-machines/linux/add-disk 
echo 'Mounting External Drive to Neo4j'

#Assuming there is only one disk for now
DISKS=`lsblk -o NAME,HCTL,SIZE,MOUNTPOINT | grep -i {DataDiskSize} | awk '{print $1}'`
diskNames=($DISKS)

for index in "${!diskNames[@]}" ; do
   if [ -z "${diskNames[$index]}" ]; then
    break
   fi
   #This will check the filesystem type of a device, if it contains the word data it is not partioned
   #If the disk is already partioned then we need to exit since this is most probably another run of the deployment.
   DISKPARTIONED=`file -sL "/dev/${diskNames[$index]}" | grep -i 'data'`
   if [ -z "$DISKPARTIONED" ]; then
      break
   fi
   echo 'Formatting the drive'
   
   #Formats the drives
   sudo parted "/dev/${diskNames[$index]}" --script mklabel gpt mkpart xfspart xfs 0% 100%
   sudo mkfs.xfs "/dev/${diskNames[$index]}1"
   sudo partprobe "/dev/${diskNames[$index]}1"
   
   dataDriveName="/datadrive" 
   if [ ${index} != 0 ]; then 
      dataDriveName="${dataDriveName}${index}"
   fi
  
   mkdir ${dataDriveName}
   sudo mount "/dev/${diskNames[$index]}1" $dataDriveName

   #Getting the disk UID so the OS can know about it
   UUID=`sudo blkid | grep -i "/dev/${diskNames[$index]}1" | awk '{print $2}' | sed 's/"//g'`
   echo "${UUID}   ${dataDriveName}   xfs   defaults,nofail   1   2" | tee -a /etc/fstab
done

#Copies the Neo4j data folder to the new folder on the mounted hard drive
sudo cp -v -rp /var/lib/neo4j/data/ /datadrive/ 


echo "Configuring network in neo4j.conf..."
sed -i 's/#dbms.default_listen_address=0.0.0.0/dbms.default_listen_address=0.0.0.0/g' /etc/neo4j/neo4j.conf

sed -i s/#dbms.default_advertised_address=localhost/dbms.default_advertised_address=${publicHostname}/g /etc/neo4j/neo4j.conf

echo ${initialDiscoveryMembers}

sed -i s/#causal_clustering.initial_discovery_members=localhost:5000,localhost:5001,localhost:5002/causal_clustering.initial_discovery_members=${initialDiscoveryMembers}/g /etc/neo4j/neo4j.conf

sed -i s/#dbms.mode=CORE/dbms.mode=${dbms_mode}/g /etc/neo4j/neo4j.conf

sed -i s/#causal_clustering.minimum_core_cluster_size_at_formation=3/causal_clustering.minimum_core_cluster_size_at_formation=${numberOfCoreVms}/g /etc/neo4j/neo4j.conf

sed -i s/#causal_clustering.minimum_core_cluster_size_at_runtime=3/causal_clustering.minimum_core_cluster_size_at_runtime=${numberOfCoreVms}/g /etc/neo4j/neo4j.conf

sed -i s/#dbms.routing.enabled=false/dbms.routing.enabled=true/g /etc/neo4j/neo4j.conf

echo Turning on SSL...
sed -i 's/dbms.connector.https.enabled=false/dbms.connector.https.enabled=true/g' /etc/neo4j/neo4j.conf
sed -i 's/#dbms.connector.bolt.tls_level=DISABLED/dbms.connector.bolt.tls_level=OPTIONAL/g' /etc/neo4j/neo4j.conf

#Map Neo4j to the new data folder we created. Neo4j restarts automatically when it detects changes on the template file. 

sed -i 's-/var/lib/neo4j/data-/datadrive/data-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.memory.heap.initial_size=512m-dbms.memory.heap.initial_size=31000m-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.memory.heap.max_size=512m-dbms.memory.heap.max_size=31000m-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.memory.pagecache.size=10g-dbms.memory.pagecache.size=20g-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.logs.query.enabled-dbms.logs.query.enabled-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.logs.query.threshold=0-dbms.logs.query.threshold=10s-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.logs.query.time_logging_enabled-dbms.logs.query.time_logging_enabled-' /etc/neo4j/neo4j.conf
sed -i 's-#dbms.logs.query.page_logging_enabled-dbms.logs.query.page_logging_enabled-' /etc/neo4j/neo4j.conf

# below Query update the property value if exist else will append the property in end 
# Format : sed -i -e '/^\(KEY_NAME=\).*/{s//\1NEW_VALUE/;:a;n;ba;q}' -e '$aKEY_NAME=INITIAL_VALUE' /etc/neo4j/neo4j.conf
sed -i -e '/^\(dbms.track_query_cpu_time=\).*/{s//\1true/;:a;n;ba;q}' -e '$adbms.track_query_cpu_time=true' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.enabled=\).*/{s//\1true/;:a;n;ba;q}' -e '$ametrics.enabled=true' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.namespaces.enabled=\).*/{s//\1true/;:a;n;ba;q}' -e '$ametrics.namespaces.enabled=true' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.prometheus.enabled=\).*/{s//\1true/;:a;n;ba;q}' -e '$ametrics.prometheus.enabled=true' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.prefix=\).*/{s//\1neo4j${dbms_mode}${nodeNumber}/;:a;n;ba;q}' -e '$ametrics.prefix=neo4j${dbms_mode}${nodeNumber}' /etc/neo4j/neo4j.conf

sed -i -e '/^\(metrics.filter=\).*/{s//\1neo4j.causal_clustering*,neo4j.dbms.page_cache.evictions/;:a;n;ba;q}' -e '$ametrics.filter=neo4j.causal_clustering*,neo4j.dbms.page_cache.evictions' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.csv.enabled=\).*/{s//\1true/;:a;n;ba;q}' -e '$ametrics.csv.enabled=true' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.csv.interval=\).*/{s//\130s/;:a;n;ba;q}' -e '$ametrics.csv.interval=30s' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.csv.rotation.size=\).*/{s//\110M/;:a;n;ba;q}' -e '$ametrics.csv.rotation.size=10M' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.csv.rotation.keep_number=\).*/{s//\15/;:a;n;ba;q}' -e '$ametrics.csv.rotation.keep_number=5' /etc/neo4j/neo4j.conf
sed -i -e '/^\(metrics.csv.rotation.compression=\).*/{s//\1zip/;:a;n;ba;q}' -e '$ametrics.csv.rotation.compression=zip' /etc/neo4j/neo4j.conf
sed -i -e '/^\(dbms.routing.default_router=\).*/{s//\1SERVER/;:a;n;ba;q}' -e '$adbms.routing.default_router=SERVER' /etc/neo4j/neo4j.conf
sed -i -e '/^\(dbms.allow_upgrade=\).*/{s//\1true/;:a;n;ba;q}' -e '$adbms.allow_upgrade=true' /etc/neo4j/neo4j.conf

tee -a /etc/neo4j/neo4j.conf << EOF

dbms.jvm.additional=-Dlog4j2.formatMsgNoLookups=true
dbms.jvm.additional=-Dlog4j2.disable.jmx=true
EOF


echo "Restart Neo4j"

#Force Neo4j.service to restart to ensure the changes on the template file take place. In some cases, the service didnt restart
#sudo systemctl restart neo4j

sudo service neo4j restart

echo "Service Restarted"

ADMINTOOLDIR="/usr/share/neo4j/conf/"
mkdir /usr/share/neo4j/conf

if [ ! -d "$ADMINTOOLDIR" ]; then
  echo "$ADMINTOOLDIR doesn't exist"
  exit 0
fi

echo "Sleeping for 10 secs to ensure the conf changes took place"
sleep 10s

echo "Moving conf for admin tool"
cp /etc/neo4j/neo4j.conf /usr/share/neo4j/conf/

echo "Configuration done"
