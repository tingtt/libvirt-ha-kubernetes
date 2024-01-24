module "base_image_ubuntu" {
  source = "./modules/image/base/ubuntu"
}

resource "libvirt_network" "br0" {
  name      = "br0"
  mode      = "bridge"
  bridge    = var.bridge_interface
  autostart = true
}

module "k8s-first-control-plane" {
  source = "./modules/vm"

  name           = "k8s-control-plane01"
  base_volume_id = module.base_image_ubuntu.jammy_volume_id
  network_id     = libvirt_network.br0.id
  vcpu           = var.k8s_control_plane_vcpus
  memory         = var.k8s_control_plane_memory_size
  volume_size    = var.k8s_control_plane_volume_size
  user           = "root"
  password       = "password"
  cloudinit      = <<-EOS
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    runcmd:
      - |
        apt install -y containerd=1.7.2-0ubuntu1~22.04.1
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
        swappoff -a
        tee /etc/modules-load.d/k8s.conf <<EOF
        overlay
        br_netfilter
        EOF
        modprobe overlay
        modprobe br_netfilter
        tee /etc/sysctl.d/k8s.conf <<EOF
        net.bridge.bridge-nf-call-iptables  = 1
        net.bridge.bridge-nf-call-ip6tables = 1
        net.ipv4.ip_forward                 = 1
        EOF
        sysctl --system
        mkdir /etc/containerd
        containerd config default | sed \
          -e "s/SystemdCgroup = false/SystemdCgroup = true/" \
          -e "s/registry.k8s.io\/pause:3.8/registry.k8s.io\/pause:3.9/" | \
          tee /etc/containerd/config.toml
        systemctl restart containerd
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
          gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        tee /etc/apt/sources.list.d/kubernetes.list <<EOF
        deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /
        EOF
        apt update
        apt install -y kubelet=1.29.1-1.1 kubeadm=1.29.1-1.1 kubectl=1.29.1-1.1
        apt-mark hold kubelet kubeadm kubectl
        cp /etc/hosts /etc/hosts.org
        tee -a /etc/hosts <<EOF
        ${var.k8s_control_plane_ips[0]} haproxy.${var.domain}
        EOF
        kubeadm config images pull
        mkdir /root/kubernetes
        echo "Creating a Kubernetes cluster."
        kubeadm init --kubernetes-version=1.29.1 \
          --control-plane-endpoint=haproxy.${var.domain}:6443 \
          --pod-network-cidr=${var.k8s_pod_cidr} \
          --cri-socket=unix:/run/containerd/containerd.sock \
          --upload-certs | tail -n 12 | head -n3 > /root/kubernetes/join.sh
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
        export KUBECONFIG=/root/.kube/config
        echo "Installing calico cni."
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
        echo "Waiting on calico to start up..."
        while ! ( \
          kubectl wait --namespace kube-system \
            --for=condition=ready pod \
            --selector=k8s-app=calico-kube-controllers \
            --timeout=120s \
        ); do sleep 10; done
        kubectl taint nodes --all node-role.kubernetes.io/control-plane-
        echo "Installing metallb."
        kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
        echo "Waiting on metallb to start up..."
        while ! ( \
          kubectl wait --namespace metallb-system \
            --for=condition=ready pod \
            --selector=component=speaker \
            --timeout=120s \
        ); do sleep 10; done
        kubectl apply -f ${var.mirror_target}/metallb-l2-advertisement.yaml
        echo "Installing haproxy."
        kubectl apply -f ${var.mirror_target}/haproxy.yaml
        python3 -m http.server 8080 --directory /root/kubernetes &
        sh -c 'sleep 5m && lsof -i:8080 -t |xargs kill -9 && rm -rf /root/kubernetes' &
        echo "Installing ingress-nginx."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
        mv -f /etc/hosts.org /etc/hosts
        tee -a /etc/hosts <<EOF
        ${var.metallb_first_ip} haproxy.${var.domain}
        EOF
  EOS
  ip             = "${var.k8s_control_plane_ips[0]}/24"
  gateway        = var.gateway
  nameservers    = var.nameservers
}

module "k8s-control-plane" {
  source = "./modules/vm"

  count = length(var.k8s_control_plane_ips) - 1

  name           = "k8s-control-plane${format("%02d", count.index + 2)}"
  base_volume_id = module.base_image_ubuntu.jammy_volume_id
  network_id     = libvirt_network.br0.id
  vcpu           = var.k8s_control_plane_vcpus
  memory         = var.k8s_control_plane_memory_size
  volume_size    = var.k8s_control_plane_volume_size
  user           = "root"
  password       = "password"
  cloudinit      = <<-EOS
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    runcmd:
      - |
        apt install -y containerd=1.7.2-0ubuntu1~22.04.1
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
        swappoff -a
        tee /etc/modules-load.d/k8s.conf <<EOF
        overlay
        br_netfilter
        EOF
        modprobe overlay
        modprobe br_netfilter
        tee /etc/sysctl.d/k8s.conf <<EOF
        net.bridge.bridge-nf-call-iptables  = 1
        net.bridge.bridge-nf-call-ip6tables = 1
        net.ipv4.ip_forward                 = 1
        EOF
        sysctl --system
        mkdir /etc/containerd
        containerd config default | sed \
          -e "s/SystemdCgroup = false/SystemdCgroup = true/" \
          -e "s/registry.k8s.io\/pause:3.8/registry.k8s.io\/pause:3.9/" | \
          tee /etc/containerd/config.toml
        systemctl restart containerd
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
          gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        tee /etc/apt/sources.list.d/kubernetes.list <<EOF
        deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /
        EOF
        apt update
        apt install -y kubelet=1.29.1-1.1 kubeadm=1.29.1-1.1 kubectl=1.29.1-1.1
        apt-mark hold kubelet kubeadm kubectl
        tee -a /etc/hosts <<EOF
        ${var.metallb_first_ip} haproxy.${var.domain}
        EOF
        kubeadm config images pull
        echo "Waiting for initialization of the first control plane..."
        while ! (curl -s ${var.k8s_control_plane_ips[0]}:8080 > /dev/null); do sleep 10; done
        curl -sL ${var.k8s_control_plane_ips[0]}:8080/join.sh | tee join.sh
        sh join.sh
        rm join.sh
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
  EOS
  ip             = "${var.k8s_control_plane_ips[count.index + 1]}/24"
  gateway        = var.gateway
  nameservers    = var.nameservers
}

module "k8s-worker" {
  source = "./modules/vm"

  count = length(var.k8s_worker_ips)

  name           = "k8s-worker${format("%02d", count.index + 1)}"
  base_volume_id = module.base_image_ubuntu.jammy_volume_id
  network_id     = libvirt_network.br0.id
  vcpu           = var.k8s_worker_vcpus
  memory         = var.k8s_worker_memory_size
  volume_size    = var.k8s_worker_volume_size
  user           = "root"
  password       = "password"
  cloudinit      = <<-EOS
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    runcmd:
      - |
        apt install -y containerd=1.7.2-0ubuntu1~22.04.1
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
        swappoff -a
        tee /etc/modules-load.d/k8s.conf <<EOF
        overlay
        br_netfilter
        EOF
        modprobe overlay
        modprobe br_netfilter
        tee /etc/sysctl.d/k8s.conf <<EOF
        net.bridge.bridge-nf-call-iptables  = 1
        net.bridge.bridge-nf-call-ip6tables = 1
        net.ipv4.ip_forward                 = 1
        EOF
        sysctl --system
        mkdir /etc/containerd
        containerd config default | sed \
          -e "s/SystemdCgroup = false/SystemdCgroup = true/" \
          -e "s/registry.k8s.io\/pause:3.8/registry.k8s.io\/pause:3.9/" | \
          tee /etc/containerd/config.toml
        systemctl restart containerd
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
          gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        tee /etc/apt/sources.list.d/kubernetes.list <<EOF
        deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /
        EOF
        apt update
        apt install -y kubelet=1.29.1-1.1 kubeadm=1.29.1-1.1 kubectl=1.29.1-1.1
        apt-mark hold kubelet kubeadm kubectl
        tee -a /etc/hosts <<EOF
        ${var.metallb_first_ip} haproxy.${var.domain}
        EOF
        echo "Waiting for initialization of the first control plane..."
        while ! (curl -s ${var.k8s_control_plane_ips[0]}:8080 > /dev/null); do sleep 10; done
        curl -s ${var.k8s_control_plane_ips[0]}:8080/join.sh | head -n2 | tee join.sh
        sh join.sh
        rm join.sh
  EOS
  ip             = "${var.k8s_worker_ips[count.index]}/24"
  gateway        = var.gateway
  nameservers    = var.nameservers
}
