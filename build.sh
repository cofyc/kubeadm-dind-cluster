#!/bin/bash -x

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

if [ $(uname) = Darwin ]; then
  readlinkf(){ perl -MCwd -e 'print Cwd::abs_path shift' "$1";}
else
  readlinkf(){ readlink -f "$1"; }
fi
DIND_ROOT="$(cd $(dirname "$(readlinkf "${BASH_SOURCE}")"); pwd)"

# FIXME
source "${DIND_ROOT}/config.sh"

IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-}"

KUBEADM_URL="${KUBEADM_URL:-}"
HYPERKUBE_URL="${HYPERKUBE_URL:-}"
KUBEADM_SHA1=${KUBEADM_SHA1:-}
HYPERKUBE_SHA1=${HYPERKUBE_SHA1:-}

prepull_images=(gcr.io/google_containers/kube-discovery-amd64:1.0
                gcr.io/google_containers/kubedns-amd64:1.7
                gcr.io/google_containers/exechealthz-amd64:1.1
                gcr.io/google_containers/kube-dnsmasq-amd64:1.3
                gcr.io/google_containers/pause-amd64:3.0
                gcr.io/google_containers/etcd-amd64:2.2.5)

hypokube_base_image=mirantis/hypokube:base
image_version_suffix=v4
image_name="mirantis/kubeadm-dind-cluster"
bare_image_name="${image_name}:bare-${image_version_suffix}"

function dind::step {
  local OPTS=""
  if [ "$1" = "-n" ]; then
    shift
    OPTS+="-n"
  fi
  GREEN="$1"
  shift
  if [ -t 1 ] ; then
    echo -e ${OPTS} "\x1B[97m* \x1B[92m${GREEN}\x1B[39m $*" 1>&2
  else
    echo ${OPTS} "* ${GREEN} $*" 1>&2
  fi
}

function dind::build-hypokube {
    dind::step "Building hypokube image"
    docker build -t ${hypokube_base_image} -f image/hypokube_base.dkr image
}

function dind::image-archive-name {
    local images=("$@")
    image_hash="$(echo -n "${images[@]}" | md5sum | head -c32)"
    # echo "images-${image_hash}.tar.gz"
    echo "images-${image_hash}.tar"
}

function dind::save-images {
    local archive="$1"
    shift
    local images=("$@")
    dind::step "Pulling images: ${images[*]}"
    for image in "${images[@]}"; do
        if [[ ${image} != ${hypokube_base_image} ]]; then
            docker pull "${image}"
        fi
    done
    docker save "${images[@]}" | lz4 -9 > "${archive}"
}

# Rationale behind storing compressed prepulled images inside the image:
# this way they're pulled just once, otherwise it would be necessary to
# re-download them after each 'clean'
function dind::copy-saved-images {
    local dest="$1"
    shift
    local images=("$@")
    if [[ ! ${IMAGE_CACHE_DIR} ]]; then
        dind::save-images "${dest}" "${images[@]}"
    else
        local cached_archive="${IMAGE_CACHE_DIR}/$(dind::image-archive-name ${images[@]})"
        if [[ ! -f ${cached_archive} ]]; then
            mkdir -p "${IMAGE_CACHE_DIR}"
            dind::save-images "${cached_archive}" "${images[@]}"
        fi
        cp "${cached_archive}" "${dest}"
    fi
}

function dind::build-base {
    docker build -t "${bare_image_name}" image/
}

function dind::build-image {
    local name="$1"
    local -a images=("${prepull_images[@]}")

    dind::build-hypokube
    images+=("${hypokube_base_image}")

    dind::copy-saved-images save.tar.lz4 "${images[@]}"
    docker build -t "${name}" \
           --build-arg KUBEADM_URL="${KUBEADM_URL}" \
           --build-arg KUBEADM_SHA1="${KUBEADM_SHA1}" \
           --build-arg HYPERKUBE_URL="${HYPERKUBE_URL}" \
           --build-arg HYPERKUBE_SHA1="${HYPERKUBE_SHA1}" \
           .
}

dind::build-base
dind::build-image "${image_name}:rmme"

# todo: for prebuilt images, just update dl targets to /k8s