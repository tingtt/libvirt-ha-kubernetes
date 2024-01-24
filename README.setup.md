# Setup libvirt host

This is the setup procedure for Ubuntu, please follow the steps for each distribution.

## References

- [KVM/Installation - Community Help Wiki (ubuntu.com)](https://help.ubuntu.com/community/KVM/Installation)
  - <span style="color:red">
    Please check <code>Pre-installation checklist</code>.
    </span>

## Setup

Install packages and permit libvirt to user.

```bash
apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst libosinfo-bin
usermod -aG libvirt `users`
```

Configure bridge intreface.

```bash
tee /etc/netplan/01-br0.yaml <<EOF
network:
  ethernets:
    eno1:
      dhcp4: false
    eno2:
      dhcp4: false
  bridges:
    br0:
      dhcp4: false
      addresses:
        - 192.168.3.254/24
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
      interfaces:
        - eno1
        - eno2
      routes:
        - to: default
          via: 192.168.3.1
EOF
netplan try
netplan apply
```

```bash
modprobe br_netfilter
tee /etc/sysctl.d/99-sysctl.conf <<EOF
net.bridge.bridge-nf-call-iptables = 0
EOF
sysctl -p
```
