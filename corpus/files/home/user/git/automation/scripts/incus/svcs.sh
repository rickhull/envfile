#!/bin/sh

set -eu

# 1. configure static IP with AdGuard upstream DNS
# 2. copy over /etc/hosts
# 3. configure systemd-resolved
#   a) handles mDNS and upstream
#   b) listens on port 5300
#   c) ignores /etc/resolv.conf
# 4. enable mDNS for hostname.local resolution
# 5. install NSD, authoritative for bunkie.org
# 6. install dnsmasq:
#   a) LAN cache for AdGuard upstream
#   b) DHCP
#   c) hostname.lan registration for DHCP clients
#   d) hostname.local resolution for non-mDNS capable clients
#
#

AUTOMATION=/root/automation
AUTOFILES=$AUTOMATION/files

#
# 1. Static IP with AdGuard DNS
#

DNS1=94.140.14.140
DNS2=94.140.14.141

set +u # do our own checking on $1

# required: the last quad of a static IP
if [ -n "$1" ] && [ "$1" -gt 5 ] && [ "$1" -lt 255 ]; then
    cat <<EOF > /root/eth0.network
[Match]
Name=eth0

[Network]
Address=192.168.1.$1/24
Gateway=192.168.1.1
DNS=$DNS1
DNS=$DNS2
MulticastDNS=yes
EOF
    incus file push /root/eth0.network svcs/etc/systemd/network/eth0.network
    incus exec svcs -- networkctl reload
else
    echo "Usage: $0 [quadnum]"
    echo "Please specify a number between 6 and 254"
    exit 1
fi

set -u # check again for unset vars

#
# 2. copy /etc/hosts from host
#

incus file push /etc/hosts svcs/etc/hosts

#
# 3. configure systemd-resolved
#

incus file push $AUTOFILES/etc/systemd/resolved.conf svcs/etc/systemd/resolved.conf
incus exec svcs -- sh -ceu \
      "rm /etc/resolv.conf;
       echo nameserver 127.0.0.1 > /etc/resolv.conf;
       systemctl enable systemd-resolved;
       systemctl restart systemd-resolved;
       systemctl status --no-pager systemd-resolved"

#
# 4. enable mDNS for hostname.local resolution
#

incus exec svcs -- sed -i.bak \
      's/^hosts: .*/hosts: files mdns_minimal [NOTFOUND=return] dns/' \
      /etc/nsswitch.conf


#
# 5. NSD - authoritative for bunkie.org, listen on 1053
#

NSD_DIR=etc/nsd
NSD_CONF=$NSD_DIR/nsd.conf # sets nsd to 1053
ZONES=$NSD_DIR/zones
BUNKIE=$ZONES/db.bunkie.org

# install
incus exec svcs -- pacman --sync --noconfirm --needed nsd

# config
incus file push $AUTOFILES/$NSD_CONF svcs/$NSD_CONF
incus file create svcs/$ZONES --type=directory --mode=755
incus file push $AUTOFILES/$BUNKIE svcs/$BUNKIE

# service
incus exec svcs -- sh -ceu \
      "nsd-checkzone bunkie.org /$BUNKIE;
       systemctl enable nsd;
       systemctl restart nsd;
       systemctl status --no-pager nsd"

#
# 6. dnsmasq
#

DNSMASQ=etc/dnsmasq.conf

# install
incus exec svcs -- pacman --sync --noconfirm --needed dnsmasq

# config
incus file push $AUTOFILES/$DNSMASQ svcs/$DNSMASQ

# service
incus exec svcs -- sh -ceu \
      "systemctl enable dnsmasq;
       systemctl restart dnsmasq;
       systemctl status --no-pager dnsmasq"
