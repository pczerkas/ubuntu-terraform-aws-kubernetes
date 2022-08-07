#!/bin/bash

exec &> /var/log/init-aws-kubernetes-node.log

set -o verbose
set -o errexit
set -o pipefail

export KUBEADM_TOKEN=${kubeadm_token}
export MASTER_IP=${master_private_ip}
export DNS_NAME=${dns_name}
export KUBERNETES_VERSION="1.24.3"

# Set this only after setting the defaults
set -o nounset

# We needed to match the hostname expected by kubeadm an the hostname used by kubelet
LOCAL_IP_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
FULL_HOSTNAME="$(curl -s http://169.254.169.254/latest/meta-data/hostname)"

# Make DNS lowercase
DNS_NAME=$(echo "$DNS_NAME" | tr 'A-Z' 'a-z')

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
wget https://github.com/opencontainers/runc/releases/download/v1.1.3/runc.amd64
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
# Initialize the Kube node
########################################
########################################
cat >/tmp/kubeadm.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $MASTER_IP:6443
    token: $KUBEADM_TOKEN
    unsafeSkipCAVerification: true
  timeout: 5m0s
  tlsBootstrapToken: $KUBEADM_TOKEN
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    cloud-provider: aws
    read-only-port: "10255"
    cgroup-driver: systemd
  name: $FULL_HOSTNAME
  taints: null
caCertPath: /etc/kubernetes/pki/ca.crt
---
EOF

kubeadm reset --force
kubeadm join --config /tmp/kubeadm.yaml
