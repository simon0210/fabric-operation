#!/bin/bash
# create MSP configuration, channel profile, and orderer genesis block
#   for target environment, i.e., docker, k8s, aws, az, gke, etc
# usage: msp-util.sh -h
# to display usage info

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; echo "$(pwd)")"

# e.g., getHostUrl peer-1
function getHostUrl {
  if [ ! -z "${SVC_DOMAIN}" ]; then
    # for Kubernetes target
    svc=${1%%-*}
    echo "${1}.${svc}.${SVC_DOMAIN}"
  else
    # default for docker-composer
    echo "${1}.${FABRIC_ORG}"
  fi
}

# set list of orderers from config
function getOrderers {
  ORDERERS=()
  seq=${ORDERER_MIN:-"0"}
  max=${ORDERER_MAX:-"0"}
  until [ "${seq}" -ge "${max}" ]; do
    ORDERERS+=("orderer-${seq}")
    seq=$((${seq}+1))
  done
}

# set list of peers from config
function getPeers {
  PEERS=()
  seq=${PEER_MIN:-"0"}
  max=${PEER_MAX:-"0"}
  until [ "${seq}" -ge "${max}" ]; do
    PEERS+=("peer-${seq}")
    seq=$((${seq}+1))
  done
}

function printOrdererMSP {
  if [ "${#ORDERERS[@]}" -gt "0" ]; then
    echo "
    - &${ORDERER_MSP}
        Name: ${ORDERER_MSP}
        ID: ${ORDERER_MSP}
        MSPDir: /etc/hyperledger/tool/crypto/msp
        Policies:
            Readers:
                Type: Signature
                Rule: \"OR('${ORDERER_MSP}.member')\"
            Writers:
                Type: Signature
                Rule: \"OR('${ORDERER_MSP}.member')\"
            Admins:
                Type: Signature
                Rule: \"OR('${ORDERER_MSP}.admin')\""
  fi
}

function printPeerMSP {
  echo "
    - &${ORG_MSP}
        Name: ${ORG_MSP}
        ID: ${ORG_MSP}
        MSPDir: /etc/hyperledger/tool/crypto/msp
        Policies:
            Readers:
                Type: Signature
                Rule: \"OR('${ORG_MSP}.admin', '${ORG_MSP}.peer', '${ORG_MSP}.client')\"
            Writers:
                Type: Signature
                Rule: \"OR('${ORG_MSP}.admin', '${ORG_MSP}.client')\"
            Admins:
                Type: Signature
                Rule: \"OR('${ORG_MSP}.admin')\""
  if [ "${#PEERS[@]}" -gt "0" ]; then
    echo "
        AnchorPeers:
            - Host: $(getHostUrl ${PEERS[0]})
              Port: 7051"
  fi
}

function printCapabilities {
  echo "
Capabilities:
    Channel: &ChannelCapabilities
        V1_4_3: true
        V1_3: false
        V1_1: false
    Orderer: &OrdererCapabilities
        V1_4_2: true
        V1_1: false
    Application: &ApplicationCapabilities
        V1_4_2: true
        V1_3: false
        V1_2: false
        V1_1: false"
}

function printApplicationDefaults {
  echo "
Application: &ApplicationDefaults
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: \"ANY Readers\"
        Writers:
            Type: ImplicitMeta
            Rule: \"ANY Writers\"
        Admins:
            Type: ImplicitMeta
            Rule: \"MAJORITY Admins\"

    Capabilities:
        <<: *ApplicationCapabilities"
}

function printOrdererDefaults {
  if [ "${#ORDERERS[@]}" -gt "0" ]; then
    echo "
Orderer: &OrdererDefaults
    OrdererType: solo
    Addresses:
        - $(getHostUrl ${ORDERERS[0]}):7050
    BatchTimeout: 2s
    BatchSize:
        MaxMessageCount: 10
        AbsoluteMaxBytes: 99 MB
        PreferredMaxBytes: 512 KB
    Organizations:

    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: \"ANY Readers\"
        Writers:
            Type: ImplicitMeta
            Rule: \"ANY Writers\"
        Admins:
            Type: ImplicitMeta
            Rule: \"MAJORITY Admins\"
        BlockValidation:
            Type: ImplicitMeta
            Rule: \"ANY Writers\""
  fi
}

function printChannelDefaults {
  echo "
Channel: &ChannelDefaults
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: \"ANY Readers\"
        Writers:
            Type: ImplicitMeta
            Rule: \"ANY Writers\"
        Admins:
            Type: ImplicitMeta
            Rule: \"MAJORITY Admins\"
    Capabilities:
        <<: *ChannelCapabilities"
}

function printOrgConsortium {
  echo "
        Consortiums:
            ${ORG}Consortium:
                Organizations:
                    - *${ORG_MSP}"
}

function printSoloOrdererProfile {
  if [ "${#ORDERERS[@]}" -gt "0" ]; then
    echo "
    soloOrdererGenesis:
        <<: *ChannelDefaults
        Orderer:
            <<: *OrdererDefaults
            Organizations:
                - *${ORDERER_MSP}
            Capabilities:
                <<: *OrdererCapabilities"
    printOrgConsortium
  fi
}

function printEtcdraftOrdererProfile {
  if [ "${#ORDERERS[@]}" -gt "0" ]; then
    echo "
    etcdraftOrdererGenesis:
        <<: *ChannelDefaults
        Capabilities:
            <<: *ChannelCapabilities
        Orderer:
            <<: *OrdererDefaults
            OrdererType: etcdraft
            EtcdRaft:
                Consenters:"
    for ord in "${ORDERERS[@]}"; do
      echo "                - Host: $(getHostUrl ${ord})
                  Port: 7050
                  ClientTLSCert: /etc/hyperledger/tool/crypto/orderers/${ord}/tls/server.crt
                  ServerTLSCert: /etc/hyperledger/tool/crypto/orderers/${ord}/tls/server.crt"
    done
    echo "            Addresses:"
    for ord in "${ORDERERS[@]}"; do
      echo "                - $(getHostUrl ${ord}):7050"
    done
    echo "            Organizations:
                - *${ORDERER_MSP}
            Capabilities:
                <<: *OrdererCapabilities
        Application:
            <<: *ApplicationDefaults
            Organizations:
            - <<: *${ORDERER_MSP}"
    printOrgConsortium
  fi
}

function printOrgChannelProfile {
  echo "
    ${ORG}Channel:
        Consortium: ${ORG}Consortium
        <<: *ChannelDefaults
        Application:
            <<: *ApplicationDefaults
            Organizations:
                - *${ORG_MSP}
            Capabilities:
                <<: *ApplicationCapabilities"
}

function printConfigTx {
  getOrderers
  getPeers

  echo "---
Organizations:"
  printOrdererMSP
  printPeerMSP

  printCapabilities
  printApplicationDefaults
  printOrdererDefaults
  printChannelDefaults

  echo "
Profiles:"
  printSoloOrdererProfile
  printEtcdraftOrdererProfile
  printOrgChannelProfile
}

function printDockerYaml {
  echo "version: '3.7'

services:
  tool:
    container_name: tool
    image: hyperledger/fabric-tools
    tty: true
    stdin_open: true
    environment:
      - FABRIC_CFG_PATH=/etc/hyperledger/tool
      - GOPATH=/opt/gopath
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - FABRIC_LOGGING_SPEC=INFO
      - SYS_CHANNEL=${SYS_CHANNEL}
      - ORG=${ORG}
      - ORG_MSP=${ORG_MSP}
      - ORDERER_TYPE=${ORDERER_TYPE}
      - TEST_CHANNEL=${TEST_CHANNEL}
    working_dir: /etc/hyperledger/tool
    command: /bin/bash -c 'while true; do sleep 30; done'
    volumes:
        - /var/run/:/host/var/run/
        - ${DATA_ROOT}/tool/:/etc/hyperledger/tool
    networks:
    - ${ORG}

networks:
  ${ORG}:
"
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

# print k8s PV and PVC for tool Pod
function printK8sStorageYaml {
  printK8sStorageClass "tool-data-class"
  printK8sPV "data-tool"
}

# printK8sPV <name>
function printK8sPV {
  echo "---
kind: PersistentVolume
apiVersion: v1
# create PV for ${1}
metadata:
  name: ${1}-pv
  labels:
    app: ${1}
    org: ${ORG}
spec:
  capacity:
    storage: 100Mi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: tool-data-class"

  if [ "${K8S_PERSISTENCE}" == "efs" ]; then
    echo "  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${AWS_FSID}
    volumeAttributes:
      path: /${FABRIC_ORG}/tool"
  elif [ "${K8S_PERSISTENCE}" == "azf" ]; then
    echo "  azureFile:
    secretName: azure-secret
    shareName: ${AZ_STORAGE_SHARE}/${FABRIC_ORG}/tool
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
    path: /vol1/${FABRIC_ORG}/tool"
  else
    echo "  hostPath:
    path: ${DATA_ROOT}/tool
    type: Directory"
  fi

  echo "---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: ${1}-pvc
  namespace: ${ORG}
spec:
  storageClassName: tool-data-class
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  selector:
    matchLabels:
      app: ${1}
      org: ${ORG}"
}

function printK8sPod {
  echo "
apiVersion: v1
kind: Pod
metadata:
  name: tool
  namespace: ${ORG}
spec:
  containers:
  - name: tool
    image: hyperledger/fabric-tools
    imagePullPolicy: Always
    env:
    - name: FABRIC_LOGGING_SPEC
      value: INFO
    - name: GOPATH
      value: /opt/gopath
    - name: FABRIC_CFG_PATH
      value: /etc/hyperledger/tool
    - name: CORE_VM_ENDPOINT
      value: unix:///host/var/run/docker.sock
    - name: ORDERER_TYPE
      value: ${ORDERER_TYPE}
    - name: SYS_CHANNEL
      value: ${SYS_CHANNEL}
    - name: ORG
      value: ${ORG}
    - name: ORG_MSP
      value: ${ORG_MSP}
    - name: TEST_CHANNEL
      value: ${TEST_CHANNEL}
    command:
    - /bin/bash
    - -c
    - while true; do sleep 30; done
    workingDir: /etc/hyperledger/tool
    volumeMounts:
    - mountPath: /host/var/run
      name: docker-sock
    - mountPath: /etc/hyperledger/tool
      name: data
  volumes:
  - name: docker-sock
    hostPath:
      path: /var/run
      type: Directory
  - name: data
    persistentVolumeClaim:
      claimName: data-tool-pvc"
}

function startService {
  # print out configtx.yaml
  echo "create ${DATA_ROOT}/tool/configtx.yaml"
  printConfigTx | ${stee} ${DATA_ROOT}/tool/configtx.yaml > /dev/null

  if [ "${ENV_TYPE}" == "docker" ]; then
    echo "use docker-compose"
    # start tool container to generate genesis block and channel tx
    mkdir -p "${DATA_ROOT}/tool/docker"
    printDockerYaml > ${DATA_ROOT}/tool/docker/docker-compose.yaml
    docker-compose -f ${DATA_ROOT}/tool/docker/docker-compose.yaml up -d
  else
    echo "use kubernetes"
    # print k8s yaml for tool job
    ${sumd} -p "${DATA_ROOT}/tool/k8s"
    printK8sStorageYaml | ${stee} ${DATA_ROOT}/tool/k8s/tool-pv.yaml > /dev/null
    printK8sPod | ${stee} ${DATA_ROOT}/tool/k8s/tool.yaml > /dev/null
    # run tool job
    kubectl create -f ${DATA_ROOT}/tool/k8s/tool-pv.yaml
    kubectl create -f ${DATA_ROOT}/tool/k8s/tool.yaml
  fi

  ${sucp} ${SCRIPT_DIR}/gen-artifact.sh ${DATA_ROOT}/tool
}

function shutdownService {
  if [ "${ENV_TYPE}" == "docker" ]; then
    echo "shutdown docker msp tools"
    docker-compose -f ${DATA_ROOT}/tool/docker/docker-compose.yaml down --volumes --remove-orphans
  else
    echo "shutdown K8s msp tools"
    kubectl delete -f ${DATA_ROOT}/tool/k8s/tool.yaml
    kubectl delete -f ${DATA_ROOT}/tool/k8s/tool-pv.yaml
  fi
}

function execCommand {
  local _cmd="gen-artifact.sh $@"
  if [ "${ENV_TYPE}" == "docker" ]; then
    docker exec -it tool bash -c "./${_cmd}"
  else
    kubectl exec -it tool -- bash -c "./${_cmd}"
  fi
}

# Print the usage message
function printHelp() {
  echo "Usage: "
  echo "  msp-util.sh <cmd> [-p <property file>] [-t <env type>] [-o <consensus type>] [-c <channel name>]"
  echo "    <cmd> - one of 'start', 'shutdown', 'bootstrap', 'genesis', 'channel'"
  echo "      - 'start' - start tools container to run msp-util"
  echo "      - 'shutdown' - shutdown tools container for the msp-util"
  echo "      - 'bootstrap' - generate bootstrap genesis block and test channel tx defined in network spec"
  echo "      - 'genesis' - generate genesis block of specified consensus type"
  echo "      - 'channel' - generate channel creation tx for specified channel name"
  echo "    -p <property file> - the .env file in config folder that defines network properties, e.g., netop1 (default)"
  echo "    -t <env type> - deployment environment type: one of 'docker', 'k8s' (default), 'aws', 'az', or 'gke'"
  echo "    -o <consensus type> - 'solo' or 'etcdraft' used with the 'genesis' command"
  echo "    -c <channel name> - name of a channel, used with the 'channel' command"
  echo "  msp-util.sh -h (print this message)"
}

ORG_ENV="netop1"
ENV_TYPE="k8s"

CMD=${1}
shift
while getopts "h?p:t:o:c:" opt; do
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
  o)
    CONS_TYPE=$OPTARG
    ;;
  c)
    CHAN_NAME=$OPTARG
    ;;
  esac
done

source $(dirname "${SCRIPT_DIR}")/config/setup.sh ${ORG_ENV} ${ENV_TYPE}
ORG_MSP="${ORG}MSP"
ORDERER_MSP=${ORDERER_MSP:-"${ORG}OrdererMSP"}
SYS_CHANNEL=${SYS_CHANNEL:-"${ORG}-channel"}
TEST_CHANNEL=${TEST_CHANNEL:-"mychannel"}
ORDERER_TYPE=${ORDERER_TYPE:-"solo"}

case "${CMD}" in
start)
  echo "start msp util tool: ${ORG_ENV} ${ENV_TYPE}"
  startService
  ;;
shutdown)
  echo "shutdown msp util tool: ${ORG_ENV} ${ENV_TYPE}"
  shutdownService
  ;;
bootstrap)
  echo "bootstrap msp artifacts: ${ORG_ENV} ${ENV_TYPE}"
  execCommand "bootstrap"
  ;;
genesis)
  echo "create genesis block for consensus type: [ ${CONS_TYPE} ]"
  if [ -z "${CONS_TYPE}" ]; then
    echo "Error: consensus type not specified"
    printHelp
  else
    execCommand "genesis ${CONS_TYPE}"
  fi
  ;;
channel)
  echo "create channel tx for channel: [ ${CHAN_NAME} ]"
  if [ -z "${CHAN_NAME}" ]; then
    echo "Error: channel name not specified"
    printHelp
  else
    execCommand "channel ${CHAN_NAME}"
  fi
  ;;
*)
  printHelp
  exit 1
esac
