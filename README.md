### Download support software
```
yum install yum-plugin-downloadonly
yum install --downloadonly --downloaddir=/home/hdp_httpd_home/ENV_TOOLS sshpass pdsh git docker-io jq iptables-services
```

If downloading a installed package, "yumdownloader" is useful.
```
yum install yum-utils
yumdownloader --destdir /home/hdp_httpd_home/ENV_TOOLS --resolve sshpass pdsh git docker-io jq iptables-services  
```

```
[ENV_TOOLS]
name=ENV_TOOLS
baseurl=http://192.0.2.251/ENV_TOOLS

path=/
enabled=1
gpgcheck=0
```

### Install software
```
yum localinstall *
```

