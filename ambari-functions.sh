#!/usr/bin/bash

# import common variable
. ./env.sh

: ${AMBARI_SERVER_NAME:=${NODE_PREFIX}-server}
: ${AMBARI_SERVER_IMAGE:="registry.cn-hangzhou.aliyuncs.com/tospur/amb-server:latest"}
: ${AMBARI_AGENT_IMAGE:="registry.cn-hangzhou.aliyuncs.com/tospur/amb-agent:latest"}
: ${HTTPD_IMAGE:="registry.cn-hangzhou.aliyuncs.com/tospur/httpd:latest"}
: ${HTTPD_NAME:=httpd}
: ${MYSQL_SERVER_NAME:=mysql}
: ${MYSQL_PASSWD:=123456}
: ${DOCKER_OPTS:=""}
: ${CONSUL_IMAGE:="sequenceiq/consul:v0.5.0-v6"}
: ${DEBUG:=1}
: ${SLEEP_TIME:=2}
: ${DNS_PORT:=53}
: ${EXPOSE_DNS:=false}
: ${DRY_RUN:=false}

amb-settings() {
  cat <<EOF
  NODE_PREFIX=$NODE_PREFIX
  AMBARI_SERVER_NAME=$AMBARI_SERVER_NAME
  AMBARI_SERVER_IMAGE=$AMBARI_SERVER_IMAGE
  AMBARI_AGENT_IMAGE=$AMBARI_AGENT_IMAGE
  HTTPD_IMAGE=$HTTPD_IMAGE
  DOCKER_OPTS=$DOCKER_OPTS
  AMBARI_SERVER_IP=$(get-ambari-server-ip)
  CONSUL_IP=$(get-consul-ip)
  CONSUL=$CONSUL
  CONSUL_IMAGE=$CONSUL_IMAGE
  EXPOSE_DNS=$EXPOSE_DNS
  DRY_RUN=$DRY_RUN
  CALICO_NET=$CALICO_NET
  HDP_PKG_DIR=$HDP_PKG_DIR
  HTTPD_NAME=$HTTPD_NAME
EOF
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

amb-clean() {
  unset NODE_PREFIX AMBARI_SERVER_NAME AMBARI_SERVER_IMAGE AMBARI_AGENT_IMAGE HTTPD_IMAGE CONSUL \
        CONSUL_IMAGE DEBUG SLEEP_TIME EXPOSE_DNS \
        DRY_RUN CALICO_NET HDP_PKG_DIR HTTPD_NAME
}

get-ambari-server-ip() {
  get-host-ip ${AMBARI_SERVER_NAME}
}

set-ambari-server-ip() {
  set-host-ip ${AMBARI_SERVER_NAME}
}

set-consul-ip() {
  set-host-ip $CONSUL
}

_get-first-host() {
    echo $HOST_FOR_LIST | awk '{print $1}'
}

amb-members() {
  local consul_ip=$(get-consul-ip)
  docker run  --net ${CALICO_NET} --rm appropriate/curl sh -c "curl http://$consul_ip:8500/v1/catalog/nodes"
}

debug() {
  [ ${DEBUG} -gt 0 ] && echo "[DEBUG] $@" 1>&2
}

docker-ps() {
  #docker ps|sed "s/ \{3,\}/#/g"|cut -d '#' -f 1,2,7|sed "s/#/\t/g"
  docker inspect --format="{{.Name}} {{.NetworkSettings.Networks.${CALICO_NET}.IPAddress}} {{.Config.Image}} {{.Config.Entrypoint}} {{.Config.Cmd}}" $(docker ps -q)
}

docker-psa() {
  #docker ps|sed "s/ \{3,\}/#/g"|cut -d '#' -f 1,2,7|sed "s/#/\t/g"
  docker inspect --format="{{.Name}} {{.NetworkSettings.Networks.${CALICO_NET}.IPAddress}} {{.Config.Image}} {{.Config.Entrypoint}} {{.Config.Cmd}}" $(docker ps -qa)
}

amb-config-nameserver() {
  # server 端添加 能上网的 nameserver
  local nameserver=$(docker exec $CONSUL  sh -c "sed -n '/.*nameserver.*/p' /etc/resolv.conf")
  docker exec $AMBARI_SERVER_NAME  sh -c "echo '$nameserver' >> /etc/resolv.conf"
  docker exec $AMBARI_SERVER_NAME  sh -c "cat /etc/resolv.conf"
}

amb-copy-ssh-ids() {
  docker exec $AMBARI_SERVER_NAME  sh -c "echo -e  'y\n'|ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa"

  # /ips/amb1
  local agent_list=$(_etcdctl ls /ips | grep amb'[0-9]' | awk -F / '{print $3}')
  for i in $agent_list; do
    local host_name="$i.service.consul"
    echo $host_name
    docker exec $AMBARI_SERVER_NAME  sh -c "ssh-keyscan $host_name >> ~/.ssh/known_hosts"
    docker exec $AMBARI_SERVER_NAME  sh -c "sshpass -p Zasd_1234 ssh-copy-id root@${host_name}"
  done
}

amb-clean-etcd() {
  _etcdctl rm /agent-nums

  local agent_list=$(_etcdctl ls /ips | grep amb'[0-9]')
  for i in $agent_list; do
    _etcdctl rm $i 
  done
}

amb-ssh-passwdless() {
  amb-config-nameserver
  amb-copy-ssh-ids
}

amb-start-agent() {
  local act_agent_size=${1:?"Usage:amb-start-agent <AGENT_NUM>"}
  local agent_nums=$(_etcdctl get /agent-nums)
  local first=1
  local last=$act_agent_size
  if [ -z "$agent_nums" ]; then
    _etcdctl set /agent-nums $act_agent_size
  else
    _etcdctl set /agent-nums $(($act_agent_size+$agent_nums))
    first=$(($agent_nums+1))
    last=$(($agent_nums+$act_agent_size))
  fi

  [ $act_agent_size -ge 1 ] && for i in $(seq $first $last); do
    amb-start-node $i
  done
}

amb-set-consul-ip() {
  docker run --net $CALICO_NET --name $CONSUL -tid  busybox
  set-consul-ip
  docker stop $CONSUL && docker rm -v $CONSUL
}

amb-publish-port() {
  # open port
  local port=${1:?"amb-publish-port <port> <des_ip>"}
  local des_ip=${2:?"amb-publish-port <port> <des_ip>"}
  firewall-cmd --zone=public --add-port=$port/tcp --permanent
  firewall-cmd --reload

  iptables -A PREROUTING -t nat -i eth0 -p tcp --dport $port -j DNAT  --to ${des_ip}:$port
  iptables -t nat -A OUTPUT -p tcp -o lo --dport $port -j DNAT --to-destination ${des_ip}:$port
  # TODO: need to save, in case of firewall-cmd --reload lost the dnat rules
}

amb-start-consul() {
  local dns_port_command=""
  if [[ "$EXPOSE_DNS" == "true" ]]; then
     dns_port_command="-p 53:$DNS_PORT/udp"
  fi
  # 因为启动 consul 必须预先知道 IP所以先获得一个 ip
  amb-set-consul-ip
  local consul_ip=$(get-consul-ip)
  echo "starting consul container"
  run-command docker run -d $dns_port_command --net ${CALICO_NET} --ip $consul_ip --name $CONSUL \
              -h $CONSUL.service.consul $CONSUL_IMAGE -server -advertise $consul_ip -bootstrap
}


amb-start-ambari-server() {
  local consul_ip=$(get-consul-ip)
  rm -rf $HADOOP_LOG/$AMBARI_SERVER_NAME
  echo "pulling image"
  echo "starting amb-server"
  run-command docker run -d $DOCKER_OPTS --net ${CALICO_NET} \
              --privileged --name $AMBARI_SERVER_NAME \
              -v $HADOOP_LOG/$AMBARI_SERVER_NAME:/var/log \
              -h $AMBARI_SERVER_NAME.service.consul $AMBARI_SERVER_IMAGE \
              systemd.setenv=NAMESERVER_ADDR=$consul_ip
  set-ambari-server-ip
  local ambari_server_ip=$(get-ambari-server-ip)
  # publish ambari 8080 port
  amb-publish-port 8080 $ambari_server_ip

  consul-register-service $AMBARI_SERVER_NAME $ambari_server_ip
  consul-register-service ambari-8080 $ambari_server_ip
}

amb-start-mysql() {
  run-command docker run --net ${CALICO_NET} --name $MYSQL_SERVER_NAME -e MYSQL_ROOT_PASSWORD=$MYSQL_PASSWD -d mysql
  set-host-ip $MYSQL_SERVER_NAME
  consul-register-service $MYSQL_SERVER_NAME $(get-host-ip $MYSQL_SERVER_NAME)
}

amb-start-server() {
  amb-start-consul
  sleep 5
  amb-start-mysql
  sleep 5
  amb-start-ambari-server
  sleep 5
  amb-start-HDP-httpd
  echo "replacing ambari.repo url"
  # agent register will copy ambari.repo from server
  amb-replace-ambari-url $AMBARI_SERVER_NAME
}

amb-start-node() {
  local consul_ip=$(get-consul-ip)

  local NUMBER=${1:?"please give a <NUMBER> parameter it will be used as node<NUMBER>"}

  if [[ $# -eq 1 ]]; then
    MORE_OPTIONS="-d"
  else
    shift
    MORE_OPTIONS="$@"
  fi
  # remove data && log dir
  rm -rf $HADOOP_DATA/${NODE_PREFIX}$NUMBER && rm -rf $HADOOP_LOG/${NODE_PREFIX}$NUMBER
  # pull images 

  run-command docker run $MORE_OPTIONS $DOCKER_OPTS --privileged --net ${CALICO_NET} --name ${NODE_PREFIX}$NUMBER \
              -v $HADOOP_DATA/${NODE_PREFIX}$NUMBER:/hadoop -v $HADOOP_LOG/${NODE_PREFIX}$NUMBER:/var/log \
              -h ${NODE_PREFIX}${NUMBER}.service.consul $AMBARI_AGENT_IMAGE \
              systemd.setenv=NAMESERVER_ADDR=$consul_ip

  set-host-ip ${NODE_PREFIX}$NUMBER

  consul-register-service ${NODE_PREFIX}${NUMBER} $(get-host-ip ${NODE_PREFIX}$NUMBER)

  # set password to agent, for server ssh
  docker exec ${NODE_PREFIX}$NUMBER sh -c " echo Zasd_1234 | passwd root --stdin "
}

amb-start-HDP-httpd() {
  # build image
  docker build -t my/httpd:latest ./httpd
  # 这里需要先将 HDP, HDP-UTILS-1.1.0.20 (centos 7) 放到 ${HDP_PKG_DIR}, 提供httpd访问
  # TODO: 必须检查配置路径的有效性
  docker run --net ${CALICO_NET} --privileged=true -d --name $HTTPD_NAME -v ${HDP_PKG_DIR}:/usr/local/apache2/htdocs/ $HTTPD_IMAGE

  set-host-ip $HTTPD_NAME
}

amb-replace-ambari-url() {
  local NODE_NAME=$1
  local httpd_ip=$(get-host-ip $HTTPD_NAME)
  local baseurl=http://${httpd_ip}/AMBARI-2.4.0.1/centos7/2.4.0.1-1/
  local gpgkey=http://${httpd_ip}/AMBARI-2.4.0.1/centos7/2.4.0.1-1/RPM-GPG-KEY/RPM-GPG-KEY-Jenkins

  docker exec $NODE_NAME sh -c "sed -i 's/baseurl=.*/baseurl=${baseurl//\//\\/}/g' /etc/yum.repos.d/ambari.repo"
  docker exec $NODE_NAME sh -c "sed -i 's/gpgkey=.*/gpgkey=${gpgkey//\//\\/}/g' /etc/yum.repos.d/ambari.repo"
  docker exec $NODE_NAME sh -c "cat /etc/yum.repos.d/ambari.repo"
}

amb-tool-get-server-sshkey() {
  docker exec ${AMBARI_SERVER_NAME}  sh -c "cat ~/.ssh/id_rsa"
}

amb-tool-get-agent-host-list() {
  local agent_list=$(_etcdctl ls /ips | grep amb'[0-9]' | tr -d "/ips/")
  for i in $agent_list; do
    echo "${i}.service.consul"
  done
}

amb-tool-get-HDP-url() {
  local httpd_ip=$(get-host-ip $HTTPD_NAME)
  echo "http://${httpd_ip}/HDP/centos7/2.x/updates/2.4.0.0"
  echo "http://${httpd_ip}/HDP-UTILS-1.1.0.20/repos/centos7"
}

amb-tool-get-all-setting() {
  echo "=============HDP url============="
  amb-tool-get-HDP-url
  echo "=============agent host list============="
  amb-tool-get-agent-host-list
  echo "=============server sshkey============="
  amb-tool-get-server-sshkey
  echo "=========================="
}

_check-input() {
    read -p "Please input HDP, HDP-UTIL package path, default:$HDP_PKG_DIR, input:" INPUT
    if [ "$INPUT" != "" ];then
        HDP_PKG_DIR=$INPUT
    fi
    if [ ! -d "$HDP_PKG_DIR" ];then
      echo "$HDP_PKG_DIR doesn't exist"
      exit
    fi
    echo $HDP_PKG_DIR
    read -p "Please input Hadoop data storage dir, default:$HADOOP_DATA, input:" INPUT
    if [ "$INPUT" != "" ];then
        HADOOP_DATA=$INPUT
    fi
    echo $HADOOP_DATA
    read -p "Please input Hadoop log dir, default:$HADOOP_LOG, input:" INPUT
    if [ "$INPUT" != "" ];then
        HADOOP_LOG=$INPUT
    fi
    echo $HADOOP_LOG
}

# 启动集群
amb-start-cluster() {
  local agents_per_host=${1:?"usage: AGENTS_PER_HOST"}
  local first_host=$(_get-first-host)

  _check-input

  echo "First clean cluster ......"
  amb-clean-cluster

  echo 'Now starting the cluster ......'
  _copy_this_sh

  pdsh -w $first_host bash ~/$0 amb-start-server
  sleep 5
  for host in $HOST_FOR_LIST; do
    pdsh -w $host bash ~/$0 amb-start-agent $agents_per_host
  done

  sleep 5
  echo "config agent passwdless......"
  pdsh -w $first_host bash ~/$0 amb-ssh-passwdless
  echo "test ambari started "
  amb-test-amb-server-start
  # config hive connect exist mysql
  docker exec $AMBARI_SERVER_NAME sh -c "ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar"
  echo "print Ambari config settings"
  amb-tool-get-all-setting
}

amb-clean-agent() {
  docker stop $(docker ps -a -q -f "name=${NODE_PREFIX}*")
  docker rm -v $(docker ps -a -q -f "name=${NODE_PREFIX}*")
}

amb-clean-server() {
  docker stop $AMBARI_SERVER_NAME $CONSUL $HTTPD_NAME $MYSQL_SERVER_NAME
  docker rm -v $AMBARI_SERVER_NAME $CONSUL $HTTPD_NAME $MYSQL_SERVER_NAME
}

amb-clean-cluster() {
  local count=0
  _copy_this_sh

  for host in $HOST_FOR_LIST
  do
    if [ $count -eq 0 ];then
      pdsh -w $host bash ~/$0 amb-clean-server
      pdsh -w $host bash ~/$0 amb-clean-etcd
    fi

    sleep 5
    pdsh -w $host bash ~/$0 amb-clean-agent

    ((count+=1))
  done
}

amb-test-amb-server-start() {
  local ambari_server_ip=$(get-ambari-server-ip)

  while [ 1 -eq 1 ]; do
    if curl ${ambari_server_ip}:8080; then
      break
    else
      sleep 5
    fi
  done
}

amb-get-agent-stay-host(){
  local input_num=${1:?"amb-get-agent-stay-host <number>"}
  local agent_nums=$(_etcdctl get /agent-nums)
  local host_num=$(awk '{print NF}' <<< "$HOST_FOR_LIST")
  local each_host_agents=$((agent_nums/host_num))
  local first=$(($input_num/$each_host_agents))
  local last=$(($input_num%$each_host_agents))

  local index=$first
  if [ $last -gt 0 ]; then
    index=$(($index+1))
  fi
  awk -v var=$index '{print $var}' <<< "$HOST_FOR_LIST"
}

amb-publish-hadoop-port(){
  # /ips/amb1
  local port=${1:?"Usage:amb-publish-port <port number>"}
  local agent_list=$(_etcdctl ls /ips | grep amb'[0-9]' | awk -F / '{print $3}')
  local amb_stay_host=""
  local amb_stay_host_ip=""
  for i in $agent_list; do
    local host_name="$i.service.consul"
    
    # server node must have ${NODE_PREFIX}1 amb-agent
    if docker exec ${NODE_PREFIX}1  sh -c "nc -w 2 -v ${host_name} $port < /dev/null"; then
      echo "$host_name have $port hiver server port"
      amb_stay_host=$i
      amb_stay_host_ip=$(get-host-ip $amb_stay_host)
      break
    fi
  done

  local locate_host=$(amb-get-agent-stay-host ${amb_stay_host: -1})
  echo "located host: $locate_host"

  _etcdctl set /hadoop/open_ports/$port "${amb_stay_host}-${amb_stay_host_ip}" 

  pdsh -w $locate_host bash ~/$0 amb-publish-port $port ${amb_stay_host_ip}
}

amb-publish-hadoop-ports() {
  local first_host=$(_get-first-host)
  _copy_this_sh

  # clean all port dnat
  pdsh -w $HOST_LIST firewall-cmd --reload

  # republish ambari 8080 port
  local ambari_server_ip=$(get-ambari-server-ip)
  pdsh -w $first_host bash ~/$0 amb-publish-port 8080 $ambari_server_ip

  # hive jdbc port 10000
  amb-publish-hadoop-port 10000
}

# call arguments verbatim:
$@