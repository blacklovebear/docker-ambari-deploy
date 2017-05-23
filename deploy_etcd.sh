#!/usr/bin/bash

# import common variable
. ./env.sh

etcd-open-ports() {
    local etcd_host_list=$(_get-etcd-host-list)
    pdsh -w $etcd_host_list firewall-cmd --zone=public --add-port=2380/tcp --permanent
    pdsh -w $etcd_host_list firewall-cmd --zone=public --add-port=2379/tcp --permanent
    pdsh -w $etcd_host_list firewall-cmd --reload
}

_stop-etcd-progress() {
    ps -ef | grep 'etcd -name'| grep -v grep | awk '{print $2}' | xargs kill -9
}

_get-etcd-host-list() {
    local host_num=$(_get-host-num)

    if [ $host_num -lt 3 ]; then
        echo $HOST_LIST | awk -F , '{print $1}'
    else
        echo $HOST_LIST | awk -F , '{printf "%s,%s,%s", $1,$2,$3}'
    fi
}

etcd-start() {
    _copy_this_sh

    local host_num=$(_get-host-num)
    if [ $host_num -lt 3 ]; then
        one-etcd-start
    else
        three-etcd-start
    fi
}

one-etcd-start() {
    local host1=$(_get-first-host)
    local host1_ip=$(_get-first-host-ip)
    pdsh -w $host1 "docker stop etcd && docker rm etcd"
    pdsh -w $host1 \
        "docker run -d -v /usr/share/ca-certificates/:/etc/ssl/certs -p 2380:2380 -p 2379:2379 \
         --restart always \
         --name etcd twang2218/etcd:v2.3.7 \
         -name etcd1 \
         -advertise-client-urls http://$host1_ip:2379 \
         -listen-client-urls http://0.0.0.0:2379 \
         -initial-advertise-peer-urls http://$host1_ip:2380 \
         -listen-peer-urls http://0.0.0.0:2380 \
         -initial-cluster-token etcd-cluster-1 \
         -initial-cluster etcd1=http://$host1_ip:2380 \
         -initial-cluster-state new"
}

three-etcd-start() {
    local host1=$(_get-first-host)
    local host2=$(_get-second-host)
    local host3=$(_get-third-host)

    local host1_ip=$(_get-first-host-ip)
    local host2_ip=$(_get-second-host-ip)
    local host3_ip=$(_get-third-host-ip)

    _three-etcd-docker-start $host1 $host1_ip 1 $host1_ip $host2_ip $host3_ip
    _three-etcd-docker-start $host2 $host2_ip 2 $host1_ip $host2_ip $host3_ip
    _three-etcd-docker-start $host3 $host3_ip 3 $host1_ip $host2_ip $host3_ip
}

_three-etcd-docker-start(){
    local host=$1; host_ip=$2; node_num=$3
    local host1_ip=$4; host2_ip=$5; host3_ip=$6
    pdsh -w $host "docker stop etcd && docker rm etcd"
    pdsh -w $host \
        "docker run -d -v /usr/share/ca-certificates/:/etc/ssl/certs -p 2380:2380 -p 2379:2379 \
         --restart always \
         --name etcd twang2218/etcd:v2.3.7  \
         -name etcd${node_num} \
         -advertise-client-urls http://$host_ip:2379 \
         -listen-client-urls http://0.0.0.0:2379 \
         -initial-advertise-peer-urls http://$host_ip:2380 \
         -listen-peer-urls http://0.0.0.0:2380 \
         -initial-cluster-token etcd-cluster-1 \
         -initial-cluster etcd1=http://$host1_ip:2380,etcd2=http://$host2_ip:2380,etcd3=http://$host3_ip:2380 \
         -initial-cluster-state new"
}

config-docker-daemon-with-etcd() {
    _copy_this_sh
    local etcd_cluster=$(_get-etcd-ip-list etcd)
    pdsh -w $HOST_LIST bash ~/$0 _local-config-docker $etcd_cluster
}

_local-config-docker() {
    local etcd_cluster=${1:?"Need etcd_cluster"}
    local docker_config="/etc/sysconfig/docker"

    if cat $docker_config | grep -q "cluster-store"; then
        sed -i "s/cluster-store=[^\']*/cluster-store=${etcd_cluster//\//\\/}/g" $docker_config
    else
        sed -i "s/OPTIONS='\(.*\)'/OPTIONS='\1 --cluster-store=${etcd_cluster//\//\\/}'/g" $docker_config
    fi
    echo "restarting docker daemon......"
    systemctl restart docker
}

_local_calico_start() {
    local etcd_cluster=${1:?"Usage:_local_calico_start <etcd_cluster> <host_ip> "}
    local host_ip=${2:?"Usage:_local_calico_start <etcd_cluster> <host_ip> "}

    # open port:179 for BPG protocol (calico use for node communication)
    firewall-cmd --zone=public --add-port=179/tcp --permanent
    firewall-cmd --reload

    chmod +x /usr/local/bin/calicoctl
    # 默认的name 和hostName 一致，如果两台机器的hostName一致，则必须指定，不然bgp发现不了远端
    # ETCD_ENDPOINTS=http://${etcd_cluster}:2379 calicoctl node run --ip=$host_ip --node-image calico/node --name node1
    ETCD_ENDPOINTS=${etcd_cluster} calicoctl node run --ip=$host_ip --node-image calico/node
}

calico-start() {
    local etcd_cluster=$(_get-etcd-ip-list http)
    if [ ! -e ./calicoctl ]; then
        # wget -O ./calicoctl https://github.com/projectcalico/calicoctl/releases/download/v1.1.3/calicoctl
        tar -zxf ./calicoctl.tar.gz
    fi
    # copy calicoctl
    pdcp -w $HOST_LIST ./calicoctl /usr/local/bin/calicoctl
    _copy_this_sh
    
    for host in $HOST_FOR_LIST; do
        local host_ip=$(_get-host-ip $host)
        pdsh -w $host bash ~/$0 _local_calico_start $etcd_cluster $host_ip
    done
    sleep 5
    pdsh -w $(_get-first-host) calicoctl node status
}

_calico-delete-ipPool() {
cat << EOF | calicoctl delete -f -
- apiVersion: v1
  kind: ipPool
  metadata:
    cidr: $CALICO_CIDR
  spec:
    nat-outgoing: true
EOF
}

_calico-create-ipPool() {
cat << EOF | calicoctl create -f -
- apiVersion: v1
  kind: ipPool
  metadata:
    cidr: $CALICO_CIDR
  spec:
    nat-outgoing: true
EOF
}

# ingress:
#   source:
#     tag: docker_test
# 默认的配置，source 有tag现在，只允许相同网络互相访问
# 外网无法访问 8080 端口
_config-calico-profile() {
cat << EOF | calicoctl apply -f -
- apiVersion: v1
  kind: profile
  metadata:
    name: $CALICO_NET
    tags:
    - $CALICO_NET
  spec:
    egress:
    - action: allow
      destination: {}
      source: {}
    ingress:
    - action: allow
      destination: {}
      source: {}
EOF
}

calico-create-net() {
    docker network rm $CALICO_NET
    _calico-delete-ipPool
    _calico-create-ipPool
    docker network create --driver calico --ipam-driver calico-ipam --subnet=$CALICO_CIDR $CALICO_NET
    _config-calico-profile
}

_rm-workload-test-container() {
    local host=$1
    pdsh -w $host docker stop '$(docker ps -a -q --filter="name=workload*")'
    pdsh -w $host docker rm '$(docker ps -a -q --filter="name=workload*")'
}

test-calico-net-conn() {
    local first_host=$(_get-first-host)
    local second_host=$(_get-second-host)

    _rm-workload-test-container $first_host
    pdsh -w $first_host docker run --net $CALICO_NET --name workload-A -tid busybox
    pdsh -w $first_host docker run --net $CALICO_NET --name workload-B -tid busybox

    _rm-workload-test-container $second_host
    pdsh -w $second_host docker run --net $CALICO_NET --name workload-C -tid busybox

    pdsh -w $first_host docker exec workload-A ping -c 4 workload-B.$CALICO_NET
    pdsh -w $first_host docker exec workload-A ping -c 4 workload-C.$CALICO_NET

    _rm-workload-test-container $first_host
    _rm-workload-test-container $second_host
}

_clean-network-container() {
    docker stop $(docker ps -f network=$CALICO_NET -a -q)
    docker rm $(docker ps -f network=$CALICO_NET -a -q)
}

docker-clean-network-all() {
    _copy_this_sh
    pdsh -w $HOST_LIST bash ~/$0 _clean-network-container
}

add-new-host(){
    local host=${1:?"Usage add-new-host <host>"}
    local host_ip=$(_get-host-ip $host)
    local etcd_cluster_docker=$(_get-etcd-ip-list etcd)
    local etcd_cluster=$(_get-etcd-ip-list http)

    _copy_this_sh $host

    # copy calicoctl
    pdcp -w $host ./calicoctl /usr/local/bin/calicoctl
    
    pdsh -w $host bash ~/$0 _local-add-new-host $host_ip $etcd_cluster_docker $etcd_cluster

}

_local-add-new-host(){
    local host_ip=$1
    local etcd_cluster_docker=$2
    local etcd_cluster=$3
    _clean-network-container
    _local-config-docker $etcd_cluster_docker
    _local_calico_start $etcd_cluster $host_ip
    calicoctl node status
}

main() {
    echo "docker-clean-network-all starting"
    docker-clean-network-all
    echo "etcd-open-ports starting"
    etcd-open-ports
    echo "etcd-start starting"
    etcd-start
    echo "config-docker-daemon-with-etcd starting"
    config-docker-daemon-with-etcd
    echo "calico-start starting"
    calico-start
    echo "calico-create-net starting"
    calico-create-net
    echo "test-calico-net-conn starting"
    test-calico-net-conn
}

# call arguments verbatim:
$@