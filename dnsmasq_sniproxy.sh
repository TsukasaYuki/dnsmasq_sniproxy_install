#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] You have use root!" && exit 1

disable_selinux(){
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
}

check_sys(){
    local checkType=$1
    local value=$2

    local release=''
    local systemPackage=''

    if [[ -f /etc/redhat-release ]]; then
        release="centos"
        systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /etc/issue; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /etc/issue; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        release="centos"
        systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /proc/version; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        release="centos"
        systemPackage="yum"
    fi

    if [[ "${checkType}" == "sysRelease" ]]; then
        if [ "${value}" == "${release}" ]; then
            return 0
        else
            return 1
        fi
    elif [[ "${checkType}" == "packageManager" ]]; then
        if [ "${value}" == "${systemPackage}" ]; then
            return 0
        else
            return 1
        fi
    fi
}

getversion(){
    if [[ -s /etc/redhat-release ]]; then
        grep -oE  "[0-9.]+" /etc/redhat-release
    else
        grep -oE  "[0-9.]+" /etc/issue
    fi
}

centosversion(){
    if check_sys sysRelease centos; then
        local code=$1
        local version="$(getversion)"
        local main_ver=${version%%.*}
        if [ "$main_ver" == "$code" ]; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

get_ip(){
    local IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    echo ${IP}
}

download(){
    local filename=$(basename $1)
    if [ -f ${1} ]; then
        echo "${filename} [found]"
    else
        echo "${filename} not found, download now..."
        wget --no-check-certificate -c -t3 -T60 -O ${1} ${2}
        if [ $? -ne 0 ]; then
            echo -e "[${red}Error${plain}] Download ${filename} failed."
            exit 1
        fi
    fi
}

error_detect_depends(){
    local command=$1
    local depend=`echo "${command}" | awk '{print $4}'`
    echo -e "[${green}Info${plain}] Starting to install package ${depend}"
    ${command} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Failed to install ${red}${depend}${plain}"
        exit 1
    fi
}

install_dependencies(){
    if check_sys packageManager yum; then
        echo -e "[${green}Info${plain}] Checking the EPEL repository..."
        if [ ! -f /etc/yum.repos.d/epel.repo ]; then
            yum install -y epel-release > /dev/null 2>&1
        fi
        [ ! -f /etc/yum.repos.d/epel.repo ] && echo -e "[${red}Error${plain}] Install EPEL repository failed, please check it." && exit 1
        [ ! "$(command -v yum-config-manager)" ] && yum install -y yum-utils > /dev/null 2>&1
        [ x"$(yum-config-manager epel | grep -w enabled | awk '{print $3}')" != x"True" ] && yum-config-manager --enable epel > /dev/null 2>&1
        echo -e "[${green}Info${plain}] Checking the EPEL repository complete..."

        yum_depends=(
            wget git autoconf automake curl gettext-devel libev-devel pcre-devel perl pkgconfig rpm-build udns-devel
        )
        for depend in ${yum_depends[@]}; do
            error_detect_depends "yum -y install ${depend}"
        done
        error_detect_depends "yum -y groupinstall development"
        if centosversion 6; then
          error_detect_depends "yum -y install centos-release-scl"
          error_detect_depends "yum -y install devtoolset-6-gcc-c++"
        fi
    elif check_sys packageManager apt; then
        apt_depends=(
            wget git autotools-dev cdbs debhelper dh-autoreconf dpkg-dev gettext libev-dev libpcre3-dev libudns-dev pkg-config fakeroot devscripts
        )
        apt-get -y update
        for depend in ${apt_depends[@]}; do
            error_detect_depends "apt-get -y install ${depend}"
        done
        error_detect_depends "apt-get -y install build-essential"
    fi
}

install_check(){
    if check_sys packageManager yum || check_sys packageManager apt; then
        if centosversion 5; then
            return 1
        fi
        return 0
    else
        return 1
    fi
	[ "$(netstat -lpn | grep -wE '53|80|443')" ] && echo -e "[${red}Error${plain}] There are other conflicting listening services, Please check if you have nginx and apache or other web services enabled.." && exit 1
}

config_firewall(){
    ports="53 80 443"
    if centosversion 6; then
        /etc/init.d/iptables status > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            for port in $ports
            do
                iptables -L -n | grep -i ${port} > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${port} -j ACCEPT
                    iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${port} -j ACCEPT
                else
                    echo -e "[${green}Info${plain}] port ${green}${port}${plain} already be enabled."
                fi
            done
            /etc/init.d/iptables save
            /etc/init.d/iptables restart
        else
            echo -e "[${yellow}Warning${plain}] iptables looks like not running or not installed, please enable port ${ports} manually if necessary."
        fi
    elif centosversion 7; then
        systemctl status firewalld > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            default_zone=$(firewall-cmd --get-default-zone)
            firewall-cmd --permanent --zone=${default_zone} --add-port=53/tcp
            firewall-cmd --permanent --zone=${default_zone} --add-port=53/udp
            firewall-cmd --permanent --zone=${default_zone} --add-port=80/tcp
            firewall-cmd --permanent --zone=${default_zone} --add-port=443/tcp
            firewall-cmd --reload
        else
            echo -e "[${yellow}Warning${plain}] firewalld looks like not running or not installed, please enable port ${ports} manually if necessary."
        fi
    fi
}

Hello() {
  echo ""
  echo -e "${yellow}Dnsmasq + SNI Proxy Auto install${plain}"
  echo -e "${yellow}Support System:  CentOS 6+, Debian8+, Ubuntu16+${plain}"
  echo ""
}

Help() {
  Hello
  echo "help：bash $0 [-h] [-i] [-u]"
  echo ""
  echo "  -h, --help            help"
  echo "  -i, --install         install Dnsmasq + SNI Proxy"
  echo "  -u, --uninstall       uinstall Dnsmasq + SNI Proxy"
  echo ""
}

Install() {
  Hello
  echo "Your System..."
  if ! install_check; then
      echo -e "[${red}Error${plain}] Your OS is not supported to run it!"
      echo "Please change to CentOS 6+/Debian 8+/Ubuntu 16+ and try again."
      exit 1
  fi
  if check_sys packageManager yum; then
		error_detect_depends "yum -y install net-tools"
  elif check_sys packageManager apt; then
		error_detect_depends "apt-get -y install net-tools"
  fi
  disable_selinux
  echo -e "[${green}Info${plain}] Checking the system complete..."
  echo "Install..."
  install_dependencies
  echo "Install Dnsmasq..."
  if check_sys packageManager yum; then
      error_detect_depends "yum -y install dnsmasq"
  elif check_sys packageManager apt; then
      error_detect_depends "apt-get -y install dnsmasq"
  fi
  wget https://github.com/TsukasaYuki/dnsmasq_sniproxy_install/raw/master/dnsmasq.conf -O /etc/dnsmasq.d/custom_netflix.conf >/dev/null 2>&1
  sed -i "s/PublicIP/`get_ip`/g" /etc/dnsmasq.d/custom_netflix.conf
  if check_sys packageManager yum; then
    if centosversion 6; then
      [ "$(grep -x -E "(conf-dir=/etc/dnsmasq.d|conf-dir=/etc/dnsmasq.d,.bak|conf-dir=/etc/dnsmasq.d/,\*.conf|conf-dir=/etc/dnsmasq.d,.rpmnew,.rpmsave,.rpmorig)" /etc/dnsmasq.conf)" ] || echo -e "\nconf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
      chkconfig dnsmasq on
      service dnsmasq start
    elif centosversion 7; then
      systemctl enable dnsmasq
      systemctl start dnsmasq
    fi
  elif check_sys packageManager apt; then
      [ "$(grep -x -E "(conf-dir=/etc/dnsmasq.d|conf-dir=/etc/dnsmasq.d,.bak|conf-dir=/etc/dnsmasq.d/,\*.conf|conf-dir=/etc/dnsmasq.d,.rpmnew,.rpmsave,.rpmorig)" /etc/dnsmasq.conf)" ] || echo "conf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
      systemctl enable dnsmasq
      systemctl restart dnsmasq
  fi
  echo "Install SNI Proxy..."
  if check_sys packageManager yum; then
    rpm -qa | grep sniproxy >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      rpm -e sniproxy
    fi
  elif check_sys packageManager apt; then
    dpkg -s sniproxy >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      dpkg -r sniproxy
    fi
  fi
  cd /tmp
  if [ -e sniproxy ]; then
    rm -rf sniproxy
  fi
  git clone https://github.com/dlundquist/sniproxy.git
  cd sniproxy
  if check_sys packageManager yum; then
      ./autogen.sh && ./configure && make dist
      if centosversion 6; then
         scl enable devtoolset-6 'rpmbuild --define "_sourcedir `pwd`" --define "_topdir /tmp/sniproxy/rpmbuild" --define "debug_package %{nil}" -ba redhat/sniproxy.spec'
      elif centosversion 7; then
        rpmbuild --define "_sourcedir `pwd`" --define "_topdir /tmp/sniproxy/rpmbuild" --define "debug_package %{nil}" -ba redhat/sniproxy.spec
      fi
      error_detect_depends "yum -y install /tmp/sniproxy/rpmbuild/RPMS/x86_64/sniproxy-*.rpm"
      wget https://github.com/dlundquist/sniproxy/raw/master/redhat/sniproxy.init -O /etc/init.d/sniproxy >/dev/null 2>&1 && chmod +x /etc/init.d/sniproxy
  elif check_sys packageManager apt; then
      ./autogen.sh && dpkg-buildpackage
      error_detect_depends "dpkg -i --no-debsig ../sniproxy_*.deb"
      wget https://github.com/dlundquist/sniproxy/raw/master/debian/init.d -O /etc/init.d/sniproxy >/dev/null 2>&1 && chmod +x /etc/init.d/sniproxy
      wget https://github.com/TsukasaYuki/dnsmasq_sniproxy_install/raw/master/sniproxy.default -O /etc/default/sniproxy >/dev/null 2>&1
  fi
  wget https://github.com/TsukasaYuki/dnsmasq_sniproxy_install/raw/master/sniproxy.conf -O /etc/sniproxy.conf >/dev/null 2>&1
  if [ ! -e /var/log/sniproxy ]; then
    mkdir /var/log/sniproxy
  fi
  echo "Install..."
  [ ! -f /usr/sbin/sniproxy ] && echo -e "[${red}Error${plain}] Install Sniproxy error." && exit 1
  echo -e "[${green}Info${plain}] Checking the sniproxy services complete..."
  [ ! -f /etc/init.d/sniproxy ] && echo -e "[${red}Error${plain}] Internet connection error." && exit 1
  echo -e "[${green}Info${plain}] Checking the sniproxy startup file complete..."
  echo "Start SNI Proxy Service..."
  if check_sys packageManager yum; then
    if centosversion 6; then
      chkconfig sniproxy on > /dev/null 2>&1
      service sniproxy start || (echo -e "[${red}Error:${plain}] Failed to start sniproxy." && exit 1)
    elif centosversion 7; then
      systemctl enable sniproxy > /dev/null 2>&1
      systemctl start sniproxy || (echo -e "[${red}Error:${plain}] Failed to start sniproxy." && exit 1)
    fi
  elif check_sys packageManager apt; then
      systemctl daemon-reload
      systemctl enable sniproxy > /dev/null 2>&1
      systemctl restart sniproxy || (echo -e "[${red}Error:${plain}] Failed to start sniproxy." && exit 1)
      wget https://raw.githubusercontent.com/TsukasaYuki/dnsmasq_sniproxy_install/master/ipadd -O /root/ipadd >/dev/null 2>&1
      wget https://raw.githubusercontent.com/TsukasaYuki/dnsmasq_sniproxy_install/master/ipdel -O /root/ipdel >/dev/null 2>&1
      wget https://raw.githubusercontent.com/TsukasaYuki/dnsmasq_sniproxy_install/master/ip -O /root/ip >/dev/null 2>&1
  bash /root/ip
  fi
  echo -e "[${green}Info${plain}] dnsmasq and sniproxy startup complete..."
  if check_sys packageManager yum; then
      echo "Check firewall..."
      config_firewall
      echo -e "[${green}Info${plain}] Firewall port detection complete..."
  fi
  echo ""
  echo -e "${yellow}Dnsmasq + SNI Proxy is OK！${plain}"
  echo ""
  echo -e "${yellow}Dnsmasq Listen IP：$(get_ip)${plain}"
  echo ""
}

Uninstall() {
  Hello
  echo -e "${yellow}Uinstall Dnsmasq&SNI Proxy?${plain}"
  echo -e "${yellow}[Enter] OK [N] NO${plain}"
  read selection
  if [[ -z $selection ]]; then
    echo -e "[${green}Info${plain}] Stoping dnsmasq and sniproxy"
    if check_sys packageManager yum; then
      if centosversion 6; then
        chkconfig sniproxy off > /dev/null 2>&1
        service sniproxy stop || echo -e "[${red}Error:${plain}] Failed to stop sniproxy."
        chkconfig dnsmasq off > /dev/null 2>&1
        service dnsmasq stop || echo -e "[${red}Error:${plain}] Failed to stop dnsmasq."
      elif centosversion 7; then
        systemctl disable sniproxy > /dev/null 2>&1
        systemctl stop sniproxy || echo -e "[${red}Error:${plain}] Failed to stop sniproxy."
        systemctl disable dnsmasq > /dev/null 2>&1
        systemctl stop dnsmasq || echo -e "[${red}Error:${plain}] Failed to stop dnsmasq."
      fi
    elif check_sys packageManager apt; then
      systemctl disable sniproxy > /dev/null 2>&1
      systemctl stop sniproxy || echo -e "[${red}Error:${plain}] Failed to stop sniproxy."
      systemctl disable dnsmasq > /dev/null 2>&1
      systemctl stop dnsmasq || echo -e "[${red}Error:${plain}] Failed to stop dnsmasq."
    fi
    echo -e "[${green}Info${plain}] Starting to uninstall dnsmasq and sniproxy"
    if check_sys packageManager yum; then
      yum remove dnsmasq sniproxy -y > /dev/null 2>&1
      if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Failed to uninstall ${red}dnsmasq${plain}"
      fi
    elif check_sys packageManager apt; then
      apt-get remove dnsmasq sniproxy -y > /dev/null 2>&1
      if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Failed to uninstall ${red}dnsmasq${plain}"
      fi
    fi
    rm -rf /etc/sniproxy.conf || echo -e "[${red}Error${plain}] Failed to delete sniproxy configuration file"
    rm -rf /etc/dnsmasq.d/custom_netflix.conf || echo -e "[${red}Error${plain}] Failed to delete dnsmasq configuration file"
    echo -e "[${green}Info${plain}] dnsmasq and sniproxy uninstall complete..."
  else
    exit 0
  fi
}

if [[ $# > 0 ]];then
    key="$1"
    case $key in
        -i|--install)
        Install
        ;;
        -u|--uninstall)
        Uninstall
        ;;
        -h|--help)
        Help
        ;;
    esac
else
    Help
fi
