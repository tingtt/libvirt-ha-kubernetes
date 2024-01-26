# libvirt-ha-kubernetes

## Default envinronment

### libvirt guests

- k8s-control-plane01, 02, 03
  - os: 22.04.3 LTS (Jammy Jellyfish)
  - ip: `192.168.3.241` - `192.168.3.243`
  - vcpu: 2
  - memory: 4GiB
  - disk: 64GiB
  - nameservers: `8.8.8.8`, `8.8.4.4`
- k8s-worker01, 02, 03
  - os: 22.04.3 LTS (Jammy Jellyfish)
  - ip: `192.168.3.231` - `192.168.3.233`
  - vcpu: 4
  - memory: 8GiB
  - disk: 64GiB
  - nameservers: `8.8.8.8`, `8.8.4.4`

### kubernetes

- calico cni
  - pod CIDR: `10.0.0.0/16`
- metallb
  - VIP pool: `192.168.3.220` - `192.168.3.229`
- haproxy (for kube-apiserver)
  - Service IP (LoadBalancer): `192.168.3.220`
- ingress-nginx
  - Service IP (LoadBalancer): `192.168.3.221`
- argocd

## Usage

### requirements

#### Terraform client

- terraform
- bunx (npx can be used)
- mkisofs (you can install with `brew install cdrtools`)

#### libvirt host

- [Setup libvirt host](blob/main/README.setup.md)

### Download os image

```bash
curl https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img \
  -o modules/image/base/ubuntu/jammy-server-cloudimg-amd64-disk-kvm.img
```

### Create `.tfvars`

```bash
# terraform.tfvars

# domain:
#   haproxy.example.com is called on each libvirt guests.
#   DNS name resolution is not required because it is specified in /etc/hosts on each libvirt guests.
domain = "example.com"

# libvirt_uri:
#   https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs
libvirt_uri = "qemu+ssh://ubuntu@192.168.3.254/system"

# bridge_interface:
#   Specify the network interface to be used by libvirt.
#   This configuration uses the network in bridge mode.
#   https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs/resources/network
bridge_interface = "br0"

libvirt_guest_user = root
libvirt_guest_password = password

# mirror_target:
#   IP of the host to run `make apply`
mirror_target = "http://192.168.3.2:8081"

k8s_control_plane_ips = ["192.168.3.241", "192.168.3.242", "192.168.3.243"]
k8s_worker_ips = ["192.168.3.231", "192.168.3.232", "192.168.3.233"]
metallb_first_ip = "192.168.3.220"
nameservers = ["8.8.8.8", "8.8.4.4"]

k8s_pod_cidr = "10.0.0.0/16"

# command:
#   If needed, specify the command you wish to execute on each VM.
command = "apt install -y nfs-common"

# argocd_git_repo:
#   Must be in a format for ssh.
argocd_git_repo = git@github.com:<YOUR_GIT_REPOSITORY_URL>.git
argocd_git_private_key_path = .ssh/id_rsa
# argocd_git_repo_dir:
#   Specify the directory that ArgoCD will be polling
argocd_git_repo_dir = .
argocd_git_repo_dir_recurse = false
```

### Create kubernetes manifests

#### Copy from templates

```bash
cp kubernetes/haproxy.yaml{.template,}
cp kubernetes/metallb-l2-advertisement.yaml{.template,}
```

#### Edit manifest (optional)

- `kubernetes/haproxy.yaml` line 26-28.
  - Specify the upstream control-planes.
- `kubernetes/metallb-l2-advertisement.yaml` line 8.
  - Specify IP pool to be used for load balancer VIP.

### Apply

Run in a network accessible from the control plane.
Cause `make apply` command runs http-server to expose `./kubernetes/` for 10 minutes.

```bash
make plan
make apply PORT=8081
```
