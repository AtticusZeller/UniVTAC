#!/usr/bin/env bash
set -e -o pipefail

CONDA_ENV_NAME="UniVTAC"
ISAACLAB_REVISION="v2.1.1"
CUROBO_REVISION="0a50de1ba72db304195d59d9d0b1ed269696047f"
RUN_GPU_SMOKE=false
CONDA_TOOLCHAIN_PACKAGES=(python=3.10 pip cmake=3.26 gcc=11.4 cuda-toolkit=12.4 pkgconfig)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
TACEX_DIR="${REPO_ROOT}/third_party/TacEx"
ISAACLAB_DIR="${REPO_ROOT}/third_party/IsaacLab"
CUROBO_DIR="${REPO_ROOT}/third_party/curobo"
VCPKG_ROOT="${VCPKG_ROOT:-${HOME}/Toolchain/vcpkg}"

usage() {
    cat <<'EOF'
Usage: bash scripts/install.sh [--gpu-smoke]

Install UniVTAC into the UniVTAC Conda environment. The default flow installs
and verifies dependencies without starting Isaac Sim or a training workload.

Options:
  --gpu-smoke  Launch Isaac Sim headlessly and import TacEx after installation.
  -h, --help   Show this help message.
EOF
}

log() {
    printf '[UniVTAC] %s\n' "$*"
}

die() {
    printf '[UniVTAC][ERROR] %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    local line_number=$1
    trap - ERR
    printf '[UniVTAC][ERROR] Installation stopped at line %s (exit %s).\n' "${line_number}" "${exit_code}" >&2
    printf '[UniVTAC][ERROR] Fix the reported command and rerun this script; completed phases are reusable.\n' >&2
    exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gpu-smoke)
                RUN_GPU_SMOKE=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

conda_env_exists() {
    conda env list | awk 'NF >= 2 && $1 !~ /^#/ { print $1 }' | grep -Fxq "${CONDA_ENV_NAME}"
}

package_version() {
    local package_name=$1
    "${python_exe}" -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' "${package_name}" 2>/dev/null
}

package_is_installed() {
    package_version "$1" >/dev/null
}

ensure_system_packages() {
    local -a missing_packages=()
    local package_name

    command -v apt-get >/dev/null 2>&1 || die "This installer currently supports apt-based Ubuntu systems."
    for package_name in cmake build-essential git-lfs curl zip unzip tar; do
        if ! dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -Fq 'install ok installed'; then
            missing_packages+=("${package_name}")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log "System build packages are already installed."
        return
    fi

    log "Installing system packages: ${missing_packages[*]}"
    if [[ ${EUID} -eq 0 ]]; then
        apt-get install -y "${missing_packages[@]}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get install -y "${missing_packages[@]}"
    else
        die "Root access or sudo is required to install: ${missing_packages[*]}"
    fi
}

ensure_git_checkout() {
    local name=$1
    local repository_url=$2
    local revision=$3
    local destination=$4
    local actual_url target_commit current_commit

    if [[ -e "${destination}" && ! -d "${destination}/.git" ]]; then
        die "${destination} exists but is not a Git checkout; move it aside and rerun."
    fi

    if [[ ! -d "${destination}/.git" ]]; then
        log "Cloning ${name} into ${destination}."
        git clone "${repository_url}" "${destination}"
    fi

    actual_url="$(git -C "${destination}" remote get-url origin)"
    [[ "${actual_url}" == "${repository_url}" || "${actual_url}" == "${repository_url%.git}" ]] || \
        die "${name} origin is ${actual_url}, expected ${repository_url}."

    if ! git -C "${destination}" rev-parse --verify --quiet "${revision}^{commit}" >/dev/null; then
        log "Fetching ${name} revision ${revision}."
        git -C "${destination}" fetch --tags origin "${revision}"
    fi

    target_commit="$(git -C "${destination}" rev-parse "${revision}^{commit}")"
    current_commit="$(git -C "${destination}" rev-parse HEAD)"
    if [[ "${current_commit}" == "${target_commit}" ]]; then
        log "${name} is already at ${revision}."
        return
    fi

    if [[ -n "$(git -C "${destination}" status --porcelain)" ]]; then
        die "${name} has local changes and is not at ${revision}; refusing to overwrite it."
    fi
    git -C "${destination}" checkout --detach "${target_commit}"
}

load_conda_env() {
    local conda_base

    command -v conda >/dev/null 2>&1 || die "Conda is not available on PATH."
    conda_base="$(conda info --base)"
    # shellcheck disable=SC1091
    source "${conda_base}/etc/profile.d/conda.sh"

    if conda_env_exists; then
        log "Conda environment ${CONDA_ENV_NAME} already exists."
    else
        log "Creating Conda environment ${CONDA_ENV_NAME} with the UIPC toolchain."
        conda create --override-channels --channel conda-forge \
            --name "${CONDA_ENV_NAME}" -y "${CONDA_TOOLCHAIN_PACKAGES[@]}"
    fi

    conda activate "${CONDA_ENV_NAME}"
    unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT

    # Always reconcile the build toolchain so a failed first run can resume.
    log "Reconciling the UIPC Conda toolchain."
    conda install --override-channels --channel conda-forge \
        --name "${CONDA_ENV_NAME}" -y "${CONDA_TOOLCHAIN_PACKAGES[@]}"
    conda activate "${CONDA_ENV_NAME}"
}

configure_python_tools() {
    python_exe="${CONDA_PREFIX}/bin/python"
    pip_exe="${CONDA_PREFIX}/bin/pip"

    if [[ ! -x "${CONDA_PREFIX}/bin/uv" ]]; then
        "${python_exe}" -m pip install uv --index-url https://pypi.org/simple
    fi
    uv_exe="${CONDA_PREFIX}/bin/uv"

    export python_exe pip_exe uv_exe
    export CUDA_HOME="${CONDA_PREFIX}"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

    log "Using Python executable: ${python_exe}"
    log "Using uv executable: ${uv_exe}"
    "${python_exe}" -m pip install --upgrade pip
    "${uv_exe}" pip install 'setuptools<82' wheel vcs-versioning mypy==2.3.0 \
        --index-url https://pypi.org/simple
}

install_isaac_sim() {
    local isaacsim_version torch_version

    isaacsim_version="$(package_version isaacsim || true)"
    torch_version="$(package_version torch || true)"
    if [[ "${isaacsim_version}" == 4.5.0* && "${torch_version}" == 2.5.1* ]]; then
        log "Isaac Sim ${isaacsim_version} and PyTorch ${torch_version} are already installed."
        return
    fi

    log "Installing PyTorch 2.5.1 (CUDA 12.4) and Isaac Sim 4.5.0."
    "${uv_exe}" pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu124
    "${uv_exe}" pip install 'isaacsim[all,extscache]==4.5.0' --extra-index-url https://pypi.nvidia.com
}

install_isaac_lab() {
    local extension_dir

    ensure_git_checkout "Isaac Lab" "https://github.com/isaac-sim/IsaacLab.git" "${ISAACLAB_REVISION}" "${ISAACLAB_DIR}"
    if package_is_installed isaaclab; then
        log "Isaac Lab is already installed from the pinned source checkout."
        return
    fi

    log "Installing Isaac Lab ${ISAACLAB_REVISION}."
    "${uv_exe}" pip install flatdict==4.0.1 --no-build-isolation
    # v2.1.1's wrapper replaces UniVTAC's required torch 2.5.1+cu124 with
    # torch 2.7.0+cu128. Install the same source extensions without that swap.
    for extension_dir in "${ISAACLAB_DIR}"/source/*; do
        if [[ -f "${extension_dir}/setup.py" ]]; then
            "${uv_exe}" pip install --editable "${extension_dir}" --index-url https://pypi.org/simple
        fi
    done
    "${uv_exe}" pip install --editable "${ISAACLAB_DIR}/source/isaaclab_rl[all]" \
        --editable "${ISAACLAB_DIR}/source/isaaclab_mimic[all]" \
        --index-url https://pypi.org/simple
}

install_curobo() {
    ensure_git_checkout "cuRobo" "https://github.com/NVlabs/curobo.git" "${CUROBO_REVISION}" "${CUROBO_DIR}"
    if package_is_installed nvidia_curobo; then
        log "cuRobo is already installed from the pinned source checkout."
        return
    fi

    log "Installing cuRobo ${CUROBO_REVISION}."
    git -C "${CUROBO_DIR}" lfs install --local
    git -C "${CUROBO_DIR}" lfs pull
    "${uv_exe}" pip install warp-lang==1.0.0 --no-build-isolation
    "${uv_exe}" pip install -e "${CUROBO_DIR}" --no-build-isolation
}

install_tacex() {
    log "Installing the bundled TacEx core packages."
    PIP_INDEX_URL=https://pypi.org/simple TERM=xterm "${TACEX_DIR}/tacex.sh" --install
    "${uv_exe}" pip uninstall torch_scatter -y || true
    "${uv_exe}" pip install torch_scatter==2.1.2 -f https://data.pyg.org/whl/torch-2.5.1+cu124.html
}

ensure_vcpkg() {
    local toolchain_file="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
    local vcpkg_executable="${VCPKG_ROOT}/vcpkg"

    if [[ ! -d "${VCPKG_ROOT}/.git" ]]; then
        if [[ -e "${VCPKG_ROOT}" ]]; then
            die "${VCPKG_ROOT} exists but is not a vcpkg Git checkout."
        fi
        log "Cloning vcpkg into ${VCPKG_ROOT}."
        mkdir -p "$(dirname -- "${VCPKG_ROOT}")"
        git clone https://github.com/microsoft/vcpkg.git "${VCPKG_ROOT}"
    fi

    if [[ ! -x "${vcpkg_executable}" ]]; then
        log "Bootstrapping vcpkg."
        "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics
    else
        log "vcpkg is already bootstrapped."
    fi

    export VCPKG_ROOT
    export CMAKE_TOOLCHAIN_FILE="${toolchain_file}"
}

install_tacex_uipc() {
    ensure_vcpkg
    if package_is_installed tacex_uipc; then
        log "tacex_uipc is already installed."
        return
    fi

    log "Building and installing tacex_uipc."
    # libuipc invokes pip recursively after compiling pyuipc. Keep that child
    # process off incomplete environment-provided package mirrors.
    PIP_INDEX_URL=https://pypi.org/simple PIP_EXTRA_INDEX_URL= \
        "${uv_exe}" pip install -e "${TACEX_DIR}/source/tacex_uipc" -v --no-build-isolation
}

verify_installation() {
    local package_name

    [[ "$(package_version isaacsim)" == 4.5.0* ]] || die "isaacsim 4.5.0 is not installed."
    [[ "$(package_version torch)" == 2.5.1* ]] || die "PyTorch 2.5.1 is not installed."
    for package_name in isaaclab nvidia_curobo tacex tacex_assets tacex_tasks tacex_uipc torch_scatter; do
        package_is_installed "${package_name}" || die "Python package ${package_name} is not installed."
    done
    "${python_exe}" -m pip check
    "${python_exe}" -c 'import uipc; print("[UniVTAC] uipc extension import succeeded.")'
    log "Dependency verification passed."
}

run_gpu_smoke() {
    local smoke_log

    smoke_log="$(mktemp "${TMPDIR:-/tmp}/univtac-gpu-smoke.XXXXXX.log")"
    log "Launching the opt-in headless GPU smoke test."
    "${python_exe}" - <<'PY' 2>&1 | tee "${smoke_log}"
from isaaclab.app import AppLauncher

simulation_app = AppLauncher(headless=True).app
try:
    import omni.gpu_foundation_factory

    gpu_factory = omni.gpu_foundation_factory.get_gpu_foundation_factory_interface()
    device_count = gpu_factory.get_device_count()
    if device_count < 1:
        raise RuntimeError("Isaac Sim GPU foundation did not create a graphics device.")

    device_names = [gpu_factory.get_device_name(index) for index in range(device_count)]
    print(f"[UniVTAC] Isaac Sim graphics devices: {device_names}")

    import tacex  # noqa: F401
    import tacex_uipc  # noqa: F401

    print("[UniVTAC] Isaac Sim, TacEx, and tacex_uipc loaded successfully.", flush=True)
finally:
    simulation_app.close()
PY

    if grep -Fq "No device could be created" "${smoke_log}"; then
        die "Isaac Sim could not create a Vulkan/RTX graphics device. Full smoke output: ${smoke_log}"
    fi
    if ! grep -Fq "[UniVTAC] Isaac Sim, TacEx, and tacex_uipc loaded successfully." "${smoke_log}"; then
        die "GPU smoke exited before its success sentinel. Full smoke output: ${smoke_log}"
    fi
}

main() {
    parse_args "$@"
    cd "${REPO_ROOT}"

    ensure_system_packages
    load_conda_env
    configure_python_tools
    install_isaac_sim
    install_isaac_lab
    install_curobo
    install_tacex
    install_tacex_uipc
    "${uv_exe}" pip install transforms3d trimesh tetgen
    verify_installation

    if [[ "${RUN_GPU_SMOKE}" == true ]]; then
        run_gpu_smoke
    else
        log "Skipping GPU smoke. Rerun with --gpu-smoke when a GPU is available."
    fi
    log "Installation completed successfully. Activate it with: conda activate ${CONDA_ENV_NAME}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
