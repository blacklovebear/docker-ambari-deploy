#!/bin/bash
source $(dirname $0)/k8s-env.sh

: ${DEBUG:=1}
: ${DRY_RUN:=false}
: ${HDP_v2_4_PATH:=HDP/centos7/2.x/updates/2.4.0.0}
: ${HDP_v2_4_UTILS_PATH:=HDP-UTILS-1.1.0.20/repos/centos7}
: ${HDP_v2_6_PATH:=HDP-2.6/centos7}
: ${HDP_v2_6_UTILS_PATH:=HDP-UTILS-1.1.0.21}

: ${AGENT_YAML:=../k8s_amb/ambari-agent.yml}

debug() {
  [ ${DEBUG} -gt 0 ] && echo "[DEBUG] $@" 1>&2
}

run_command() {
  CMD="$@"
  if [[ "$DRY_RUN" == "false" ]]; then
    debug "$CMD"
    "$@"
  else
    debug [DRY_RUN] "$CMD"
  fi
}

_kubectl(){
    kubectl --namespace=ambari "$@"
}

_get_amb_server_name(){
    _kubectl get pod -o wide | grep ambari-server | awk '{print $1}'
}

_get_amb_agents_name(){
    _kubectl get pod -o wide | grep amb-agent | awk '{print $1}'
}

_get_amb_agents_ip(){
    _kubectl get pod -o wide | grep amb-agent | awk '{print $6}'
}

_run_amb_server_sh(){
    local ambari_server_name=$(_get_amb_server_name)
    run_command _kubectl exec $ambari_server_name -c ambari-server -- "$@"
}

_amb_copy_ssh_to_agent(){
    local host_name=${1:?"Usage: _amb_copy_ssh_to_agent <host_name> <server-name> "}
    _run_amb_server_sh sh -c "ssh-keyscan $host_name >> ~/.ssh/known_hosts"
    _run_amb_server_sh sh -c "sshpass -p Zasd_1234 ssh-copy-id root@${host_name}"
}

config_master(){
    _run_amb_server_sh sh -c "echo -e  'y\n'|ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa"

    for i in $(amb_tool_get_agent_host_list); do
        run_command _amb_copy_ssh_to_agent $i
    done

    _run_amb_server_sh sh -c "sort -u ~/.ssh/known_hosts > ~/.ssh/tmp_hosts"
    _run_amb_server_sh sh -c "mv ~/.ssh/tmp_hosts ~/.ssh/known_hosts"
}

config_agents(){
    local agents_name=$(_get_amb_agents_name)
    for i in $agents_name; do
        run_command _amb_start_agent_service $i
    done
}

_amb_start_agent_service() {
  local agent_name=${1:?"Usage: _amb_start_agent_service <agent_name>"}
  # set password to agent, for server ssh
  run_command _kubectl exec $agent_name -c amb-agent -- sh -c "echo Zasd_1234 | passwd root --stdin"
  run_command _kubectl exec $agent_name -c amb-agent -- sh -c "systemctl restart ntpd"
}

amb_tool_get_server_sshkey() {
  run_command _kubectl exec $(_get_amb_server_name) -c ambari-server -- sh -c "cat ~/.ssh/id_rsa"
}

amb_tool_get_agent_host_list() {
    for i in $(_get_amb_agents_ip); do
        echo "${i//./-}.ambari.pod.cluster.local"
    done
}

amb_replace_ambari_url() {
  local ambari_path="AMBARI-2.4.0.1/centos7/2.4.0.1-1"
  local baseurl=http://amb-httpd/${ambari_path}/
  local gpgkey=http://amb-httpd/${ambari_path}/RPM-GPG-KEY/RPM-GPG-KEY-Jenkins

  _run_amb_server_sh sh -c "sed -i 's/baseurl=.*/baseurl=${baseurl//\//\\/}/g' /etc/yum.repos.d/ambari.repo"
  _run_amb_server_sh sh -c "sed -i 's/gpgkey=.*/gpgkey=${gpgkey//\//\\/}/g' /etc/yum.repos.d/ambari.repo"
  _run_amb_server_sh sh -c "cat /etc/yum.repos.d/ambari.repo"
}

amb_tool_get_HDP_url() {
  debug "-------------HDP 2.4-------------"
  echo "http://amb-httpd/$HDP_v2_4_PATH"
  echo "http://amb-httpd/$HDP_v2_4_UTILS_PATH"
  debug "---------------------------------"
  debug "-------------HDP 2.6-------------"
  echo "http://amb-httpd/$HDP_v2_6_PATH"
  echo "http://amb-httpd/$HDP_v2_6_UTILS_PATH"
  debug "---------------------------------"
}


amb_test_amb_server_start() {
  local ambari_server_ip=$(get_ambari_server_ip)

  while [ 1 -eq 1 ]; do
    if curl ${ambari_server_ip}:8080; then
      break
    else
      sleep $SLEEP_TIME
    fi
  done
}

amb_tool_get_all_setting() {
  debug "=============HDP url============="
  amb_tool_get_HDP_url
  debug "=============agent host list============="
  amb_tool_get_agent_host_list
  debug "=============server sshkey============="
  amb_tool_get_server_sshkey
  debug "=========================="
}

amb_config_mysql_driver(){
  _run_amb_server_sh sh -c "ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar"
}


_check_hadoop_dir_input(){
  read -p "Please input Hadoop data storage dir, default:$HADOOP_DATA, input:" INPUT
  if [ "$INPUT" != "" ];then
      HADOOP_DATA=$INPUT
      sed -i "s/\/home\/hadoop_data/${HADOOP_DATA//\//\\/}/g" $AGENT_YAML
  fi
  echo "HADOOP_DATA=$HADOOP_DATA"

  read -p "Please input Hadoop log dir, default:$HADOOP_LOG, input:" INPUT
  if [ "$INPUT" != "" ];then
      HADOOP_LOG=$INPUT
      sed -i "s/\/home\/hadoop_log/${HADOOP_LOG//\//\\/}/g" $AGENT_YAML
  fi
  echo "HADOOP_LOG=$HADOOP_LOG"
}

amb_start_cluster(){
  local amb_agent_nums=${1:?"usage: amb_start_cluster <amb_agent_nums>"}
  local host_nums=$(_get-host-num)

  if [[ $amb_agent_nums > $host_nums ]]; then
    echo "Ambari agents numbers($amb_agent_nums) have to less and equal than host numbers($host_nums)"
    exit
  else
    sed -i "s/replicas: 5/replicas: $amb_agent_nums/g" $AGENT_YAML
  fi

  _check_hadoop_dir_input
  kubectl delete -f ../k8s_amb
  kubectl create -f ../k8s_amb
}

amb_config_cluster(){
    config_agents
    config_master
    amb_replace_ambari_url
    amb_config_mysql_driver
    amb_tool_get_all_setting
}

$@