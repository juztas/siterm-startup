#!/bin/bash

function askYesNo () {
  retVal=-1
  while true; do
    read -p "$1" yn
    case $yn in
      [Yy]es ) retVal=0; break;;
      [Nn]o ) retVal=1; break;;
      * ) echo "Please answer [Yy]es or [Nn]o.";;
    esac
  done
  return $retVal
}

function certChecker() {
  echo "Certificate information:"
  openssl x509 -in $1 -noout -subject -issuer -startdate -enddate
  exitCode=$?
  if [ "$exitCode" -ne "0" ]; then
    echo "There was exception getting certificate information. Exiting"
    return 1
  fi
  certmod=`openssl x509 -in $1 -noout -modulus`
  keymod=`openssl rsa -in $2 -noout -modulus`
  if [ "$certmod" != "$keymod" ]; then
    echo "Certificate and key modulus are not equal. Is it same cert/key match? Exiting"
    return 1
  fi
  return 0
}

# ENVIRONMENT
REWRITE_CONFIG_MAP=0
REWRITE_SECRETS=0


# TODO:
# 3. Config files can load and MariaDB password was changed.

echo "Which kube config to use? Provide full path, like /home/username/.kube/config"
read KUBECONF
# Remove quotes - kubectl is unhappy with remaining quotes if not full path provided
if [ -f $KUBECONF ]; then
  echo "KubeConfig $KUBECONF file is present. Continue..."
else
  echo "KubeConfig $KUBECONF file does not exist. Exiting..."
  exit 1
fi

echo "Which Hostname we are deploying? Please enter full qualified domain name:"
read fqdn

echo "Which namespace on Kubernetes to use to deploy service?"
read namespace

configfile=default_configs/sitefe-k8s.yaml

result=0
if [ -f "deployed_configs/sitefe-k8s.yaml-$fqdn" ]; then
  askYesNo "Kubernetes config file is already present. Do you want to continue (Any manual changes in yaml file will be overwritten)? [Yy]es or [Nn]o:  "
  result=$?
fi
if [ "$result" -ne "0" ]; then
  echo "Exiting..."
  exit $result
fi


# Precheck that such node exists. Needed for
count=`kubectl get nodes --kubeconfig $KUBECONF | grep $fqdn | wc -l`
if [ "$count" -ne "1" ]; then
  echo "Hostname $fqdn does not exists in kubernetes nodes list. (Maybe private name?)"
  echo "Here is full list of kubernetes nodes:"
  kubectl get nodes --kubeconfig $KUBECONF
  echo "On which one you want to deploy service? Needed for nodeSelector: kubernetes.io/hostname parameter. Please enter NAME:"
  read nodeselector
else
  nodeselector=$fqdn
fi


# Some fields in yaml require listing without '.' - so we replace it to  '-'
fqdnnodots=$( echo ${fqdn:1} | tr '.' '-' )

echo "============================================================"
echo "  HOSTCERT and HOSTKEY CHECK/INSTALL"
echo "============================================================"

result=0
# Move config, hostcert, key - to name with hostname
if [ -f "../conf/etc/grid-security/hostcert.pem-$fqdn" ] || [ -f "../conf/etc/grid-security/hostkey.pem-$fqdn" ]; then
  askYesNo "HostCert and HostKey is already present for $fqdn. Do you want to overwrite them with ../conf/etc/grid-security/host{cert,key}.pem? [Yy]es or [Nn]o:  "
  result=$?
fi
if [ "$result" -eq "0" ]; then
  echo "Certificate Overwrite Requested."
  certChecker ../conf/etc/grid-security/hostcert.pem ../conf/etc/grid-security/hostkey.pem
  certExit=$?
  if [ "$certExit" -ne "0" ]; then
    exit $certExit
  fi
  cp ../conf/etc/grid-security/hostcert.pem ../conf/etc/grid-security/hostcert.pem-$fqdn
  cp ../conf/etc/grid-security/hostkey.pem ../conf/etc/grid-security/hostkey.pem-$fqdn
  REWRITE_SECRETS=1
else
  echo "NO Certificate Overwrite. Checking that Certs are valid"
  certChecker ../conf/etc/grid-security/hostcert.pem-$fqdn ../conf/etc/grid-security/hostkey.pem-$fqdn
  certExit=$?
  if [ "$certExit" -ne "0" ]; then
    exit $certExit
  fi
fi

echo "============================================================"
echo "  HTTPD CERT/KEY/CHAIN CHECK/INSTALL"
echo "============================================================"


result=0
# Move config, hostcert, key - to name with hostname
if [ -f "../conf/etc/httpd/certs/cert.pem-$fqdn" ] || [ -f "../conf/etc/httpd/certs/privkey.pem-$fqdn" ] || [ -f "../conf/etc/httpd/certs/fullchain.pem-$fqdn" ]; then
  askYesNo "HTTPD CERT/KEY/CHAIN is already present for $fqdn. Do you want to overwrite them with ../conf/etc/httpd/certs/{cert,privkey,fullchain}.pem? [Yy]es or [Nn]o:  "
  result=$?
fi
if [ "$result" -eq "0" ]; then
  echo "Certificate Overwrite Requested."
  certChecker ../conf/etc/httpd/certs/cert.pem ../conf/etc/httpd/certs/privkey.pem
  certExit=$?
  if [ "$certExit" -ne "0" ]; then
    exit $certExit
  fi
  cp ../conf/etc/httpd/certs/cert.pem ../conf/etc/httpd/certs/cert.pem-$fqdn
  cp ../conf/etc/httpd/certs/privkey.pem ../conf/etc/httpd/certs/privkey.pem-$fqdn
  cp ../conf/etc/httpd/certs/fullchain.pem ../conf/etc/httpd/certs/fullchain.pem-$fqdn
  cp ../conf/environment ../conf/environment-$fqdn
  REWRITE_SECRETS=1
else
  echo "NO Certificate Overwrite. Checking that Certs are valid"
  certChecker ../conf/etc/httpd/certs/cert.pem-$fqdn ../conf/etc/httpd/certs/privkey.pem-$fqdn
  certExit=$?
  if [ "$certExit" -ne "0" ]; then
    exit $certExit
  fi
fi

echo "============================================================"
echo "  CONFIG FILE CHECK"
echo "============================================================"


result=0
if [ -f "../conf/etc/siterm.yaml-$fqdn" ]; then
  askYesNo "Config file is present for $fqdn. Do you want to overwrite it? [Yy]es or [Nn]o:  "
  result=$?
fi
if [ "$result" -eq 0 ]; then
  echo "Config Overwrite Requested."
  cp ../conf/etc/siterm.yaml ../conf/etc/siterm.yaml-$fqdn
  REWRITE_CONFIG_MAP=1
fi

echo "============================================================"
echo "  CREATE and CONFIGURE Kubernetes yaml file"
echo "============================================================"

cp $configfile sitefe-k8s.yaml-$fqdn
sed -i ".backup" "s|___REPLACEME___|$fqdn|g" sitefe-k8s.yaml-$fqdn
sed -i ".backup" "s|___REPLACEMENODESELECTOR___|$nodeselector|g" sitefe-k8s.yaml-$fqdn
sed -i ".backup" "s|___REPLACEMENODOTS___|$fqdnnodots|g" sitefe-k8s.yaml-$fqdn
sed -i ".backup" "s|___REPLACEMENAMESPACE___|$namespace|g" sitefe-k8s.yaml-$fqdn
rm -f sitefe-k8s.yaml-$fqdn.backup
mv sitefe-k8s.yaml-$fqdn deployed_configs/

echo "============================================================"
echo "  Check if config map/secrets are present in kubernetes"
echo "============================================================"
echo "Check config map"
kubectl get configmap sense-fe-$fqdn --namespace $namespace --kubeconfig $KUBECONF
CONFIG_MAP_PRESENT=$?
echo '------------------------------------------------------------'
if [ "$CONFIG_MAP_PRESENT" -eq 0 ] && [ "$REWRITE_CONFIG_MAP" -eq 1 ]; then
  echo "Config map is present and new config was produced. Deleting old config"
  kubectl delete configmap sense-fe-$fqdn --namespace $namespace --kubeconfig $KUBECONF
fi
if [ "$REWRITE_CONFIG_MAP" -eq 1 ] || [ "$CONFIG_MAP_PRESENT" -eq 1 ]; then
  echo "Creating new config map for $fqdn"
  kubectl create configmap sense-fe-$fqdn --from-file=sense-siterm-fe=../conf/etc/siterm.yaml-$fqdn \
                                          --namespace $namespace --kubeconfig $KUBECONF
fi

echo '------------------------------------------------------------'
echo 'Check secrets'
kubectl get secret sense-fe-$fqdn --namespace $namespace --kubeconfig $KUBECONF
SECRETS_PRESENT=$?
echo '------------------------------------------------------------'

if [ "$SECRETS_PRESENT" -eq 0 ] && [ "$REWRITE_SECRETS" -eq 1 ]; then
  echo "Secrets are present and new secrets were produced. Deleting old secrets"
  kubectl delete secret sense-fe-$fqdn --namespace $namespace --kubeconfig $KUBECONF
fi
if [ "$REWRITE_SECRETS" -eq 1 ] || [ "$SECRETS_PRESENT" -eq 1 ]; then
  echo "Creating new secrets for $fqdn"
  kubectl create secret generic sense-fe-$fqdn \
          --from-file=fe-hostcert=../conf/etc/grid-security/hostcert.pem-$fqdn \
          --from-file=fe-hostkey=../conf/etc/grid-security/hostkey.pem-$fqdn \
          --from-file=fe-httpdcert=../conf/etc/httpd/certs/cert.pem-$fqdn \
          --from-file=fe-httpdprivkey=../conf/etc/httpd/certs/privkey.pem-$fqdn \
          --from-file=fe-httpdfullchain=../conf/etc/httpd/certs/fullchain.pem-$fqdn \
          --from-file=fe-environment=../conf/environment-$fqdn \
          --from-file=ansible-conf=../conf/etc/ansible-conf.yaml \
          --namespace $namespace --kubeconfig $KUBECONF
fi

echo "============================================================"
echo "============================================================"
echo " HERE IS KUBERNETES CONFIG FILE"
cat deployed_configs/sitefe-k8s.yaml-$fqdn

echo "------------------------------------------------------------"
echo "See Kubernetes config above. If you need to make any manual changes,"
echo "like add tolerations, do not submit and modify this config file:"
echo "deployed_configs/sitefe-k8s.yaml-$fqdn"
echo "and submit manually using this command:"
echo kubectl apply -f deployed_configs/sitefe-k8s.yaml-$fqdn --namespace $namespace --kubeconfig $KUBECONF
askYesNo "Do you want submit config right now? [Yy]es or [Nn]o:  "
result=$?
if [ "$result" -eq "0" ]; then
  echo "Apply config..."
  echo kubectl apply -f deployed_configs/sitefe-k8s.yaml-$fqdn --namespace $namespace --kubeconfig $KUBECONF
else
  echo "Not applying configuration..."
fi
