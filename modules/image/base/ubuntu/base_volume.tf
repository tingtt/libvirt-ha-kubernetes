resource "libvirt_volume" "jammy" {
  name   = "jammy"
  source = "modules/image/base/ubuntu/jammy-server-cloudimg-amd64-disk-kvm.img"
  format = "qcow2"
}

output "jammy_volume_id" {
  value = libvirt_volume.jammy.id
}
