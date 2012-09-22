#!/bin/bash
#
# Author:    Andrew Awesome Hamilton
# Co-Author: Graziano Obertelli
#
# Script to install eucalyptus on a single box

# defaults
VERSION="1.0"

# SELFCONTAINED defined the operation mode: if set to Y, it will not ask
# questions and setup a cloud fully contained within the machine, with *NO*
# connectivity to the outsite world (public IP will be bogus, and
# instances will be accessible only from the machine itself)
SELFCONTAINED="Y"
FE_HOST="172.16.1.1"          # default CLC IP when in selfcontained mode

# usage ...
usage () {
        echo "Usage: $0 [options]"
        echo
        echo "Options:"
        echo "   -w      configured to be world accessible (will ask about IPs etc ...)"
        echo "   -V      version"
        echo

        exit 0
}

# set command line arguments
while [ $# -gt 0 ]; do
        if [ "$1" = "-w" ]; then 
                echo "Not Implemented yet"
                exit 0
                SELFCONTAINED="N"
                shift
        fi
        if [ "$1" = "-V" ]; then 
                echo "Version: $VERSION"
                shift
                exit 0
        fi

        usage
done

# Make registration easier later
if [ ! -e /root/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa 
fi
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# Install and start libvirtd
yum install -y libvirt.x86_64
chkconfig libvirtd on
service libvirtd start

# Turn off DNSMasq as it will cause issues later
service dnsmasq stop
chkconfig dnsmasq off

# Add in the NOZEROCONF=true to /etc/sysconfig/network
echo "NOZEROCONF=true" >> /etc/sysconfig/network

# Add the bridge on br0
cat >> /etc/sysconfig/network-scripts/ifcfg-br0 <<EOF
DEVICE=br0
ONBOOT=yes
TYPE=Bridge
BOOTPROTO=none
IPADDR=172.16.0.1
NETMASK=255.255.255.0
NETWORK=172.16.0.0
EOF

if [ "$SELFCONTAINED" = "Y" ]; then
        # Add the bridge on br1 used by the frontend in selfcontained mode
        cat >> /etc/sysconfig/network-scripts/ifcfg-br1 <<EOF
DEVICE=br1
ONBOOT=yes
TYPE=Bridge
BOOTPROTO=none
IPADDR=172.16.1.1
NETMASK=255.255.255.0
NETWORK=172.16.1.0
EOF

fi

# Restart the network to use the settings created above
service network restart

# Setup SSH known_hosts
ssh-keyscan 172.16.0.1 $FE_HOST | tee /root/.ssh/known_hosts

# Disable the firewall on the system
cp /etc/sysconfig/system-config-firewall /etc/sysconfig/system-config-firewall.ol
sed -i -e 's/enabled/disabled/' /etc/sysconfig/system-config-firewall.old

# Disable SELinux
sed -i -e 's/\(SELINUX\=\)enabled/\1disabled/' /etc/sysconfig/selinux
setenforce 0

# Install and setup NTP
yum install ntp
sed -i -e 's/\([0-9]\)\.centos/\1/g' /etc/ntp.conf
chkconfig ntpd on
service ntpd start
ntpdate -u pool.ntp.org
hwclock --systohc

## Install Eucalyptus
# Install the repos
yum -y install http://downloads.eucalyptus.com/software/eucalyptus/3.1/centos/6/x86_64/eucalyptus-release-3.1.1.noarch.rpm
yum -y install http://downloads.eucalyptus.com/software/eucalyptus/3.1/centos/6/x86_64/eucalyptus-release-3.1-1.el6.noarch.rpm
yum -y install http://downloads.eucalyptus.com/software/euca2ools/2.1/centos/6/x86_64/euca2ools-release-2.1-2.el6.noarch.rpm
yum -y install http://downloads.eucalyptus.com/software/eucalyptus/3.1/centos/6/x86_64/epel-release-6-7.noarch.rpm
yum -y install http://downloads.eucalyptus.com/software/eucalyptus/3.1/centos/6/x86_64/elrepo-release-6-4.el6.elrepo.noarch.rpm

#Install the CLC
yum groupinstall -y eucalyptus-cloud-controller

# Install the other components (NC, CC, SC, Walrus)
yum -y install eucalyptus-nc eucalyptus-cc eucalyptus-sc eucalyptus-walrus

# Set eucalyptus.conf depending on the mode
if [ "$SELFCONTAINED" = "Y" ]; then
        # comment network defaults
        sed -i -e 's/^VNET/#VNET/g' /etc/eucalyptus/eucalyptus.conf

        # add the networking
        cat >>/etc/eucalyptus/eucalyptus.conf <<EOF

# Cloud on a single machine config
VNET_MODE="MANAGED-NOVLAN"
VNET_PRIVINTERFACE="br0"
VNET_PUBINTERFACE="br1"
VNET_BRIDGE="br0"
VNET_SUBNET="172.16.128.0"
VNET_NETMASK="255.255.128.0"
VNET_DNS="8.8.8.8"
VNET_ADDRSPERNET="16"
VNET_PUBLICIPS="172.16.1.100-172.16.1.150"
VNET_DHCPDAEMON="/usr/sbin/dhcpd41"
EOF

        # ensure the CLC will register on the internal IP
        sed -i -e "s/^CLOUD_OPTS=\"\"/CLOUD_OPTS=\"-i ${FE_HOST}\"/" /etc/eucalyptus/eucalyptus.conf
else
        vim /etc/eucalyptus/eucalyptus.conf
fi

# workaround for EUCA-2049 (-i isn't obeyed): all interfaces going down
IFACES="`ifconfig |sed 's/[ \t].*//;/^$/d;/lo/d;/br1/d'`"
for x in $IFACES; do
        ifdown $x
done

# Initialize Eucalyptus
euca_conf --initialize

# Start the processes
service eucalyptus-cloud start
service eucalyptus-cc cleanstart
service eucalyptus-nc start

# Wait for the services to start listening on ports.
for x in 8443 8773 8774 8775 8777; do
    while [[ -z `netstat -ntplu | grep $x` ]]; do 
        echo "Waiting for the Eucalyptus components to start"
        sleep 7
    done
done

sleep 3

# workaround for EUCA-2049 (-i isn't obeyed): all interfaces comes up now
for x in $IFACES; do
        ifup $x
done

# Register components
euca_conf --skip-scp-hostcheck --register-walrus --partition walrus --host $FE_HOST --component walrus-single
euca_conf --skip-scp-hostcheck --register-cluster --partition cluster01 --host $FE_HOST --component cc-single
euca_conf --skip-scp-hostcheck --register-sc --partition cluster01 --host $FE_HOST --component sc-single
euca_conf --skip-scp-hostcheck --register-nodes "172.16.0.1"

mkdir /root/creds
cd /root/creds/
euca_conf --get-credentials admin.zip
unzip admin.zip


#source eucarc
#euca-describe-availability-zones verbose
#cd ..
#mkdir centos_img
#cd centos_img/
#wget http://192.168.7.65/ami-creator/centos6-201209051029/ks-centos6-201209051029.img.gz
#wget http://192.168.7.65/ami-creator/centos6-201209051029/vmlinuz-2.6.32-279.5.2.el6.x86_64
#wget http://192.168.7.65/ami-creator/centos6-201209051029/initramfs-2.6.32-279.5.2.el6.x86_64.img
#ls
#euca-bundle-image -i vmlinuz-2.6.32-279.5.2.el6.x86_64 --kernel true
#euca-upload-bundle -b centos-test -m /tmp/vmlinuz-2.6.32-279.5.2.el6.x86_64.manifest.xml
#euca-register --arch x86_64 centos-test/vmlinuz-2.6.32-279.5.2.el6.x86_64.manifest.xml
#euca-bundle-image -i initramfs-2.6.32-279.5.2.el6.x86_64.img --ramdisk true
#euca-upload-bundle -b centos-test -m /tmp/initramfs-2.6.32-279.5.2.el6.x86_64.img.manifest.xml
#euca-register --arch x86_64 centos-test/initramfs-2.6.32-279.5.2.el6.x86_64.img.manifest.xml
#ls
#gunzip ks-centos6-201209051029.img.gz
#ls
#euca-bundle-image -i ks-centos6-201209051029.img --kernel eki-784C3795 --ramdisk eri-8D623A42
#euca-upload-bundle -b centos-test -m /tmp/ks-centos6-201209051029.img.manifest.xml
#euca-register --arch x86_64 centos-test/ks-centos6-201209051029.img.manifest.xml
#euca-describe-instances
#euca-create-keypair admin | tee /root/creds/admin.priv; chmod 0600 /root/creds/admin.priv
#euca-run-instances -k admin -t m1.large
#euca-authorize -P tcp -p 22 -s 0.0.0.0/0 default
#euca-authorize -P icmp -t -1:-1 -s 0.0.0.0/0 default

