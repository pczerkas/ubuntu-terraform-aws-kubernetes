#!/bin/bash

exec &> /var/log/init-aws-kubernetes-master.log

set -o verbose
set -o errexit
set -o pipefail

export KUBEADM_TOKEN=${kubeadm_token}
export DNS_NAME=${dns_name}
export IP_ADDRESS=${ip_address}
export CLUSTER_NAME=${cluster_name}
export ASG_NAME=${asg_name}
export ASG_MIN_NODES="${asg_min_nodes}"
export ASG_MAX_NODES="${asg_max_nodes}"
export AWS_REGION=${aws_region}
export AWS_SUBNETS="${aws_subnets}"
export ADDONS="${addons}"
export KUBERNETES_VERSION="1.24.4"

# Set this only after setting the defaults
set -o nounset

# We needed to match the hostname expected by kubeadm an the hostname used by kubelet
LOCAL_IP_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
FULL_HOSTNAME="$(curl -s http://169.254.169.254/latest/meta-data/hostname)"

# Make DNS lowercase
DNS_NAME=$(echo "$DNS_NAME" | tr 'A-Z' 'a-z')

# Install AWS CLI client
apt-get -y update
apt-get -y install python3 python3-pip
pip3 install awscli --upgrade
apt-get install -y apt-transport-https curl

########################################
########################################
# Tag subnets
########################################
########################################
for SUBNET in $AWS_SUBNETS
do
  aws ec2 create-tags --resources $SUBNET --tags Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared --region $AWS_REGION
done

########################################
########################################
# Install containerd
########################################
########################################
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sysctl --system

# download the latest version of containerd from GitHub and extract the files
wget https://github.com/containerd/containerd/releases/download/v1.6.6/containerd-1.6.6-linux-amd64.tar.gz
tar Czxvf /usr/local containerd-1.6.6-linux-amd64.tar.gz

# download the systemd service file and set it up so that you can manage the service via systemd
wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
mv containerd.service /usr/lib/systemd/system/

# start the containerd service
systemctl daemon-reload
systemctl enable --now containerd

# download the latest version of runC from GitHub and install it
wget https://github.com/opencontainers/runc/releases/download/v1.1.2/runc.amd64
install -m 755 runc.amd64 /usr/local/sbin/runc

# containerd uses a configuration file config.toml for handling its demons. When installing containerd using
# official binaries, you will not get the configuration file. So, generate the default configuration file
mkdir -p /etc/containerd/
containerd config default | sudo tee /etc/containerd/config.toml

# if you plan to use containerd as the runtime for Kubernetes, configure the systemd cgroup driver for runC
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# restart the containerd service
systemctl restart containerd

########################################
########################################
# Install Kubernetes components
########################################
########################################
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF | tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
swapoff -a

# Start services
systemctl enable kubelet
systemctl start kubelet

########################################
########################################
# Initialize the Kube cluster
########################################
########################################

# Initialize the master
cat >/tmp/kubeadm.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: $KUBEADM_TOKEN
  ttl: 0s
  usages:
  - signing
  - authentication
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    cloud-provider: aws
    read-only-port: "10255"
    cgroup-driver: systemd
  name: $FULL_HOSTNAME
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
apiServer:
  certSANs:
  - $DNS_NAME
  - $IP_ADDRESS
  - $LOCAL_IP_ADDRESS
  - $FULL_HOSTNAME
  extraArgs:
    cloud-provider: aws
  timeoutForControlPlane: 5m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager:
  extraArgs:
    cloud-provider: aws
dns: {}
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: k8s.gcr.io
kubernetesVersion: v$KUBERNETES_VERSION
networking:
  dnsDomain: cluster.local
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler: {}
---
EOF

kubeadm reset --force
kubeadm init --config /tmp/kubeadm.yaml

# Use the local kubectl config for further kubectl operations
export KUBECONFIG=/etc/kubernetes/admin.conf

# Install calico
kubectl apply -f https://docs.projectcalico.org/archive/v3.23/manifests/calico.yaml

########################################
########################################
# Create user and kubeconfig files
########################################
########################################

# Allow the user to administer the cluster
kubectl create clusterrolebinding admin-cluster-binding --clusterrole=cluster-admin --user=admin

# Prepare the kubectl config file for download to client (IP address)
export KUBECONFIG_OUTPUT=/home/ubuntu/kubeconfig_ip
kubeadm kubeconfig user --client-name admin --config /tmp/kubeadm.yaml > $KUBECONFIG_OUTPUT
chown ubuntu:ubuntu $KUBECONFIG_OUTPUT
chmod 0600 $KUBECONFIG_OUTPUT

cp /etc/kubernetes/admin.conf /home/ubuntu/kubeconfig
sed -i "s/server: https:\/\/.*:6443/server: https:\/\/$IP_ADDRESS:6443/g" /home/ubuntu/kubeconfig_ip
sed -i "s/server: https:\/\/.*:6443/server: https:\/\/$DNS_NAME:6443/g" /home/ubuntu/kubeconfig
chown ubuntu:ubuntu /home/ubuntu/kubeconfig
chmod 0600 /home/ubuntu/kubeconfig

########################################
########################################
# Install addons
########################################
########################################
for ADDON in $ADDONS
do
  curl $ADDON | envsubst > /tmp/addon.yaml
  kubectl apply -f /tmp/addon.yaml
  rm /tmp/addon.yaml
done
