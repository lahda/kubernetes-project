#!/usr/bin/env bash


set -euo pipefail


K8S_VERSION="1.30"                       # branche kubeadm/kubelet/kubectl (dépôt pkgs.k8s.io)
POD_NETWORK_CIDR="192.168.0.0/16"        # doit correspondre au manifest Calico ci-dessous
CALICO_VERSION="v3.27.0"
DASHBOARD_VERSION="v2.7.0"               # Kubernetes Dashboard (interface web du cluster)
JOIN_FILE="/root/kubeadm-join-command.sh"
DASHBOARD_TOKEN_FILE="/root/kubernetes-dashboard-token.txt"
LOG_PREFIX="[install-kubeadm]"

log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERREUR : $*" >&2; exit 1; }


[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté avec sudo (ex: sudo ./install-kubeadm.sh prep)"

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  log "Attention : ce script a été écrit et testé pour Ubuntu 22.04 LTS. Poursuite quand même..."
fi

ACTION="${1:-}"
[[ -n "$ACTION" ]] || die "Usage : $0 {single|prep|master|worker} [argument optionnel]"


REAL_USER="${SUDO_USER:-root}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)


prep_system() {
  log "Désactivation du swap..."
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab

  log "Chargement des modules noyau overlay et br_netfilter..."
  cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  log "Configuration sysctl (forwarding IP + bridging)..."
  cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system > /dev/null

  log "Installation de containerd..."
  apt-get update -qq
  apt-get install -y -qq containerd
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd -q

  if command -v kubeadm >/dev/null 2>&1; then
    log "kubeadm déjà installé, on passe l'installation du paquet."
  else
    log "Ajout du dépôt Kubernetes officiel (pkgs.k8s.io, branche ${K8S_VERSION})..."
    apt-get install -y -qq apt-transport-https ca-certificates curl gpg
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list

    log "Installation de kubeadm, kubelet, kubectl..."
    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl > /dev/null
  fi

  log "Préparation du système terminée."
}


detect_private_ip() {

  local token
  token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
  if [[ -n "$token" ]]; then
    curl -sf -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null || true
  else
    curl -sf "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null || true
  fi
}

init_master() {
  local advertise_ip="${1:-}"
  [[ -z "$advertise_ip" ]] && advertise_ip="$(detect_private_ip)"
  local init_args=(--pod-network-cidr="${POD_NETWORK_CIDR}")
  [[ -n "$advertise_ip" ]] && init_args+=(--apiserver-advertise-address="${advertise_ip}")

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log "Le control-plane semble déjà initialisé (/etc/kubernetes/admin.conf existe). Rien à faire."
  else
    log "Initialisation du control-plane : kubeadm init ${init_args[*]}"
    kubeadm init "${init_args[@]}"
  fi

  log "Configuration de kubectl pour l'utilisateur ${REAL_USER}..."
  mkdir -p "${REAL_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
  chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.kube/config"

  log "Installation du CNI Calico (${CALICO_VERSION})..."
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

  install_dashboard

  log "Génération de la commande de jonction pour le(s) worker(s)..."
  echo "#!/usr/bin/env bash" > "${JOIN_FILE}"
  kubeadm token create --print-join-command >> "${JOIN_FILE}"
  chmod +x "${JOIN_FILE}"

  echo
  log "=========================================================================="
  log "Master prêt. Commande à copier sur CHAQUE worker (aussi sauvegardée dans ${JOIN_FILE}) :"
  echo
  tail -n1 "${JOIN_FILE}"
  echo
  log "Exemple : sudo ./install-kubeadm.sh worker \"$(tail -n1 "${JOIN_FILE}")\""
  log "=========================================================================="
  print_dashboard_access
}


install_dashboard() {
  log "Installation du Kubernetes Dashboard (${DASHBOARD_VERSION})..."
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

  log "Création du compte admin-user pour se connecter au Dashboard..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: kubernetes-dashboard
EOF

  log "Attente que le Dashboard soit prêt..."
  kubectl -n kubernetes-dashboard rollout status deployment/kubernetes-dashboard --timeout=120s || true

  log "Génération d'un jeton de connexion (sauvegardé dans ${DASHBOARD_TOKEN_FILE})..."
  kubectl -n kubernetes-dashboard create token admin-user --duration=24h > "${DASHBOARD_TOKEN_FILE}" 2>/dev/null \
    || log "Impossible de générer le jeton maintenant, relancez : kubectl -n kubernetes-dashboard create token admin-user"
  chmod 600 "${DASHBOARD_TOKEN_FILE}" 2>/dev/null || true
}


print_dashboard_access() {
  echo
  log "=========================================================================="
  log "Kubernetes Dashboard installé. Pour y accéder depuis ce nœud :"
  log "  1) kubectl proxy"
  log "  2) Ouvrir dans un navigateur :"
  log "     http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
  log "  3) Se connecter avec le jeton (token) sauvegardé dans ${DASHBOARD_TOKEN_FILE}"
  log "     (ou régénérer : kubectl -n kubernetes-dashboard create token admin-user)"
  log "=========================================================================="
}


single_node() {
  init_master "${1:-}"

  export KUBECONFIG=/etc/kubernetes/admin.conf
  log "Retrait du taint control-plane pour autoriser les pods sur ce nœud unique..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || \
    log "(taint déjà absent, rien à faire)"

  echo
  log "=========================================================================="
  log "Cluster single-node prêt !"
  kubectl get nodes
  log "Pour tester : kubectl create deployment nginx-test --image=nginx"
  log "              kubectl expose deployment nginx-test --port=80 --type=NodePort"
  log "=========================================================================="
}


join_worker() {
  local join_cmd="${1:-}"

  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "Ce nœud semble déjà avoir rejoint un cluster (/etc/kubernetes/kubelet.conf existe). Rien à faire."
    return
  fi

  if [[ -z "$join_cmd" ]]; then
    log "Préparation système terminée. Aucune commande 'kubeadm join' fournie."
    log "Récupérez-la sur le master (fichier ${JOIN_FILE} ou 'kubeadm token create --print-join-command')"
    log "puis relancez : sudo $0 worker \"<commande kubeadm join complète>\""
    return
  fi

  log "Exécution de la commande de jonction fournie..."
  eval "$join_cmd"
  log "Le nœud a rejoint le cluster. Vérifiez depuis le master avec : kubectl get nodes"
}


case "$ACTION" in
  single)
    prep_system
    single_node "${2:-}"
    ;;
  prep)
    prep_system
    ;;
  master)
    prep_system
    init_master "${2:-}"
    ;;
  worker)
    prep_system
    join_worker "${2:-}"
    ;;
  *)
    die "Action inconnue : '$ACTION'. Usage : $0 {single|prep|master|worker} [argument optionnel]"
    ;;
esac