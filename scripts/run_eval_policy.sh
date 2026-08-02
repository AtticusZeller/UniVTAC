#!/usr/bin/env bash
set -Eeuo pipefail

python_executable="${CONDA_PREFIX:?Conda environment is not active}/bin/python"
site_packages="$(${python_executable} -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
nvjitlink_lib="${site_packages}/nvidia/nvjitlink/lib"

if [[ ! -d "${nvjitlink_lib}" ]]; then
    echo "Missing PyTorch CUDA nvJitLink runtime: ${nvjitlink_lib}" >&2
    exit 1
fi

# Keep the CUDA runtime bundled with the cu124 PyTorch wheel ahead of any system toolkit.
export LD_LIBRARY_PATH="${nvjitlink_lib}:${CONDA_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

exec "${python_executable}" scripts/eval_policy.py "$@"
