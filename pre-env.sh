#!/usr/bin/bash

# import common variable
source $(dirname $0)/env.sh

CURRENT_EXE_FILE=$SH_FILE_PATH/${0##*/}

_change-ip() {
    local GATEWAY=${1:?"Usage:change-ip <GATEWAY> <IPADDR>"}
    local IPADDR=${2:?"Usage:change-ip <GATEWAY> <IPADDR>"}
    local DNS1=172.30.100.3

    sed -i "s/ONBOOT=.*/ONBOOT=yes/g" /etc/sysconfig/network-scripts/ifcfg-eth0
    sed -i "s/BOOTPROTO=.*/BOOTPROTO=static/g" /etc/sysconfig/network-scripts/ifcfg-eth0

    for ele in DNS1 GATEWAY IPADDR; do
        if cat /etc/sysconfig/network-scripts/ifcfg-eth0 | grep $ele; then
            sed -i "s/$ele=.*/$ele=${!ele}/g" /etc/sysconfig/network-scripts/ifcfg-eth0
        else
            echo "$ele=${!ele}" >> /etc/sysconfig/network-scripts/ifcfg-eth0
        fi
    done
}


save-docker-images(){
    # master only
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/master/amb-server.tar registry.cn-hangzhou.aliyuncs.com/tospur/amb-server:v2.4
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/master/mysql.tar registry.cn-hangzhou.aliyuncs.com/tospur/mysql:latest
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/master/httpd.tar registry.cn-hangzhou.aliyuncs.com/tospur/httpd:latest
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/master/consul.tar docker.io/sequenceiq/consul:v0.5.0-v6

    # per node
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/amb-agent.tar registry.cn-hangzhou.aliyuncs.com/tospur/amb-agent:v2.4
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/busybox.tar docker.io/busybox:latest
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/etcdctl.tar docker.io/tenstartups/etcdctl:latest
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/curl.tar docker.io/appropriate/curl:latest
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/calico-node.tar docker.io/calico/node:latest
    docker save -o $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/etcd.tar docker.io/twang2218/etcd:v2.3.7
}



_load-master-images(){
    docker load -i $HDP_PKG_DIR/IMAGES_TAR/base_images/master/amb-server.tar
    docker load -i $HDP_PKG_DIR/IMAGES_TAR/base_images/master/mysql.tar
    docker load -i $HDP_PKG_DIR/IMAGES_TAR/base_images/master/httpd.tar
    docker load -i $HDP_PKG_DIR/IMAGES_TAR/base_images/master/consul.tar
}


_load-agents-images(){
    local host_list=${1:?"Usage: _load-agents-images <host_list>"}

    local local_image_path=/tmp/base_images/agent

    pdsh -w $host_list mkdir -p $local_image_path
    pdsh -w $host_list rm -rf $local_image_path/*

    pdcp -w $host_list $HDP_PKG_DIR/IMAGES_TAR/base_images/agent/* $local_image_path

    pdsh -w $host_list docker load -i $local_image_path/amb-agent.tar
    pdsh -w $host_list docker load -i $local_image_path/busybox.tar
    pdsh -w $host_list docker load -i $local_image_path/etcdctl.tar
    pdsh -w $host_list docker load -i $local_image_path/curl.tar
    pdsh -w $host_list docker load -i $local_image_path/calico-node.tar
    pdsh -w $host_list docker load -i $local_image_path/etcd.tar
}


_set-hostname() {
    hostnamectl set-hostname $1
}

_host-ssh-passwd-less(){
    ssh-keyscan $1 >> ~/.ssh/known_hosts
    sshpass -p $2 ssh-copy-id root@$1
}

_hosts-ssh-passwd-less() {
    local passwd=${1:?"Usage:_install-pdsh <PASSWD>"}
    # yum -y update
    echo -e  'y\n'|ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
    for host in ${HOST_LIST//,/ }; do
        _host-ssh-passwd-less $host $passwd
    done
}

_config-docker() {
    echo '{
    "live-restore": true,
    "registry-mirrors": ["https://80kate9y.mirror.aliyuncs.com"]
}' > /etc/docker/daemon.json

    debug "Docker deamon restarting ............"
    systemctl restart docker
}

_enable-iptables(){
    systemctl disable firewalld
    systemctl enable iptables
}

_install-agents-software(){
    local host_list=${1:?"Usage: _install-agents-software <host_list>"}
    local local_software_path=/tmp/docker_deploy_software

    pdsh -w $host_list mkdir -p $local_software_path
    pdsh -w $host_list rm -rf $local_software_path/*

    for host in ${host_list//,/ }; do
        scp $HDP_PKG_DIR/ENV_TOOLS/* ${host}:$local_software_path
    done

    # pdcp -w $host_list $HDP_PKG_DIR/ENV_TOOLS/* $local_software_path

    pdsh -w $host_list yum localinstall -y $local_software_path/*
}


_install-master-software(){
    # yum install -y epel-release sshpass pdsh docker-io jq iptables-services
    yum localinstall -y $HDP_PKG_DIR/ENV_TOOLS/*
}

_config-per-host(){
    debug "Installing tools...................."
    _enable-iptables
    _config-docker
}

# config host network
pre-network() {
    local host_name=${1:?"Usage: main <HOST-NAME> <IP-ADDR>"}
    local ip_addr=${2:?"Usage: main <HOST-NAME> <IP-ADDR>"}

    _set-hostname $host_name
    _change-ip 172.18.84.254 $ip_addr
    systemctl restart network
}

_check-input(){
    read -p "Please input host list comma as segmentation default:[$HOST_LIST] input:" INPUT

    if [[ "$INPUT" != "" ]];then
        HOST_LIST=$INPUT
        echo $HOST_LIST
        sed -i "s/HOST_LIST=\(.*\)/HOST_LIST=$HOST_LIST/g" $ENV_FILE
    fi
}

pre-deploy() {
    local passwd=${1:?"Usage: pre-deploy <host-passwd>"}
    # _check-input

    local rest_hosts=$(_get-2after-hosts)

    # install on master server
    # yum install -y sshpass pdsh
    _install-master-software
    _hosts-ssh-passwd-less $passwd

    _install-agents-software $rest_hosts

    _copy_this_sh

    pdsh -w $HOST_LIST bash $CURRENT_EXE_FILE _config-per-host

    _load-master-images
    _load-agents-images $HOST_LIST
}


_add-host-to-env-sh(){
    local host=$1
    if egrep "HOST_LIST=" $ENV_FILE | grep -q "$host"; then
        : "do nothing"
    else
        sed -i "s/HOST_LIST=\(.*\)/HOST_LIST=\1,$host/g" $ENV_FILE
    fi
}

add-new-host() {
    local host=${1:?"Usage: add-new-host <host> <passwd>"}
    local passwd=${2:?"sage: add-new-host <host> <passwd>"}


    _add-host-to-env-sh $host
    _host-ssh-passwd-less $host $passwd
    _copy_this_sh $host

    pdsh -w $host bash $CURRENT_EXE_FILE _install-agents-software
    pdsh -w $host bash $CURRENT_EXE_FILE _config-per-host
}

$@