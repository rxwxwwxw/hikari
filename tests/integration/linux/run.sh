#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DISTRO="all"
LOCAL_ONLY=0
ENGINE="auto" # auto | podman | docker
PODMAN_STATIC_VER="v6.2.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --distro=*) DISTRO="${1#*=}"; shift ;;
    --distro) DISTRO="${2:?}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    --engine) ENGINE="${2:?}"; shift 2 ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--distro all|fedora|arch|ubuntu|debian] [--engine auto|podman|docker] [--local-only]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$ENGINE" in
  auto|podman|docker) ;;
  *) echo "Invalid --engine: $ENGINE (expected auto|podman|docker)" >&2; exit 2 ;;
esac

echo "=== 1. Running rootless Linux installer & distro-fixture matrix ==="
bash "$SCRIPT_DIR/test-installer.sh"

echo "=== 2. Running live loopback service & API contract smoke test ==="
bash "$SCRIPT_DIR/test-services.sh"

if [ "$LOCAL_ONLY" -eq 1 ]; then
  echo "Skipped container builds (--local-only requested)."
  exit 0
fi

bootstrap_podman_static() {
  local cache_root="${HIKARI_PODMAN_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/hikari/podman-static}"
  local arch_tag
  case "$(uname -m)" in
    x86_64|amd64) arch_tag="amd64" ;;
    aarch64|arm64) arch_tag="arm64" ;;
    *) echo "Unsupported arch for static podman: $(uname -m)" >&2; return 1 ;;
  esac

  local base="$cache_root/podman-linux-$arch_tag"
  local cfg="$cache_root/cfg"
  local data="$cache_root/data"

  if [ ! -x "$base/usr/local/bin/podman" ]; then
    echo "Bootstrapping rootless podman-static ($PODMAN_STATIC_VER, $arch_tag) into $cache_root..."
    mkdir -p "$cache_root"
    local url="https://github.com/mgoltzsche/podman-static/releases/download/${PODMAN_STATIC_VER}/podman-linux-${arch_tag}.tar.gz"
    curl -fsSL "$url" -o "$cache_root/podman-linux-${arch_tag}.tar.gz"
    tar -xzf "$cache_root/podman-linux-${arch_tag}.tar.gz" -C "$cache_root"
  fi

  mkdir -p "$cfg/containers" "$data/storage" "$data/run/storage"
  cp "$base/etc/containers/policy.json" "$cfg/containers/policy.json"
  cp "$base/etc/containers/registries.conf" "$cfg/containers/registries.conf"
  cp "$base/etc/containers/seccomp.json" "$cfg/containers/seccomp.json"

  cat > "$cfg/containers.conf" <<EOF
[containers]
netns = "pasta"
default_sysctls = []
seccomp_profile = "$cfg/containers/seccomp.json"
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
runtime = "crun"
helper_binaries_dir = ["$base/usr/local/lib/podman", "$base/usr/local/bin"]
[engine.runtimes]
crun = ["$base/usr/local/bin/crun"]
[network]
network_backend = "netavark"
pasta_options = ["--quiet"]
EOF

  cat > "$cfg/storage.conf" <<EOF
[storage]
driver = "overlay"
runroot = "$data/run/storage"
graphroot = "$data/storage"
[storage.options.overlay]
mount_program = "$base/usr/local/bin/fuse-overlayfs"
mountopt = "nodev"
EOF

  export PATH="$base/usr/local/bin:$base/usr/local/lib/podman:$PATH"
  export XDG_CONFIG_HOME="$cfg"
  export CONTAINERS_CONF="$cfg/containers.conf"
  export CONTAINERS_STORAGE_CONF="$cfg/storage.conf"
  export CONTAINERS_REGISTRIES_CONF="$cfg/containers/registries.conf"
  PODMAN_ROOT_ARGS=(--root "$data/storage" --runroot "$data/run/storage")
}

SELECTED_ENGINE=""
PODMAN_ROOT_ARGS=()

if [ "$ENGINE" = "podman" ]; then
  if command -v podman >/dev/null 2>&1; then
    SELECTED_ENGINE="podman"
  else
    bootstrap_podman_static
    SELECTED_ENGINE="podman"
  fi
elif [ "$ENGINE" = "docker" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    SELECTED_ENGINE="docker"
  fi
else
  # auto: prefer podman, then docker, else bootstrap podman-static if curl + newuidmap exist
  if command -v podman >/dev/null 2>&1; then
    SELECTED_ENGINE="podman"
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    SELECTED_ENGINE="docker"
  elif command -v newuidmap >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    bootstrap_podman_static
    SELECTED_ENGINE="podman"
  fi
fi

echo "=== 3. Checking container matrix ($DISTRO via ${SELECTED_ENGINE:-none}) ==="
if [ -z "$SELECTED_ENGINE" ]; then
  echo "NOTE: Neither Podman nor an accessible Docker daemon is available."
  echo "SKIPPED: Container builds for Dockerfile.{fedora,arch,ubuntu,debian}."
  exit 0
fi

declare -a TARGETS
if [ "$DISTRO" = "all" ]; then
  TARGETS=(fedora arch ubuntu debian)
else
  TARGETS=("$DISTRO")
fi

CREATED_IMAGES=()
run_ctr() {
  if [ "$SELECTED_ENGINE" = "podman" ]; then
    podman "${PODMAN_ROOT_ARGS[@]}" "$@"
  else
    docker "$@"
  fi
}

cleanup_containers() {
  for img in "${CREATED_IMAGES[@]:-}"; do
    run_ctr rmi -f "$img" >/dev/null 2>&1 || true
  done
}
trap cleanup_containers EXIT

for d in "${TARGETS[@]}"; do
  df="$SCRIPT_DIR/Dockerfile.$d"
  tag="localhost/hikari-test-$d:$$"
  echo "--- Building & running container test for $d ($df) ---"
  run_ctr build -t "$tag" -f "$df" "$REPO_ROOT"
  CREATED_IMAGES+=("$tag")
  run_ctr run --rm "$tag"
done

echo "All Linux integration tests (including $SELECTED_ENGINE distro matrix) PASSED."
