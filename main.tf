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
  user           = var.libvirt_guest_user
  password       = var.libvirt_guest_password
  cloudinit      = <<-EOS
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    write_files:
      - content: |
          ${indent(6, format("%s", file(var.argocd_git_private_key_path)))}
        path: /root/.ssh/github
    runcmd:
      - |
        #? Install dependencies
        apt install -y containerd=1.7.12-0ubuntu2~22.04.1
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
        apt install -y kubelet=1.29.9-1.1 kubeadm=1.29.9-1.1 kubectl=1.29.9-1.1
        apt-mark hold kubelet kubeadm kubectl
        #! Specify host temporary for injecting kube-apiserver host
        cp /etc/hosts /etc/hosts.org
        tee -a /etc/hosts <<EOF
        ${var.k8s_control_plane_ips[0]} haproxy.${var.domain}
        EOF
        kubeadm config images pull
        mkdir /root/kubernetes
        #? Create a Kubernetes cluster
        echo "Creating a Kubernetes cluster."
        kubeadm init --kubernetes-version=1.29.1 \
          --control-plane-endpoint=haproxy.${var.domain}:6443 \
          --pod-network-cidr=${var.k8s_pod_cidr} \
          --cri-socket=unix:/run/containerd/containerd.sock \
          --upload-certs | tail -n 12 | head -n3 > /root/kubernetes/join.sh
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
        export KUBECONFIG=/root/.kube/config
        #? Install calico cni
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
        #? Install metallb
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
        #? Install haproxy for kube-apiserver
        echo "Installing haproxy."
        kubectl apply -f ${var.mirror_target}/haproxy.yaml
        #? Wait for haproxy VIP provisioning
        echo "Waiting for haproxy VIP provisioning..."
        while ! (curl -sk https://${var.metallb_first_ip}:6443/livez > /dev/null); do sleep 10; done
        #! Specify host of loadbalancer for kube-apiserver
        mv -f /etc/hosts.org /etc/hosts
        tee -a /etc/hosts <<EOF
        ${var.metallb_first_ip} haproxy.${var.domain}
        EOF
        #! Start http server sharing join command (for 5 minutes)
        python3 -m http.server 8080 --directory /root/kubernetes &
        sh -c 'sleep 5m && lsof -i:8080 -t |xargs kill -9 && rm -rf /root/kubernetes' &
        #? Install ingress-nginx
        echo "Installing ingress-nginx."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
        #? Execute custom commands
        ${indent(6, format("%s", var.command))}
        #? Wait for worker01 up
        while ! ( \
          kubectl wait --for=condition=Ready node/k8s-worker01 --timeout=120s \
        ); do sleep 10; done
        #? Install argocd
        echo "Installing argocd."
        kubectl create namespace argocd
        kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
        curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
        install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
        rm argocd-linux-amd64
        while ! ( \
          kubectl wait --namespace argocd \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/name=argocd-server \
            --timeout=120s \
        ); do sleep 10; done
        #? Setup argocd
        echo "Logining to argocd."
        #! Start port-forward svc/argocd-server
        kubectl port-forward svc/argocd-server -n argocd 8082:443 &
        sleep 10s
        export HOME=/root ; \
          argocd login localhost:8082 --insecure --username admin --password `argocd admin initial-password -n argocd | head -n1`
        sleep 20s
        echo "Adding application to argocd."
        export HOME=/root ; \
          argocd repo add ${var.argocd_git_repo} --ssh-private-key-path /root/.ssh/github
        sleep 30s
        export HOME=/root ; \
          argocd app create main --dest-server https://kubernetes.default.svc \
            --dest-namespace ${var.argocd_app_dest_namespace} \
            --repo ${var.argocd_git_repo} \
            --revision ${var.argocd_app_git_repo_revision} \
            --path ${var.argocd_app_git_repo_dir} \
            --sync-policy automated
        sleep 20s
        #! Stop port-forward svc/argocd-server
        lsof -i:8082 -t |xargs kill -9
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
  user           = var.libvirt_guest_user
  password       = var.libvirt_guest_password
  cloudinit      = <<-EOS
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    runcmd:
      - |
        #? Install dependencies
        apt install -y containerd=1.7.12-0ubuntu2~22.04.1
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
        apt install -y kubelet=1.29.9-1.1 kubeadm=1.29.9-1.1 kubectl=1.29.9-1.1
        apt-mark hold kubelet kubeadm kubectl
        #! Specify host of loadbalancer for kube-apiserver
        tee -a /etc/hosts <<EOF
        ${var.metallb_first_ip} haproxy.${var.domain}
        EOF
        kubeadm config images pull
        #? Join to cluster
        echo "Waiting for initialization of the first control plane..."
        while ! (curl -s ${var.k8s_control_plane_ips[0]}:8080 > /dev/null); do sleep 10; done
        curl -sL ${var.k8s_control_plane_ips[0]}:8080/join.sh | tee join.sh
        sh join.sh
        rm join.sh
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
        #? Execute custom commands
        ${indent(6, format("%s", var.command))}
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
  user           = var.libvirt_guest_user
  password       = var.libvirt_guest_password
  cloudinit      = <<-EOS
    package_upgrade: true
    packages:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    runcmd:
      - |
        #? Install dependencies
        apt install -y containerd=1.7.12-0ubuntu2~22.04.1
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
        apt install -y kubelet=1.29.9-1.1 kubeadm=1.29.9-1.1 kubectl=1.29.9-1.1
        apt-mark hold kubelet kubeadm kubectl
        #! Specify host of loadbalancer for kube-apiserver
        tee -a /etc/hosts <<EOF
        ${var.metallb_first_ip} haproxy.${var.domain}
        EOF
        #? Join to cluster
        echo "Waiting for initialization of the first control plane..."
        while ! (curl -s ${var.k8s_control_plane_ips[0]}:8080 > /dev/null); do sleep 10; done
        curl -s ${var.k8s_control_plane_ips[0]}:8080/join.sh | head -n2 | tee join.sh
        sh join.sh
        rm join.sh
        #? Execute custom commands
        ${indent(6, format("%s", var.command))}
  EOS
  ip             = "${var.k8s_worker_ips[count.index]}/24"
  gateway        = var.gateway
  nameservers    = var.nameservers
}
