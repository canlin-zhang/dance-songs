#!/usr/bin/env bash
# One-time host bootstrap for paddleocr-docker-compose.
#
# Installs the host pieces the container needs, all of which require sudo:
#   * nvidia-container-toolkit   (apt, NVIDIA's repo)
#   * docker runtime config      (daemon.json: adds "nvidia", keeps your mtu)
#   * CDI device spec            (/etc/cdi/nvidia.yaml, required by Docker 29+ to
#                                 resolve --gpus without an NVIDIA vendor error)
# Then it refuses to continue unless the GPU is visible from inside a container,
# pulls the base image by digest, builds the derived image, and checks that
# Paddle reports compute capability 12.0.
#
#   ./setup.sh --dry-run        # print every command, sudo ones included
#   ./setup.sh                  # do it (sudo will ask for your password)
#   ./setup.sh --skip-toolkit   # toolkit already installed
#   ./setup.sh --no-pull        # base image already pulled
#
# Takes 10-20 minutes on a cold cache: the base image is ~10 GB.
#
set -euo pipefail

TOOL_DIR=$(dirname "$(readlink -f "$0")")
BASE_IMAGE="ccr-2vdh3abv-pub.cnc.bj.baidubce.com/paddlepaddle/paddleocr-vl"
BASE_DIGEST="sha256:659eb236d509966380c0ac938049cbb3494f1e84c5d5c53fcac3572c05463487"
LOCAL_IMAGE="dance-songs/paddleocr-docker-compose:latest"
LOG="$TOOL_DIR/setup-$(date +%Y%m%d-%H%M%S).log"

DRY_RUN=false
ASSUME_YES=false
SKIP_TOOLKIT=false
DO_PULL=true

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if $DRY_RUN; then return 0; fi
  "$@"
}

run_shell() {
  printf '+ %s\n' "$1"
  if $DRY_RUN; then return 0; fi
  bash -o pipefail -c "$1"
}

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)   DRY_RUN=true ;;
    --yes|-y)       ASSUME_YES=true ;;
    --skip-toolkit) SKIP_TOOLKIT=true ;;
    --no-pull)      DO_PULL=false ;;
    --help|-h)      usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- preflight
say "preflight"
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 \
  || die "docker compose v2 not found (the v1 'docker-compose' binary is not supported)"
[ -e /dev/dxg ] || [ -e /dev/nvidia0 ] \
  || note "WARNING: neither /dev/dxg (WSL2) nor /dev/nvidia0 present; is the driver installed?"
command -v apt-get >/dev/null || die "apt-get not found: this script supports Debian/Ubuntu hosts only"

if grep -qi microsoft /proc/version; then
  note "host:            WSL2 ($(uname -r))"
else
  note "host:            Linux ($(uname -r))"
fi
note "docker:          $(docker --version)"
note "compose:         $(docker compose version --short 2>/dev/null || echo '?')"
if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
  note "GPU:             $(/usr/lib/wsl/lib/nvidia-smi --query-gpu=name --format=csv,noheader)"
  note "driver:          $(/usr/lib/wsl/lib/nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
elif command -v nvidia-smi >/dev/null; then
  note "GPU:             $(nvidia-smi --query-gpu=name --format=csv,noheader)"
fi
note "free on \$HOME:  $(df -h --output=avail "$HOME" | tail -1 | tr -d ' ')"

free_gb=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
if [ "${free_gb:-0}" -lt 15 ]; then
  note "WARNING: under 15G free; the base image alone is ~10G"
fi

if ! $DRY_RUN; then
  exec > >(tee -a "$LOG") 2>&1
  note "logging to $LOG"
fi

# --------------------------------------------- 1. nvidia-container-toolkit
say "1/5 nvidia-container-toolkit (apt, needs sudo)"
if $SKIP_TOOLKIT; then
  note "skipped (--skip-toolkit)"
elif dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  note "already installed: $(dpkg-query -W -f='${Version}' nvidia-container-toolkit)"
else
  note "WSL2 needs a toolkit new enough to know about /dev/dxg; apt gives the current one"
  run_shell "sudo apt-get update"
  run_shell "sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg"
  run_shell "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  run_shell "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null"
  run_shell "sudo apt-get update"
  run_shell "sudo apt-get install -y nvidia-container-toolkit"
fi

# ------------------------------------ 2. docker runtime + CDI device spec
say "2/5 docker runtime config and CDI spec (needs sudo)"
note "an existing daemon.json keeps its keys: nvidia-ctk merges, it does not overwrite"
if [ -f /etc/docker/daemon.json ]; then
  run_shell "sudo cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak.\$(date +%Y%m%d-%H%M%S)"
else
  note "no /etc/docker/daemon.json yet; nvidia-ctk will create it"
fi
run_shell "sudo nvidia-ctk runtime configure --runtime=docker"
run_shell "sudo mkdir -p /etc/cdi && sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
run_shell "sudo systemctl restart docker"

# ------------------------------------- 3. gate: the GPU must survive Docker
say "3/5 GPU inside a container (nothing is downloaded until this passes)"
printf '+ %s\n' "docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi -L"
if ! $DRY_RUN; then
  if docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi -L; then
    note "OK: --gpus all works"
  else
    note "FAILED: --gpus all"
    note "try the CDI form:  docker run --rm --device nvidia.com/gpu=all ..."
    note "and check:         docker info | grep -i cdi ; ls -l /etc/cdi/nvidia.yaml"
    die "GPU not reachable from Docker; stopping before the 10 GB pull"
  fi
fi

# ------------------------------------------------------- 4. base image
say "4/5 base image $BASE_IMAGE@$BASE_DIGEST"
if $DO_PULL; then
  run docker pull "$BASE_IMAGE@$BASE_DIGEST"
else
  note "pull skipped (--no-pull)"
fi
run docker compose -f "$TOOL_DIR/compose.yaml" build

# ------------------------------------- 5. paddle + sm_120 inside the image
say "5/5 paddle GPU check inside the built image"
VERIFY="import paddle
print('paddle        :', paddle.__version__)
print('cuda build    :', paddle.device.is_compiled_with_cuda())
cc = paddle.device.cuda.get_device_capability()
print('capability    :', cc)
print('gpu           :', paddle.device.cuda.get_device_name(0))
x = paddle.rand([1024, 1024], dtype='float32')
print('matmul        :', float((x @ x).sum()))
print('OK' if cc == (12, 0) else 'NOT sm_120: this image expects sm_120; report the pair below')"
run docker run --rm --gpus all "$LOCAL_IMAGE" python -c "$VERIFY"

say "done$($DRY_RUN && echo ' (DRY RUN: nothing installed, nothing pulled)')"
cat <<EOF
   drop scans in:  $TOOL_DIR/input/
   convert:        $TOOL_DIR/ocr.sh
   help:           $TOOL_DIR/ocr.sh --help
EOF
