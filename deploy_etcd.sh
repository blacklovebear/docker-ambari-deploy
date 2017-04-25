#!/usr/bin/bash
# 必须配置好，本地host文件
: ${HOST_LIST=docker-220,docker-222}


etcd-install() {
    # wget https://github.com/coreos/etcd/releases/download/v3.1.5/etcd-v3.1.5-linux-amd64.tar.gz

    pdcp -w $HOST_LIST ./etcd-v3.1.5-linux-amd64.tar.gz ~

    pdsh -w $HOST_LIST tar -zxf ~/etcd-v3.1.5-linux-amd64.tar.gz
    pdsh -w $HOST_LIST mv -f ~/etcd-v3.1.5-linux-amd64/etcd* /usr/bin

}

etcd-open-ports() {
    pdsh -w $HOST_LIST firewall-cmd --zone=public --add-port=2380/tcp --permanent
    pdsh -w $HOST_LIST firewall-cmd --reload
}

etcd-start() {
    # todo: open port 2380, 2379
    local cluster_size=${1:?"usege: etcd-start <CLUSTER_SIZE>"}

    local token=$(curl "https://discovery.etcd.io/new?size=$cluster_size")

    local host_list=${HOST_LIST//,/ }
    local count=0
    for host in $host_list
    do
        if [ $count -eq $cluster_size ];then
            break
        fi

        local host_ip=$(grep -i $host /etc/hosts | awk '{print $1}')

        # stop it first
        pdsh -w $host ps -ef | grep 'etcd -name'| grep -v grep | awk '{print $2}' | xargs kill -9

        pdsh -w $host ETCD_DISCOVERY=${token} \
        nohup etcd -name etcd-$host -initial-advertise-peer-urls http://${host_ip}:2380 \
          -listen-peer-urls http://${host_ip}:2380 \
          -listen-client-urls http://${host_ip}:2379,http://127.0.0.1:2379 \
          -advertise-client-urls http://${host_ip}:2379 \
          -discovery ${token} > ~/etcd.log &

        count=$(($count+1))
    done
    # local listen_ip=$(ip addr | grep inet | grep $connect_net_interface | awk -F" " '{print $2}'| sed -e 's/\/.*$//')
}

_get-firt-host-ip() {
    local host_list=${HOST_LIST//,/ }
    local host=$(echo $host_list | awk '{print $1}')

    grep -i $host /etc/hosts | awk '{print $1}'
}

etcd-config-docker-daemon() {
    pdcp -w $HOST_LIST ./deploy_etcd.sh ~

    pdsh -w $HOST_LIST bash ~/deploy_etcd.sh _config-docker-daemon $(_get-firt-host-ip)

}

_config-docker-daemon() {
    local first_host_ip=$1
    local cluster_ip=""
    local docker_config="/etc/sysconfig/docker"

    # 本地监听 2379端口
    if netstat -lnt | awk '$6 == "LISTEN" && $4 ~ ".2379"'; then
        cluster_ip="0.0.0.0"
    else
        cluster_ip=$first_host_ip
    fi

    if cat $docker_config | grep -q "cluster-store"; then
        sed -i "s/cluster-store=[^\']*/cluster-store=etcd:\/\/${cluster_ip}:2379/g" $docker_config
    else
        sed -i "s/OPTIONS='\(.*\)'/OPTIONS='\1 --cluster-store=etcd:\/\/${cluster_ip}:2379'/g" $docker_config
    fi

}

# call arguments verbatim:
$@