variable "name" {
  type = string
}

variable "base_volume_id" {
  type = string
}

variable "network_id" {
  type = string
}

variable "vcpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "volume_size" {
  type = number
}

variable "user" {
  type = string
}

variable "password" {
  type = string
}

variable "cloudinit" {
  type = string
}

variable "ip" {
  # e.g. "192.168.3.254/24"
  type = string
}

variable "gateway" {
  type = string
}

variable "nameservers" {
  type = list(string)
}

resource "libvirt_volume" "vda" {
  name           = var.name
  base_volume_id = var.base_volume_id
  size           = var.volume_size
}

resource "libvirt_cloudinit_disk" "cloudinit" {
  name = "cloudinit_${var.name}"

  user_data = <<-EOS
    #cloud-config
    hostname: ${var.name}
    chpasswd:
      list: ${var.user}:${var.password}
      expire: false
    ${var.cloudinit}
  EOS

  network_config = <<-EOS
    network:
      version: 1
      config:
        - type: physical
          name: ens3
          subnets:
            - type: static
              address: ${var.ip}
              gateway: ${var.gateway}
        - type: nameserver
          address: ${jsonencode(var.nameservers)}
  EOS
}

resource "libvirt_domain" "guest" {
  name   = var.name
  memory = var.memory
  vcpu   = var.vcpu

  disk { volume_id = libvirt_volume.vda.id }

  cloudinit = libvirt_cloudinit_disk.cloudinit.id

  network_interface {
    network_id = var.network_id
  }

  console {
    type        = "pty"
    target_port = "0"
  }
}
