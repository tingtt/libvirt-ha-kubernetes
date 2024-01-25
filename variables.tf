variable "domain" {
  type    = string
  default = "example.com"
}

variable "libvirt_uri" {
  type    = string
  default = "qemu+ssh://tingtt@192.168.3.254/system"
}

variable "bridge_interface" {
  type    = string
  default = "br0"
}

variable "libvirt_guest_user" {
  type    = string
  default = "root"
}
variable "libvirt_guest_password" {
  type    = string
  default = "password"
}

variable "gateway" {
  type    = string
  default = "192.168.3.1"
}

variable "mirror_target" {
  type    = string
  default = "http://192.168.3.2:8080"
}

variable "k8s_control_plane_ips" {
  type    = list(string)
  default = ["192.168.3.241", "192.168.3.242", "192.168.3.243"]
}
variable "k8s_control_plane_vcpus" {
  type    = number
  default = 2
}
variable "k8s_control_plane_memory_size" {
  type    = number
  default = 4096
}
variable "k8s_control_plane_volume_size" {
  type    = number
  default = 68719476736 # 64GiB
}

variable "k8s_worker_ips" {
  type    = list(string)
  default = ["192.168.3.231", "192.168.3.232", "192.168.3.233"]
}
variable "k8s_worker_vcpus" {
  type    = number
  default = 4
}
variable "k8s_worker_memory_size" {
  type    = number
  default = 8192
}
variable "k8s_worker_volume_size" {
  type    = number
  default = 68719476736 # 64GiB
}

variable "metallb_first_ip" {
  type    = string
  default = "192.168.3.220"
}

variable "nameservers" {
  type    = list(string)
  default = ["8.8.8.8", "8.8.4.4"]
}

variable "k8s_pod_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
