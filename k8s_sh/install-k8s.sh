#!/bin/bash
source $(dirname $0)/k8s-env.sh

: ${MASTER_IP:=""}

get-master-host(){
    cut -d',' -f 1 <<< $HOST_LIST
}

get-nodes-host(){
    cut -d',' -f 2- <<< $HOST_LIST
}

add-google-to-host(){
    if ! cat /etc/hosts | grep google;then
        cat << EOF >> /etc/hosts
61.91.161.217 google.com
61.91.161.217 gcr.io
61.91.161.217 www.gcr.io
61.91.161.217 console.cloud.google.com
61.91.161.217 storage.googleapis.com
EOF
        pdcp -w $HOST_LIST /etc/hosts /etc/hosts
    fi
}

install-k8s(){
    local repo_path=/etc/yum.repos.d/virt7-docker-common-release.repo
    cat << EOF > $repo_path
[virt7-docker-common-release]
name=virt7-docker-common-release
baseurl=http://cbs.centos.org/repos/virt7-docker-common-release/x86_64/os/
gpgcheck=0
EOF
    pdcp -w $HOST_LIST $repo_path $repo_path
    pdsh -w $HOST_LIST yum -y install --enablerepo=virt7-docker-common-release kubernetes etcd flannel

}

conf-kubernetes-common(){
    local config_path=/etc/kubernetes/config
    cat << EOF > $config_path
###
# kubernetes system config
#
# The following values are used to configure various aspects of all
# kubernetes services, including
#
#   kube-apiserver.service
#   kube-controller-manager.service
#   kube-scheduler.service
#   kubelet.service
#   kube-proxy.service
# logging to stderr means we get it in the systemd journal
KUBE_LOGTOSTDERR="--logtostderr=true"

# journal message level, 0 is debug
KUBE_LOG_LEVEL="--v=0"

# Should this cluster be allowed to run privileged docker containers
KUBE_ALLOW_PRIV="--allow-privileged=true"

# How the controller-manager, scheduler, and proxy find the apiserver
KUBE_MASTER="--master=https://${MASTER_IP}:6443"
EOF
    pdcp -w $HOST_LIST $config_path $config_path
}

conf-kubernetes-master(){
    conf-etcd-on-master
    conf-apiserver-on-master
    conf-scheduler-on-master
    conf-controller-manager-on-master
}

conf-etcd-on-master(){
    local master_host=$(get-master-host)
    local config_path=/etc/etcd/etcd.conf
    cat << EOF > $config_path
# [member]
ETCD_NAME=default
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_CLIENT_URLS="http://${MASTER_IP}:2379"
#[cluster]
ETCD_ADVERTISE_CLIENT_URLS="http://${MASTER_IP}:2379"
EOF
    pdcp -w $master_host $config_path $config_path
}

conf-apiserver-on-master(){
    local master_host=$(get-master-host)
    local config_path=/etc/kubernetes/apiserver
    cat << EOF > $config_path
###
# kubernetes system config
#
# The following values are used to configure the kube-apiserver
#

# The address on the local server to listen to.
KUBE_API_ADDRESS="--address=0.0.0.0"

# The port on the local server to listen on.
KUBE_API_PORT="--insecure-port=8080 --insecure-bind-address=127.0.0.1"

# Port minions listen on
KUBELET_PORT="--kubelet-port=10250"

# Comma separated list of nodes in the etcd cluster
KUBE_ETCD_SERVERS="--etcd-servers=http://${MASTER_IP}:2379"

# Address range to use for services
KUBE_SERVICE_ADDRESSES="--service-cluster-ip-range=10.254.0.0/16"

# default admission control policies
KUBE_ADMISSION_CONTROL="--admission-control=NamespaceLifecycle,NamespaceExists,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota"

# Add your own!
KUBE_API_ARGS="--client-ca-file=/srv/kubernetes/ca.crt --tls-cert-file=/srv/kubernetes/server.cert --tls-private-key-file=/srv/kubernetes/server.key --service-account-key-file=/srv/kubernetes/server.key"
EOF
    pdcp -w $master_host $config_path $config_path
}

conf-scheduler-on-master(){
    local master_host=$(get-master-host)
    local config_path=/etc/kubernetes/scheduler
    cat << EOF > $config_path
###
# kubernetes scheduler config

# default config should be adequate

# Add your own!
KUBE_SCHEDULER_ARGS="--kubeconfig=/root/.kube/config"
EOF
    pdcp -w $master_host $config_path $config_path
}

conf-controller-manager-on-master(){
    local master_host=$(get-master-host)
    local config_path=/etc/kubernetes/controller-manager
    cat << EOF > $config_path
###
# The following values are used to configure the kubernetes controller-manager

# defaults from config and apiserver should be adequate

# Add your own!
KUBE_CONTROLLER_MANAGER_ARGS="--kubeconfig=/root/.kube/config --root-ca-file=/srv/kubernetes/ca.crt --service-account-private-key-file=/srv/kubernetes/server.key"
EOF
    pdcp -w $master_host $config_path $config_path
}

conf-kubernetes-nodes(){
    conf-flanneld
    conf-kubelet
    conf-proxy
}

conf-flanneld() {
    local config_path=/etc/sysconfig/flanneld
    cat << EOF > $config_path
# Flanneld configuration options

# etcd url location.  Point this to the server where etcd runs
FLANNEL_ETCD_ENDPOINTS="http://${MASTER_IP}:2379"

# etcd config key.  This is the configuration key that flannel queries
# For address range assignment
FLANNEL_ETCD_PREFIX="/kube-centos/network"

# Any additional options that you want to pass
#FLANNEL_OPTIONS=""
EOF
    pdcp -w $HOST_LIST $config_path $config_path
}

conf-kubelet(){
    local config_path=/etc/kubernetes/kubelet
    cat << EOF > $config_path
###
# kubernetes kubelet (minion) config

# The address for the info server to serve on (set to 0.0.0.0 or "" for all interfaces)
KUBELET_ADDRESS="--address=0.0.0.0"

# The port for the info server to serve on
KUBELET_PORT="--port=10250"

# You may leave this blank to use the actual hostname
#KUBELET_HOSTNAME="--hostname-override=127.0.0.1"
KUBELET_HOSTNAME=""

# location of the api-server
#KUBELET_API_SERVER="--api-servers=http://${MASTER_IP}:8080"
KUBELET_API_SERVER="--api-servers=https://${MASTER_IP}:6443"

# pod infrastructure container
#KUBELET_POD_INFRA_CONTAINER="--pod-infra-container-image=registry.access.redhat.com/rhel7/pod-infrastructure:latest"

# Add your own!
KUBELET_ARGS="--cluster_dns=10.254.0.10 --cluster_domain=k8s --kubeconfig=/root/.kube/config"
EOF
    pdcp -w $HOST_LIST $config_path $config_path
}

conf-proxy(){
    local config_path=/etc/kubernetes/proxy
    cat << EOF > $config_path
###
# kubernetes proxy config

# default config should be adequate

# Add your own!
KUBE_PROXY_ARGS="--kubeconfig=/root/.kube/config"
EOF
    pdcp -w $HOST_LIST $config_path $config_path
}

open-kubelet-ports(){
    local master_host=$(get-master-host)
    # etcd

    需要改成 iptables 形式

    pdsh -w $master_host firewall-cmd --zone=public --add-port=2379/tcp --permanent
    # kube-apiserver
    pdsh -w $master_host firewall-cmd --zone=public --add-port=6443/tcp --permanent

    pdsh -w $HOST_LIST firewall-cmd --zone=public --add-port=10250/tcp --permanent

    pdsh -w $HOST_LIST firewall-cmd --reload
}


conf-flanneld-on-etcd(){
    local master_host=$(get-master-host)
    pdsh -w $master_host systemctl start etcd
    pdsh -w $master_host "etcdctl --endpoint ${MASTER_IP}:2379 set /kube-centos/network/config \"{ \\\"Network\\\": \\\"172.30.0.0/16\\\", \\\"SubnetLen\\\": 24, \\\"Backend\\\": { \\\"Type\\\": \\\"vxlan\\\" } }\""
}

start-master(){
    local master_host=$(get-master-host)

    _copy_this_sh $master_host

    pdsh -w $master_host "sed -i 's/User=.*/User=root/g' /usr/lib/systemd/system/kube-controller-manager.service"
    pdsh -w $master_host "sed -i 's/User=.*/User=root/g' /usr/lib/systemd/system/kube-scheduler.service"

    pdsh -w $master_host bash $SH_FILE_PATH/$0 _local_start_master
}

start-nodes(){
    # local nodes_host=$(get-nodes-host)
    _copy_this_sh
    pdsh -w $HOST_LIST bash $SH_FILE_PATH/$0 _local_start_nodes
}

stop-all(){
    local master_host=$(get-master-host)
    _copy_this_sh

    pdsh -w $HOST_LIST bash $SH_FILE_PATH/$0 _local_stop_nodes

    pdsh -w $master_host bash $SH_FILE_PATH/$0 _local_stop_master
}

_local_start_master(){
    for SERVICES in etcd kube-apiserver kube-controller-manager kube-scheduler flanneld; do
        systemctl restart $SERVICES
        systemctl enable $SERVICES
        systemctl status $SERVICES
    done
}

_local_stop_master(){
    for SERVICES in etcd kube-apiserver kube-controller-manager kube-scheduler flanneld; do
        systemctl stop $SERVICES
        systemctl status $SERVICES
    done
}

_local_stop_nodes(){
    for SERVICES in kube-proxy kubelet flanneld docker; do
        systemctl stop $SERVICES
        systemctl status $SERVICES
    done
}

_local_start_nodes(){
    for SERVICES in kube-proxy kubelet flanneld docker; do
        systemctl restart $SERVICES
        systemctl enable $SERVICES
        systemctl status $SERVICES
    done
}

conf-kubectl(){
    local master_host=$(get-master-host)
    # pdsh -w $master_host "kubectl config set-cluster default-cluster --server=http://${MASTER_IP}:8080"
    # pdsh -w $master_host "kubectl config set-context default-context --cluster=default-cluster --user=default-admin"
    # pdsh -w $master_host "kubectl config use-context default-context"
    kubectl config set-cluster default-cluster --server=https://${MASTER_IP}:6443 --certificate-authority=/srv/kubernetes/ca.crt
    kubectl config set-credentials default-admin --certificate-authority=/srv/kubernetes/ca.crt --client-key=/srv/kubernetes/kubecfg.key --client-certificate=/srv/kubernetes/kubecfg.crt
    kubectl config set-context default-context --cluster=default-cluster --user=default-admin
    kubectl config use-context default-context

    pdsh -w $HOST_LIST mkdir -p /root/.kube/
    pdcp -w $HOST_LIST /root/.kube/config /root/.kube/config

    pdsh -w $master_host "kubectl create namespace ambari"
    pdsh -w $master_host "kubectl label node $master_host role=master"
}

create-certificate(){
    bash $(dirname $0)/make-ca-cert.sh main
}

install-tools(){
    yum install -y epel-release
    yum install -y pdsh docker-io
}

main(){
    MASTER_IP=${1:?"main <master_ip>"}

    add-google-to-host

    install-k8s

    conf-kubernetes-common

    conf-kubernetes-master

    conf-kubernetes-nodes

    open-kubelet-ports

    conf-flanneld-on-etcd

    conf-kubectl

    start-master

    start-nodes

}

$@