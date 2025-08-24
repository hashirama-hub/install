#!/usr/bin/env bash
# install-k8s-containerd.sh
# Thiết lập môi trường để cài Kubernetes (kubelet/kubeadm/kubectl) + containerd trên Ubuntu.

set -euo pipefail

#--- Tiện ích nhỏ
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
trap 'err "Lỗi tại dòng $LINENO. Xem log ở trên."' ERR

#--- sudo nếu cần
if [[ $EUID -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi
export DEBIAN_FRONTEND=noninteractive

#--- Thông tin hệ thống
ARCH="$(dpkg --print-architecture)"
UBUNTU_CODENAME="$(
  if [ -r /etc/os-release ]; then . /etc/os-release; echo "${UBUNTU_CODENAME:-}"; fi
)"
if [[ -z "${UBUNTU_CODENAME}" ]]; then
  UBUNTU_CODENAME="$(lsb_release -cs)"
fi

#======================================================================
# 1) Tắt swap & vô hiệu hoá trong fstab
#======================================================================
log "Tắt swap và comment cấu hình swap trong /etc/fstab (nếu có)…"
$SUDO swapoff -a || true
if [ -f /etc/fstab ]; then
  TS="$(date +%F_%H%M%S)"
  $SUDO cp -a /etc/fstab /etc/fstab.bak."$TS"
  # Comment mọi dòng khai báo swap chưa comment
  $SUDO sed -ri 's/^([^#].*\s+swap\s+.*)$/# \1/g' /etc/fstab || true
  $SUDO sed -ri 's/^([^#].*swap\.img.*)$/# \1/g' /etc/fstab || true
  $SUDO sed -ri 's/^([^#].*swapfile.*)$/# \1/g' /etc/fstab || true
fi

#======================================================================
# 2) Cấu hình module kernel cho containerd/K8s
#======================================================================
log "Khai báo module kernel overlay & br_netfilter…"
cat <<'EOF' | $SUDO tee /etc/modules-load.d/containerd.conf >/dev/null
overlay
br_netfilter
EOF

log "Nạp module kernel…"
$SUDO modprobe overlay
$SUDO modprobe br_netfilter

#======================================================================
# 3) Cấu hình sysctl cho mạng
#======================================================================
log "Thiết lập sysctl cho Kubernetes…"
cat <<'EOF' | $SUDO tee /etc/sysctl.d/kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

log "Áp dụng sysctl --system…"
$SUDO sysctl --system

#======================================================================
# 4) Cài gói cơ bản & thêm kho Docker
#======================================================================
log "Cài đặt gói tiện ích cần thiết…"
$SUDO apt-get update -y
$SUDO apt-get install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates lsb-release

log "Thêm kho Docker (để cài containerd.io)…"
$SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg
$SUDO add-apt-repository -y "deb [arch=${ARCH}] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable"

#======================================================================
# 5) Cài containerd
#======================================================================
log "Cài đặt containerd.io…"
$SUDO apt-get update -y
$SUDO apt-get install -y containerd.io

#======================================================================
# 6) Cấu hình containerd (SystemdCgroup = true)
#======================================================================
log "Sinh file cấu hình containerd mặc định & bật SystemdCgroup…"
$SUDO mkdir -p /etc/containerd
$SUDO sh -c 'containerd config default > /etc/containerd/config.toml'
$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

#======================================================================
# 7) Khởi động & bật containerd
#======================================================================
log "Khởi động containerd và bật khởi động cùng hệ thống…"
$SUDO systemctl daemon-reload
$SUDO systemctl restart containerd
$SUDO systemctl enable containerd

#======================================================================
# 8) Thêm kho Kubernetes (v1.30 stable)
#======================================================================
log "Thêm kho Kubernetes v1.30 (pkgs.k8s.io)…"
$SUDO install -m 0755 -d /etc/apt/keyrings
$SUDO curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

#======================================================================
# 9) Cài kubelet, kubeadm, kubectl & hold phiên bản
#======================================================================
log "Cài đặt kubelet kubeadm kubectl và giữ phiên bản…"
$SUDO apt-get update -y
$SUDO apt-get install -y kubelet kubeadm kubectl
$SUDO apt-mark hold kubelet kubeadm kubectl

#======================================================================
# 10) Thông tin tổng kết
#======================================================================
log "Hoàn tất! Thông tin phiên bản:"
(set +e
  containerd --version || true
  kubeadm version -o short 2>/dev/null || kubeadm version || true
  kubectl version --client --output=yaml || true
)
log "Bạn có thể tiếp tục: 'sudo kubeadm init' (máy master) hoặc 'sudo kubeadm join …' (node)."
