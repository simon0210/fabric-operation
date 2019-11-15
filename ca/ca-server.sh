#!/bin/bash
# start fabric-ca server and client for a specified org,
#   with optional target env, i.e., docker, k8s, aws, az, gke, etc, to provide extra SVC_DOMAIN config
# usage: start-ca.sh <org_name> <env>
# where config parameters for the org are specified in ../config/org_name.env, e.g.
#   start-ca.sh netop1
# use config parameters specified in ../config/netop1.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; echo "$(pwd)")"

# printServerService ca|tlsca
function printServerService {
  CA_NAME=${1}
  if [ "${CA_NAME}" == "tlsca" ]; then
    PORT=${TLS_PORT}
    ADMIN=${TLS_ADMIN:-"tlsadmin"}
    PASSWD=${TLS_PASSWD:-"tlsadminpw"}
  else
    PORT=${CA_PORT}
    ADMIN=${CA_ADMIN:-"caadmin"}
    PASSWD=${CA_PASSWD:-"caadminpw"}
  fi

  CN_NAME="${CA_NAME}.${FABRIC_ORG}"
  setServerConfig ${CA_NAME}

  echo "
  ${CN_NAME}:
    image: hyperledger/fabric-ca
    container_name: ${CN_NAME}
    ports:
    - ${PORT}:7054
    environment:
    - FABRIC_CA_HOME=/etc/hyperledger/fabric-ca-server
    - FABRIC_CA_SERVER_PORT=7054
    - FABRIC_CA_SERVER_TLS_ENABLED=true
    - FABRIC_CA_SERVER_CSR_CN=${CN_NAME}
    - FABRIC_CA_SERVER_CSR_HOSTS=${CN_NAME},localhost
    volumes:
    - ${ORG_DIR}/${CA_NAME}-server:/etc/hyperledger/fabric-ca-server
    command: sh -c 'fabric-ca-server start -b ${ADMIN}:${PASSWD}'
    networks:
    - ${ORG}"
}

# printClientService - print docker yaml for ca client
function printClientService {
  CLIENT_NAME="caclient.${FABRIC_ORG}"
  ${sumd} -p "${ORG_DIR}/ca-client"

  echo "
  ${CLIENT_NAME}:
    image: hyperledger/fabric-ca
    container_name: ${CLIENT_NAME}
    environment:
    - SVC_DOMAIN=${SVC_DOMAIN}
    - FABRIC_CA_HOME=/etc/hyperledger/fabric-ca-client
    - FABRIC_CA_CLIENT_TLS_CERTFILES=/etc/hyperledger/fabric-ca-client/tls-cert.pem
    volumes:
    - ${ORG_DIR}/ca-client:/etc/hyperledger/fabric-ca-client
    command: bash -c 'while true; do sleep 30; done'
    networks:
    - ${ORG}"
}

function printCADockerYaml {
  echo "version: '3.7'

networks:
  ${ORG}:

services:"
  printServerService ca
  printServerService tlsca
  printClientService
}

# printK8sStorageClass <name>
# storage class for local host, or AWS EFS
function printK8sStorageClass {
  if [ "${K8S_PERSISTENCE}" == "efs" ]; then
    PROVISIONER="efs.csi.aws.com"
  elif [ "${K8S_PERSISTENCE}" == "azf" ]; then
    PROVISIONER="kubernetes.io/azure-file"
  elif [ "${K8S_PERSISTENCE}" == "gfs" ]; then
    # no need to define storage class for Google Filestore
    return 0
  else
    # default to local host
    PROVISIONER="kubernetes.io/no-provisioner"
  fi

  echo "
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: ${1}
provisioner: ${PROVISIONER}
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer"

  if [ "${K8S_PERSISTENCE}" == "azf" ]; then
    echo "parameters:
  skuName: Standard_LRS"
  fi
}

# print local k8s PV and PVC for ca server or client client
function printK8sStorageYaml {
  printK8sStorageClass "ca-data-class"

  printK8sPV "ca-server"
  printK8sPV "tlsca-server"
  printK8sPV "ca-client"
}

# printK8sHostPV ca-server|tlsca-server|ca-client
function printK8sPV {
  PV_NAME=${1}
  echo "---
kind: PersistentVolume
apiVersion: v1
# create PV for ${PV_NAME}
metadata:
  name: ${PV_NAME}-pv
  labels:
    node: ${PV_NAME}
    org: ${ORG}
spec:
  capacity:
    storage: 100Mi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ca-data-class"

  if [ "${K8S_PERSISTENCE}" == "efs" ]; then
    echo "  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${AWS_FSID}
    volumeAttributes:
      path: /${FABRIC_ORG}/canet/${PV_NAME}"
  elif [ "${K8S_PERSISTENCE}" == "azf" ]; then
    echo "  azureFile:
    secretName: azure-secret
    shareName: ${AZ_STORAGE_SHARE}/${FABRIC_ORG}/canet/${PV_NAME}
    readOnly: false
  mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=10000
  - gid=10000
  - mfsymlinks
  - nobrl"
  elif [ "${K8S_PERSISTENCE}" == "gfs" ]; then
    echo "  nfs:
    server: ${GKE_STORE_IP}
    path: /vol1/${FABRIC_ORG}/canet/${PV_NAME}"
  else
    echo "  hostPath:
    path: ${ORG_DIR}/${PV_NAME}
    type: Directory"
  fi

  echo "---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: ${PV_NAME}-pvc
  namespace: ${ORG}
spec:
  storageClassName: ca-data-class
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  selector:
    matchLabels:
      node: ${PV_NAME}
      org: ${ORG}"
}

function printK8sClient {
  ${sumd} -p "${ORG_DIR}/ca-client"

  echo "---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ca-client
  namespace: ${ORG}
  labels:
    app: ca-client
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ca-client
  template:
    metadata:
      labels:
        app: ca-client
    spec:
      containers:
      - name: ca-client
        image: hyperledger/fabric-ca
        env:
        - name: FABRIC_CA_HOME
          value: /etc/hyperledger/fabric-ca-client
        - name: FABRIC_CA_CLIENT_TLS_CERTFILES
          value: /etc/hyperledger/fabric-ca-client/tls-cert.pem
        - name: SVC_DOMAIN
          value: ${SVC_DOMAIN}
        args:
        - bash
        - -c
        - \"while true; do sleep 30; done\"
        workingDir: /etc/hyperledger/fabric-ca-client
        volumeMounts:
        - mountPath: /etc/hyperledger/fabric-ca-client
          name: data
      restartPolicy: Always
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ca-client-pvc"
}

# printK8sServer ca|tlsca
function printK8sServer {
  CA_NAME=${1}
  if [ "${CA_NAME}" == "tlsca" ]; then
    PORT=${TLS_PORT}
    ADMIN=${TLS_ADMIN:-"tlsadmin"}
    PASSWD=${TLS_PASSWD:-"tlsadminpw"}
  else
    PORT=${CA_PORT}
    ADMIN=${CA_ADMIN:-"caadmin"}
    PASSWD=${CA_PASSWD:-"caadminpw"}
  fi
  setServerConfig ${CA_NAME}

  echo "---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CA_NAME}-server
  namespace: ${ORG}
  labels:
    app: ${CA_NAME}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ${CA_NAME}
  template:
    metadata:
      labels:
        app: ${CA_NAME}
    spec:
      containers:
      - name: ${CA_NAME}-server
        image: hyperledger/fabric-ca
        env:
        - name: FABRIC_CA_HOME
          value: /etc/hyperledger/fabric-ca-server
        - name: FABRIC_CA_SERVER_CSR_CN
          value: ${CA_NAME}.${FABRIC_ORG}
        - name: FABRIC_CA_SERVER_CSR_HOSTS
          value: ${CA_NAME}-server.${SVC_DOMAIN},${CA_NAME}.${FABRIC_ORG},localhost
        - name: FABRIC_CA_SERVER_PORT
          value: \"7054\"
        - name: FABRIC_CA_SERVER_TLS_ENABLED
          value: \"true\"
        args:
        - sh
        - -c
        - fabric-ca-server start -b ${ADMIN}:${PASSWD}
        ports:
        - containerPort: 7054
          name: server
        volumeMounts:
        - mountPath: /etc/hyperledger/fabric-ca-server
          name: data
      restartPolicy: Always
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${CA_NAME}-server-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: ${CA_NAME}-server
  namespace: ${ORG}
spec:
  selector:
    app: ${CA_NAME}
  ports:
  - protocol: TCP
    port: ${PORT}
    targetPort: server"
}

# print k8s PODs yaml for CA server and client
# the generated yaml uses org_name as Kubernetes namespace, so multiple orgs can co-exist.
# To avoid re-typing namespace on every kubectl command, set the context to use the namespace by default, e.g.,
# kubectl config view
# kubectl config set-context netop1 --namespace=netop1 --cluster=docker-desktop --user=docker-desktop
# kubectl config use-context netop1
function printK8sCAPods {
  printK8sServer ca
  printK8sServer tlsca
  printK8sClient
}

# setServerConfig ca|tlsca
function setServerConfig {
  CA_NAME=${1}
  SERVER_DIR="${ORG_DIR}/${CA_NAME}-server"
  ${sumd} -p ${SERVER_DIR}
  cp ${SCRIPT_DIR}/fabric-ca-server-config.yaml ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  sed -i -e "s/%%admin%%/${ADMIN}/" ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  sed -i -e "s/%%adminpw%%/${PASSWD}/" ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  sed -i -e "s/%%country%%/${CSR_COUNTRY}/" ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  sed -i -e "s/%%state%%/${CSR_STATE}/" ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  sed -i -e "s/%%city%%/${CSR_CITY}/" ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  sed -i -e "s/%%org%%/${FABRIC_ORG}/" ${SCRIPT_DIR}/fabric-ca-server-config.tmp
  ${sumv} ${SCRIPT_DIR}/fabric-ca-server-config.tmp ${SERVER_DIR}/fabric-ca-server-config.yaml
  rm ${SCRIPT_DIR}/fabric-ca-server-config.tmp*
}

function startDocker {
  # create docker yaml for CA server and client
  mkdir -p "${ORG_DIR}/docker"
  printCADockerYaml > ${ORG_DIR}/docker/docker-compose.yaml

  # start CA server and client
  docker-compose -f ${ORG_DIR}/docker/docker-compose.yaml up -d
}

function startK8s {
  # create k8s yaml for CA server and client
  ${sumd} -p "${ORG_DIR}/k8s"
  printK8sStorageYaml | ${stee} ${ORG_DIR}/k8s/ca-pv.yaml > /dev/null
  printK8sCAPods | ${stee} ${ORG_DIR}/k8s/ca.yaml > /dev/null

  # start CA server and client
  kubectl create -f ${ORG_DIR}/k8s/ca-pv.yaml
  kubectl create -f ${ORG_DIR}/k8s/ca.yaml
}

function stopServer {
  if [ "${ENV_TYPE}" == "docker" ]; then
    echo "stop docker containers"
    docker-compose -f ${ORG_DIR}/docker/docker-compose.yaml down --volumes --remove-orphans
  else
    echo "stop k8s CA PODs"
    kubectl delete -f ${ORG_DIR}/k8s/ca.yaml
    kubectl delete -f ${ORG_DIR}/k8s/ca-pv.yaml
  fi

  if [ ! -z "${CLEANUP}" ]; then
    echo "cleanup ca/tlsca server data"
    ${surm} -R ${ORG_DIR}/ca-server
    ${surm} -R ${ORG_DIR}/tlsca-server
  fi
  echo "cleanup ca-client data"
  ${surm} -R ${ORG_DIR}/ca-client/*
}

# Print the usage message
function printHelp() {
  echo "Usage: "
  echo "  ca-server.sh <cmd> [-p <property file>] [-t <env type>] [-d]"
  echo "    <cmd> - one of 'start', or 'shutdown'"
  echo "      - 'start' - start ca and tlsca servers and ca client"
  echo "      - 'shutdown' - shutdown ca and tlsca servers and ca client, and cleanup ca-client data"
  echo "    -p <property file> - the .env file in config folder that defines network properties, e.g., netop1 (default)"
  echo "    -t <env type> - deployment environment type: one of 'docker', 'k8s' (default), 'aws', 'az', or 'gke'"
  echo "    -d - delete all ca/tlsca server data for fresh start next time"
  echo "  ca-server.sh -h (print this message)"
}

ORG_ENV="netop1"
ENV_TYPE="k8s"

CMD=${1}
shift
while getopts "h?p:t:d" opt; do
  case "$opt" in
  h | \?)
    printHelp
    exit 0
    ;;
  p)
    ORG_ENV=$OPTARG
    ;;
  t)
    ENV_TYPE=$OPTARG
    ;;
  d)
    CLEANUP="true"
    ;;
  esac
done

source $(dirname "${SCRIPT_DIR}")/config/setup.sh ${ORG_ENV} ${ENV_TYPE}
ORG_DIR=${DATA_ROOT}/canet
CA_PORT=${CA_PORT:-"7054"}
TLS_PORT=${TLS_PORT:-"7055"}

case "${CMD}" in
start)
  echo "start ca server: ${ORG_ENV} ${ENV_TYPE}"
  if [ "${ENV_TYPE}" == "docker" ]; then
    startDocker
  else
    startK8s
  fi
  ;;
shutdown)
  echo "shutdown ca server: ${ORG_ENV} ${ENV_TYPE}"
  stopServer
  ;;
*)
  printHelp
  exit 1
esac
