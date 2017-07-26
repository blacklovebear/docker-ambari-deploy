#!/usr/bin/bash
: ${DEBUG:=1}
: ${DRY_RUN:=false}

: ${NODE_PREFIX:=amb}
: ${CONSUL:=${NODE_PREFIX}-consul}

# 通过 calico 配置的跨节点网络
: ${CALICO_NET:=docker_test}
: ${CALICO_CIDR:=192.0.2.0/24}
: ${SH_FILE_PATH:=/tmp}
: ${ENV_FILE:=$(dirname $0)/env.sh}

# 本地 HDP，HDP-UTIL 包所在的路径
HDP_PKG_DIR=/home/hdp_httpd_home
# docker volume mount to docker
HADOOP_DATA=/home/hadoop_data
HADOOP_LOG=/home/hadoop_log

AMBARI_VERSION=v2.4
AMBARI_v2_4_PATH=AMBARI-2.4.0.1/centos7/2.4.0.1-1
AMBARI_v2_5_PATH=AMBARI-2.5.0.3/centos7

HOST_LIST=dc01,dc02,dc03,dc04,dc05

_copy_this_sh() {
    local host=$1
    if [[ "" == $host ]];then
        host=$HOST_LIST
    fi
    run-command pdcp -w $host /etc/hosts $ENV_FILE $0 $SH_FILE_PATH
}

_get-host-num(){
    awk '{print NF}' <<< "${HOST_LIST//,/ }"
}

_get-host-ip(){
    grep -i $1 $SH_FILE_PATH/hosts | awk '{print $1}'
}

_get-first-host() {
    cut -d',' -f 1 <<< $HOST_LIST
}

_get-second-host() {
    cut -d',' -f 2 <<< $HOST_LIST
}

_get-third-host() {
    cut -d',' -f 3 <<< $HOST_LIST
}

_get-first-host-ip() {
    _get-host-ip $(_get-first-host)
}

_get-second-host-ip() {
    _get-host-ip $(_get-second-host)
}

_get-third-host-ip() {
    _get-host-ip $(_get-third-host)
}

_get-etcd-ip-list() {
    local input_type=${1:?"Usage:_get-etcd-ip-list <TYPE>(etcd,http)"}
    local host_num=$(_get-host-num)
    local host1_ip=$(_get-first-host-ip)

    local result=""
    if [ $host_num -lt 3 ]; then
        result="etcd://${host1_ip}:2379"
    else
        local host2_ip=$(_get-second-host-ip)
        local host3_ip=$(_get-third-host-ip)
        result="etcd://${host1_ip}:2379,etcd://${host2_ip}:2379,etcd://${host3_ip}:2379"
    fi

    if [ $input_type == 'http' ]; then
        echo $result | sed -e "s/etcd/http/g"
    else
        # etcd for docker daemon only config one
        echo $result | awk -F , '{print $1}'
    fi
}

_etcdctl() {
    docker run  --rm tenstartups/etcdctl --endpoints $(_get-etcd-ip-list http) $@
}

debug() {
  [ ${DEBUG} -gt 0 ] && echo "[DEBUG] $@" 1>&2
}

run-command() {
  CMD="$@"
  if [[ "$DRY_RUN" == "false" ]]; then
    debug "$CMD"
    "$@"
  else
    debug [DRY_RUN] "$CMD"
  fi
}

get-host-ip() {
    local HOST=${1:?"Usage: get-host-ip <HOST>"}
     _etcdctl get /ips/${HOST}
}

set-host-ip() {
    local HOST=${1:?"Usage: set-host-ip <HOST> <ip>"}
    local IP=${2:?"Usage: set-host-ip <HOST> <ip>"}
    _etcdctl set /ips/${HOST} ${IP}
}

get-consul-ip() {
    get-host-ip ${CONSUL}
}

consul-register-service() {
    : ${1:?"Usage:consul-register-service <node_name> <node_ip>"}
    : ${2:?"Usage:consul-register-service <node_name> <node_ip>"}
    local consul_ip=$(get-consul-ip)
    docker run  --net ${CALICO_NET} --rm appropriate/curl sh -c "
    curl -X PUT -d \"{
        \\\"Node\\\": \\\"$1\\\",
        \\\"Address\\\": \\\"$2\\\",
        \\\"Service\\\": {
          \\\"Service\\\": \\\"$1\\\"
        }
      }\" http://$consul_ip:8500/v1/catalog/register
  "
}

list-consul-register-nodes(){
    local consul_ip=$(get-consul-ip)
    docker run  --net ${CALICO_NET} --rm appropriate/curl sh -c "curl http://$consul_ip:8500/v1/catalog/nodes"
}

docker-ps() {
  docker inspect --format="{{.Name}} [{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}] {{.Config.Image}} {{.Config.Entrypoint}} {{.Config.Cmd}}" $(docker ps -q)
}

docker-psa() {
  docker inspect --format="{{.Name}} [{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}] {{.Config.Image}} {{.Config.Entrypoint}} {{.Config.Cmd}}" $(docker ps -qa)
}