#!/usr/bin/env bash

#
# This script is intended to be run on Ubuntu 20.04 (Focal). It *may* run on other Debian/Ubuntu variants, but it
# will definitely not run on Red Hat variants. It will definitely not run on Darwin. Plan9? Right out. Just stick
# to Ubuntu and you should be good.
#

set -o errexit  # abort on nonzero exit status
set -o nounset  # abort on unbound variable
set -o pipefail # don't hide errors within pipes

# Don't pollute console output with upgrade notifications
export PULUMI_SKIP_UPDATE_CHECK=true

# Run Pulumi non-interactively
export PULUMI_SKIP_CONFIRMATIONS=true

update_os() {
    sudo apt update
    DEBIAN_FRONTEND=noninteractive sudo apt -y upgrade
    PYVER=$(curl -s https://gitcdn.link/cdn/nginxinc/kic-reference-architectures/master/.python-version)
    DEBIAN_FRONTEND=noninteractive sudo apt -y install make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev docker.io firefox
}

install_python() {
  if [ -d ~/.asdf ] ; then
    echo "Existing asdf directory found, will not clone"
  else
    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.10.0
  fi
  "${HOME}"/.asdf/bin/asdf plugin add python || true
  "${HOME}"/.asdf/bin/asdf install python "${PYVER}" || true
   PATH="${HOME}"/.asdf/bin:"${PATH}"
   source "${HOME}"/.asdf/asdf.sh
  "${HOME}"/.asdf/bin/asdf global python "${PYVER}"
  "${HOME}"/.asdf/bin/asdf shell python "${PYVER}"
  "${HOME}"/.asdf/bin/asdf reshim
}

install_k3s() {
    mkdir "${HOME}"/.kube || true
    curl -sfL https://get.k3s.io |  INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh -
    k3s kubectl config view --flatten > "${HOME}"/.kube/config
}

clone_repo() {
  if [ -d ~/kic-reference-architectures ] ; then
    echo "Existing source directory found; will not clone"
  else
    cd "${HOME}" && git clone --recurse-submodules https://github.com/nginxinc/kic-reference-architectures
  fi
}

setup_venv() {
    # Run our setup script
    "${PROJECT_ROOT}"/bin/setup_venv.sh
}

configure_pulumi() {

    # Generate a random number for our pulumi stack...we use the built in bash RANDOM variable, 
    # but if you want you can change it
    BUILD_NUMBER="${RANDOM}"
    echo "PULUMI_STACK=marajenk${BUILD_NUMBER}" > "${PROJECT_ROOT}"/config/pulumi/environment

    # Build the stacks...
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi stack select --create marajenk${BUILD_NUMBER} -C "${PROJECT_ROOT}"/pulumi/python/config
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi stack select --create marajenk${BUILD_NUMBER} -C "${PROJECT_ROOT}"/pulumi/python/kubernetes/applications/sirius

    # Set our helm values 
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set certmgr:helm_timeout "600" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kic-helm:fqdn "marajenks${BUILD_NUMBER}.zathras.io" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kic-helm:helm_timeout "600" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:cluster_name "microk8s-cluster" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:infra_type "kubeconfig" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:kubeconfig "$HOME/.kube/config" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set logagent:helm_timeout "600" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set logstore:helm_timeout "600" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set prometheus:adminpass "password" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set prometheus:helm_timeout "600" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set prometheus:helm_timeout "600" -C "${PROJECT_ROOT}"/pulumi/python/config -s marajenk${BUILD_NUMBER}

}

build_mara() {
    "${PROJECT_ROOT}"/bin/start_kube.sh
}

cleanup() {
    # Call the destroy script to remove our MARA
    PATH="${PROJECT_ROOT}"/pulumi/python/venv/bin:$PATH "${PROJECT_ROOT}"/bin/destroy.sh

    # Stop all K3s servces
    /usr/local/bin/k3s-killall.sh || true

    # Uninstall K3s
    /usr/local/bin/k3s-uninstall.sh || true

    # Get the stack name....
    STACK_NAME=$(cat "${PROJECT_ROOT}"/config/pulumi/environment  | awk -F= '{print $2}' )

    # Remove the Pulumi Stack
    find . -mindepth 2 -maxdepth 6 -type f -name Pulumi.yaml -execdir pulumi stack rm "${STACK_NAME}" --force --yes \\;
}

tool_install() {
  # Install K9s; again, piping to curl is not a good idea so this should be refactored at some point...
  curl -sS https://webinstall.dev/k9s | bash
  # Install Kompose
  curl -L https://github.com/kubernetes/kompose/releases/download/v1.26.1/kompose-linux-amd64 -o kompose
  chmod +x kompose
  sudo mv ./kompose /usr/local/bin/kompose
}

install_dns() {
  # First disable the system resolver...
  sudo systemctl disable systemd-resolved
  sudo systemctl stop systemd-resolved
  sudo unlink /etc/resolv.conf

  # Add in a default...we'll use google
  echo nameserver 8.8.8.8 | sudo tee /etc/resolv.conf

  # Install dnsmasq
  sudo apt -y install dnsmasq

  # What is our address?
  IP_ADDR=$(ip -j  -4 addr show ens5| jq ".[].addr_info[].local" | sed 's/"//g')

  # Create config
cat > '/tmp/dnsmaq' <<FileContent
port=53
domain-needed
bogus-priv
strict-order
expand-hosts
domain=example.local
listen-address="${IP_ADDR}"
FileContent

  # Copy config into place....
  sudo cp /tmp/dnsmasq /etc/dnsmas

  # Update hosts file....
  echo "${IP_ADDR}    mara.example.local" | sudo tee /etc/hosts

  # Update the resolv.conf
cat > 'tmp/resolv.conf' <<FileContent
nameserver "${IP_ADDR}"
nameserver 8.8.8.8
search example.local
domain example.local
FileContent

  # Restart dnsmasq
  sudo systemctl restart dnsmasq

  # Test DNS
  dig @127.0.01 mara.example.local

}


help()
{
   # Display Help
   echo "MARA UDF Helper Script"
   echo " "
   echo "This is a simple helper script designed to enable configuration and deployment of the MARA"
   echo "project on F5's UDF environment."
   echo " "
   echo "This project is desgined to be run on a virtual machine that has at least 4 vCPU, 20GB of RAM,"
   echo "and 32GB of disk. This has been tested on Ubuntu 20.04 (Focal), but should work on other Debian"
   echo "flavors."
   echo " "
   echo "For more information on MARA, please navigate to https://nginx.com/mara"
   echo " "
   echo "Syntax: $0 [-d|k|r|h]"
   echo "options:"
   echo "d     Clone repo, deploy MARA, deploy supporting components (os, k3s)"
   echo "k     Update the OS and deploy K3s only (no repo clone)"
   echo "r     Remove MARA and supporting components"
   echo "h     This help screen"
   echo
}

# Set it all to false...
DEPLOY="FALSE"
DEPLOY_K3S="FALSE"
UNDEPLOY="FALSE"

#
# Manage the options...
#
while getopts ":hdkr" option; do
   case $option in
      h) # display Help
         help
         exit;;
      d) # Deploy
         DEPLOY="TRUE"
         break;;
      k) # Just K3s
         DEPLOY_K3S="TRUE"
         break;;
      r) # Remove 
         UNDEPLOY="TRUE"
         break;;
     \?) # Invalid option
         echo "Error: Invalid option"
         exit;;
   esac
done


# Mainline

# Is there a PULUMI environment variable set?
if [ -x "${PULUMI_ACCESS_TOKEN+x}" ] ; then
    echo "No Pulumi access token in the PULUMI_ACCESS_TOKEN env variable"
    echo "If you have no already logged into Pulumi on this system you"
    echo "will be prompted to when the MARA setup runs."
    echo " "
    echo "To avoid being prompted you can do one of two things:"
    echo "1. Set the PULUMI_ACCESS_TOKEN variable in your environment."
    echo "2. Log into Pulumi on this system (you will see this message again, but can ignore it)."
    echo " "
fi

# Other required variables
PROJECT_ROOT=$HOME/kic-reference-architectures
FULL_START_TIME=$(date +%s.%N)

# Deploy everything...
if [ "${DEPLOY}" = "TRUE" ]; then 
    START_TIME=$(date +%s.%N)
    update_os
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function update_os() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_python
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function install_python() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_k3s
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function install_k3s() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    clone_repo
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function clone_repo() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    setup_venv
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function setup_venv() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    configure_pulumi
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function configure_pulumi() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    build_mara
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function build_mara() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    tool_install
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function tool_install() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_dns
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function install_dns() Elapsed Time: $EXECUTION_TIME <<<<<============="

elif [ "${DEPLOY_K3S}" = "TRUE" ]; then
    START_TIME=$(date +%s.%N)
    update_os
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function update_os() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_k3s
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function install_k3s() Elapsed Time: $EXECUTION_TIME <<<<<============="

elif [ "${UNDEPLOY}" = "TRUE" ]; then
    START_TIME=$(date +%s.%N)
    cleanup
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
    echo "=============>>>>> Function cleanup() Elapsed Time: $EXECUTION_TIME <<<<<============="

else
    echo "Nothing to do! Please select an option!"
    echo " "
    help
fi

# Overall run time is....
DURATION=$(echo "$(date +%s.%N) - ${FULL_START_TIME}" | bc)
EXECUTION_TIME=`printf "%.2f seconds" $DURATION`
echo "=============>>>>> Script Elapsed Time: $EXECUTION_TIME <<<<<=============" 

