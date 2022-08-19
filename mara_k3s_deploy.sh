#!/usr/bin/env bash

#####################################################################################################################
# This script is intended to be run on Ubuntu 20.04 (Focal). It *may* run on other Debian/Ubuntu variants, but it
# will definitely not run on Red Hat variants. It will definitely not run on Darwin. Plan9? Right out. Just stick
# to Ubuntu and you should be good.
#####################################################################################################################

set -o errexit  # abort on nonzero exit status
set -o nounset  # abort on unbound variable
set -o pipefail # don't hide errors within pipes

# Don't pollute console output with upgrade notifications
export PULUMI_SKIP_UPDATE_CHECK=true

# Run Pulumi non-interactively
export PULUMI_SKIP_CONFIRMATIONS=true

#####################################################################################################################
# Installs required packages to the system; add any you need here. The "noninteractive" is important so we don't
# find ourselves stuck waiting for config / confirmation / etc
#####################################################################################################################
update_os() {
    sudo apt update
    DEBIAN_FRONTEND=noninteractive sudo apt -y upgrade
    PYVER=$(curl -s https://gitcdn.link/cdn/nginxinc/kic-reference-architectures/master/.python-version)
    DEBIAN_FRONTEND=noninteractive sudo apt -y install make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev docker.io firefox jq
}

#####################################################################################################################
# We use the ASDF package manager in order to install a specific version of Python
#####################################################################################################################
install_python() {
  if [ -d ~/.asdf ] ; then
    echo "Existing asdf directory found, will not clone"
  else
    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.10.0
  fi
  "${HOME}"/.asdf/bin/asdf plugin add python || true
  "${HOME}"/.asdf/bin/asdf install python "${PYVER}" || true
   PATH="${HOME}"/.asdf/bin:"${PATH}"
  "${HOME}"/.asdf/bin/asdf global python "${PYVER}"
  "${HOME}"/.asdf/bin/asdf reshim
}

#####################################################################################################################
# Install K3S; piping curl to bash is generally frowned upon, but this script is intended only to ever be run in
# a throwaway VM. If desired, this repo can be forked and pinned to a specific version of the script to alleviate
# any security concerns.
#
# The options are key - the first one disables the standard traefik IC, and the second ensures that our user
# (who is assumed to not be root) can read it.
#####################################################################################################################
install_k3s() {
    mkdir "${HOME}"/.kube || true
    curl -sfL https://get.k3s.io |  INSTALL_K3S_VERSION="v1.23.9+k3s1" INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh -
    k3s kubectl config view --flatten > "${HOME}"/.kube/config
}

#####################################################################################################################
# Clone the repo and init the submodule
#####################################################################################################################
clone_repo() {
  if [ -d ~/kic-reference-architectures ] ; then
    echo "Existing source directory found; will not clone"
  else
    cd "${HOME}" && git clone --recurse-submodules https://github.com/nginxinc/kic-reference-architectures
  fi

  #
  # After we clone, check to see if we need to move a JWT into place.
  #
  if [ -f "${HOME}"/jwt ] ; then
    cp "${HOME}"/jwt "${HOME}"/kic-reference-architectures/extras/jwt.token
    echo "Copied JWT into place"
  fi
}

#####################################################################################################################
# Create our virtual environment in order to install required packages and utilities that have been tested to work
# with this version of MARA.
#####################################################################################################################
setup_venv() {
    # Run our setup script
    "${PROJECT_ROOT}"/bin/setup_venv.sh
}

#####################################################################################################################
# This step performs configuration of the Pulumi stack; any changes you want to make to the configuration should be
# done here (rather than editing the configuration files manually).
#
# Note that you will need to use full paths to all of the files and binaries you are using; nothing is guaranteed
# to be in your path.
#####################################################################################################################
configure_pulumi() {
    # Generate a random number for our pulumi stack...we use the built in bash RANDOM variable,
    # but if you want you can change it
    BUILD_NUMBER="${RANDOM}"

    # Generate a random password for the values we need to set and print it out.
    MARA_PASSWORD=$(pwgen 16 1)
    echo $MARA_PASSWORD > "${PROJECT_ROOT}"/.mara_password

    # 
    echo "PULUMI_STACK=maraudf${BUILD_NUMBER}" > "${PROJECT_ROOT}"/config/pulumi/environment

    # Build the stacks...
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi stack select --create maraudf${BUILD_NUMBER} -C pulumi/python/config
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi stack select --create maraudf${BUILD_NUMBER} -C pulumi/python/kubernetes/secrets

    # Set the helm values
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set certmgr:helm_timeout "600" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kic-helm:helm_timeout "600" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:kubeconfig "$HOME/.kube/config" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set logagent:helm_timeout "600" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set logstore:helm_timeout "600" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set prometheus:helm_timeout "600" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kic-helm:fqdn "maraudf${BUILD_NUMBER}.zathras.io" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:cluster_name "default" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:infra_type "kubeconfig" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set kubernetes:kubeconfig "$HOME/.kube/config" -C pulumi/python/config -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set prometheus:adminpass "${MARA_PASSWORD}" --secret -C pulumi/python/kubernetes/secrets -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set sirius:accounts_pwd "${MARA_PASSWORD}" --secret -C pulumi/python/kubernetes/secrets -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set sirius:demo_login_pwd "password" --secret -C pulumi/python/kubernetes/secrets -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set sirius:demo_login_user "testuser" --secret -C pulumi/python/kubernetes/secrets -s maraudf${BUILD_NUMBER}
    "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi config set sirius:ledger_pwd "${MARA_PASSWORD}" --secret -C pulumi/python/kubernetes/secrets -s maraudf${BUILD_NUMBER}


}

#####################################################################################################################
# This is the MARA deployment; note that we use the "start_kube.sh" script as opposed to the "start.sh" script; this
# is done in order to bypass the interactive warnings and prompts. Values are instead set in the function above
# named "configure_pulumi()".
#####################################################################################################################
build_mara() {
    "${PROJECT_ROOT}"/bin/start_kube.sh
}

#####################################################################################################################
# Clean up our deployment and environment. This script will remove the deployment of MARA along with the K3s
# installation.
#
# Note that you may need to purge the "kic-reference-architectures" repository directory if you run into issues when
# trying to re-run the process. Every effort has been taken to make this process idempotent, but....sometimes the
# process needs a kick.
#####################################################################################################################
cleanup() {
    # Call the destroy script to remove our MARA
    PATH="${PROJECT_ROOT}"/pulumi/python/venv/bin:$PATH "${PROJECT_ROOT}"/bin/destroy.sh || true

    # Stop all K3s servces
    /usr/local/bin/k3s-killall.sh || true

    # Uninstall K3s
    /usr/local/bin/k3s-uninstall.sh || true

    # Get the stack name....
    STACK_NAME=$(cat "${PROJECT_ROOT}"/config/pulumi/environment | grep PULUMI_STACK | awk -F= '{print $2}' )

    # Remove the Pulumi Stack
    find "${PROJECT_ROOT}" -mindepth 2 -maxdepth 6 -type f -name Pulumi.yaml -execdir "${PROJECT_ROOT}"/pulumi/python/venv/bin/pulumi stack rm "${STACK_NAME}" --force --yes \;
}

#####################################################################################################################
# This step installs some 3rd party tools that prove useful; please feel free to add tools that you want to be
# present in your environment.
#
# Note: you will need to make sure that this function returns 0; any non-zero RC will cause the process to abort.
# If you need assistance with this, please see the use of "|| true" in some of the areas above.
#####################################################################################################################
tool_install() {
  # Install K9s; again, piping to curl is not a good idea so this should be refactored at some point...
  curl -sS https://webinstall.dev/k9s | bash
  # Install Kompose
  curl -L https://github.com/kubernetes/kompose/releases/download/v1.26.1/kompose-linux-amd64 -o kompose
  chmod +x kompose
  sudo mv ./kompose /usr/local/bin/kompose
}

#####################################################################################################################
# This demo is designed to use "mara.test" as the FQDN of the deployment, and in order to make sure that we can
# resolve our FQDN appropriately we install and configure the "dnsmasq" service.
#
# It is important to be careful when editing this; the FQDN needs to be resolvable within the BoS loadgenerator
# pod. This is handled by adjusting the "resolv.conf" on the host to point to the external IP address of the
# host as the main resolver. This information is then passed into the coredns module and used as a forward.
#
# If this is broken, it will most likely cause the loadgenerator to not work properly.
#####################################################################################################################
install_dns() {
  #
  # Install dnsmasq - we do this before we start mucking about with the resolvers...
  #
  sudo apt -y install dnsmasq pwgen

  # First disable the system resolver...
  sudo systemctl disable systemd-resolved
  sudo systemctl stop systemd-resolved
  sudo unlink /etc/resolv.conf

  #
  # What is our address?
  #
  IP_ADDR=$(ip -j  route show to 0.0.0.0/0  | jq ".[].prefsrc" | sed 's/"//g')

  #
  # Create config
  #
cat > '/tmp/dnsmasq' <<FileContent
port=53
domain-needed
bogus-priv
strict-order
expand-hosts
domain=test
listen-address="${IP_ADDR}"
FileContent

  #
  # Copy config into place....
  #
  sudo cp /tmp/dnsmasq /etc/dnsmasq

  #
  # Update hosts file....
  #
  echo "${IP_ADDR}    mara.test  ${HOSTNAME}" | sudo tee -a /etc/hosts

  #
  # Update the resolv.conf using a heredoc; justification is important so don't muck with it.
  # It is also important that we put the localhost first on it's external address rather than
  # the localhost/127.0.0.1 address. This is because the coredns deployment will use this
  # as it's upstream resolver, which enables us to resolve mara.test
  #
cat > '/tmp/resolv.conf' <<FileContent
nameserver ${IP_ADDR}
nameserver 8.8.8.8
search test
domain test
FileContent

  #
  # Copy config into place....
  #
  sudo cp /tmp/resolv.conf /etc/resolv.conf

  #
  # Restart dnsmasq
  #
  sudo systemctl restart dnsmasq

  # Test DNS
  dig @${IP_ADDR} mara.test

}

#####################################################################################################################
# Configure coredns to use the host system's nameserver (dnsmasq); note that this function creates a configmap
# that works with the current version of coredns. There is a good chance that this may break on future upgrades.
#
# To be fair, there are likely more sustainable ways to do this....but this works for now, and pull requests
# are welcome...
#####################################################################################################################
coredns_config()
{

#
# We are going to use the IP address of our host...
#
IP_ADDR=$(ip -j  route show to 0.0.0.0/0  | jq ".[].prefsrc" | sed 's/"//g')

#
# We build our configuration file; this logic says that for every query for the "test" domain we should use
# IP_ADDR to point to our resolver. This will allow the locust loadgenerator to hit the NGINX IC.
#
cat > '/tmp/coredns.yaml' <<FileContent
apiVersion: v1
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        hosts /etc/coredns/NodeHosts {
          ttl 60
          reload 15s
          fallthrough
        }
        prometheus :9153
        forward test ${IP_ADDR}
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
    import /etc/coredns/custom/*.server
  NodeHosts: |
    10.1.1.4 ubuntu
kind: ConfigMap
metadata:
  annotations:
  name: coredns
  namespace: kube-system
FileContent

  #
  # Now we apply the configuration to coredns...
  #
  "${PROJECT_ROOT}"/pulumi/python/venv/bin/kubectl apply -f /tmp/coredns.yaml

  #
  # And now we check the output...
  "${PROJECT_ROOT}"/pulumi/python/venv/bin/kubectl describe configmap --namespace kube-system coredns

}

#####################################################################################################################
# Show help information
#####################################################################################################################
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
   echo "k     Update the OS and deploy K3s and tools only (no MARA clone or deploy)"
   echo "r     Remove MARA and supporting components"
   echo "h     This help screen"
   echo
}

# Set it all to false...
DEPLOY="FALSE"
DEPLOY_K3S="FALSE"
UNDEPLOY="FALSE"


#####################################################################################################################
# Script mainline
#####################################################################################################################
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



#
# Is there a PULUMI environment variable set?
#
if [ -x "${PULUMI_ACCESS_TOKEN+x}" ] ; then
    echo "No Pulumi access token in the PULUMI_ACCESS_TOKEN env variable"
    echo "If you have no already logged into Pulumi on this system you"
    echo "will be prompted to when the MARA setup runs."
    echo " "
    echo "To avoid being prompted you can do one of two things:"
    echo "1. Set the PULUMI_ACCESS_TOKEN variable in your environment."
    echo "2. Log into Pulumi on this system (you will see this message again, but can ignore it)."
    echo " "
    sleep 5
fi



# Other required variables
PROJECT_ROOT=$HOME/kic-reference-architectures
FULL_START_TIME=$(date +%s.%N)

# Deploy everything...
if [ "${DEPLOY}" = "TRUE" ]; then

    #
    # Is there a JWT set? We only care on a full deploy.
    #
    if [ -f "$HOME/jwt" ] ; then
        echo "Found JWT for NGINX Plus; will copy into appropriate directory"
    else
        echo "No JWT found; the deployment will be configured to deploy the NGINX OSS IC"
        echo " "
        echo "If you were intending to deploy NGINX Plus, please hit ctrl-c now and put a valid JWT for the NGINX Plus"
        echo "Ingress Controller into the file $HOME/jwt."
        echo " "
        echo "The script will pause for 5 seconds now."
        sleep 5
    fi

    START_TIME=$(date +%s.%N)
    update_os
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function update_os() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_python
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function install_python() Elapsed Time: $EXECUTION_TIME <<<<<============="

    # Source the asdf config...
    source "${HOME}"/.asdf/asdf.sh

    #
    # We need DNS before we deploy K3s, otherwise we get the wrong resolvers inside CoreDNS
    #
    START_TIME=$(date +%s.%N)
    install_dns
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function install_dns() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_k3s
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function install_k3s() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    clone_repo
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function clone_repo() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    setup_venv
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function setup_venv() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    configure_pulumi
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function configure_pulumi() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    build_mara
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function build_mara() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    tool_install
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function tool_install() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    coredns_config
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function coredns_config() Elapsed Time: $EXECUTION_TIME <<<<<============="

elif [ "${DEPLOY_K3S}" = "TRUE" ]; then
    START_TIME=$(date +%s.%N)
    update_os
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function update_os() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    install_k3s
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function install_k3s() Elapsed Time: $EXECUTION_TIME <<<<<============="

    START_TIME=$(date +%s.%N)
    tool_install
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function tool_install() Elapsed Time: $EXECUTION_TIME <<<<<============="

elif [ "${UNDEPLOY}" = "TRUE" ]; then
    START_TIME=$(date +%s.%N)
    cleanup
    DURATION=$(echo "$(date +%s.%N) - ${START_TIME}" | bc)
    EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
    echo "=============>>>>> Function cleanup() Elapsed Time: $EXECUTION_TIME <<<<<============="

else
    echo "Nothing to do! Please select an option!"
    echo " "
    help
fi

# Overall run time is....
DURATION=$(echo "$(date +%s.%N) - ${FULL_START_TIME}" | bc)
EXECUTION_TIME=$(printf "%.2f seconds" "${DURATION}")
echo "=============>>>>> Script Elapsed Time: $EXECUTION_TIME <<<<<=============" 
