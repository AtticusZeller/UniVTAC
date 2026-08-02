# Installation Guide

## Installation all-in-one Script

Clone the repository and run the installation script `scripts/install.sh` to set up the environment and install dependencies all at once. The script will create a conda environment named `UniVTAC` and install Isaac Sim, Isaac Lab, TacEx, cuRobo, and other necessary packages.

```bash
git clone https://github.com/univtac/UniVTAC.git
cd UniVTAC
bash scripts/install.sh
```

默认命令只安装依赖并执行轻量检查，不会运行 cuRobo 全量测试、启动 512 环境训练或采集演示数据。大多数安装阶段可以在失败后直接重跑；`tacex_uipc` 的 vcpkg manifest 安装是例外，未完成的 build cache 可能需要先隔离后再重试。

Conda 构建工具链通过 conda-forge 安装，并显式忽略本机配置的默认 channel，因此安装器不会代替用户接受 Anaconda channel 的服务条款。

Isaac Lab 2.1.1 的上游 wrapper 会强制改装 PyTorch 2.7.0+cu128；UniVTAC 需要的 cuRobo 栈固定为 PyTorch 2.5.1+cu124。安装器因此直接安装同一 tag 下的 editable source extensions，避免无效且不兼容的先升级、再降级。

脚本可以从任意工作目录启动：

```bash
bash /path/to/UniVTAC/scripts/install.sh
```

GPU 空闲时，可以显式运行无头 smoke，启动 Isaac Sim 并加载 TacEx：

```bash
bash scripts/install.sh --gpu-smoke
```

首次启动 Isaac Sim 需要接受 NVIDIA Omniverse EULA。先在交互式终端运行 `isaacsim`
阅读并接受许可证，退出后再为自动 smoke 设置 `ACCEPT_EULA=Y`。安装器不会代替用户接受
许可证。

`--gpu-smoke` 只有在 Kit 创建至少一个 Vulkan/RTX graphics device、随后成功导入
TacEx 和 `tacex_uipc` 并输出最终成功标记时才返回 0。仅有 `nvidia-smi`、CUDA tensor
或 `SimulationApp` 进程 exit 0 不构成通过；日志出现 `Driver Version: 0`、空 GPU 表或
`No device could be created` 会返回非零。

在同时存在根仓 `.venv` 和本 Conda 环境时，用明确路径检查依赖，避免 shell 继续解析到
错误的 Python：

```bash
conda activate UniVTAC
"$CONDA_PREFIX/bin/python" -m pip check
"$CONDA_PREFIX/bin/python" -c 'import uipc; print(uipc.__version__)'
```

安装器只在当前进程导出 vcpkg 路径，不会修改 `~/.bashrc`。如果已有自定义 vcpkg checkout，可以通过 `VCPKG_ROOT=/path/to/vcpkg` 指定。

### `tacex_uipc` / vcpkg 中断恢复

如果首个错误是 `tinygltf` 的 `unexpected hash`，先停止并检查下载归档，不要根据控制台的 `Actual` 值直接关闭或改写完整性校验。2026-08-02 的 GitHub 自动归档变更会让有效的 tinygltf 源码 tarball 与旧 vcpkg port 的 SHA512 不同；同类上游事件见 [microsoft/vcpkg#53143](https://github.com/microsoft/vcpkg/issues/53143)。

只有在 gzip 校验通过、归档内容确认为 tinygltf 源码且 tar 内 Git commit 与 tag 一致后，才可以使用临时 vcpkg overlay 更新该次下载的 SHA512。临时 overlay 不应提交为长期依赖答案，上游恢复后应移除。

如果一次 manifest install 已经失败，`source/tacex_uipc/build/vcpkg.json` 可能存在而 `vcpkg_installed` 仍不完整。libuipc 会因 manifest 内容未变化把 `VCPKG_MANIFEST_INSTALL` 设为 `OFF`，随后以 `Eigen3Config.cmake` 缺失结束。此时不要把错误归因于 GCC/Make；保留失败目录作为证据，并从新的 `source/tacex_uipc/build` 目录重试。安装完成的 vcpkg binary cache 可以复用。

libuipc 构建 pyuipc 时还会调用 `mypy.stubgen`，并在编译后递归执行 pip。安装器固定安装
`mypy==2.3.0`，且让该子进程使用官方 PyPI，避免云端环境提供的不完整镜像缺少 `mypy`
或 `setuptools`。pyuipc wheel 同时包含 stub-only 顶层包和编译扩展；vendored 修订会把
编译模块目录放到搜索路径最前，防止 `import uipc` 误选 stub namespace。

耗时较长的项目检查需要在安装后显式运行：

```bash
conda activate UniVTAC
python -m pytest third_party/curobo
python third_party/TacEx/scripts/reinforcement_learning/skrl/train.py \
  --task TacEx-Ball-Rolling-Tactile-RGB-v0 \
  --num_envs 512 --enable_cameras --livestream 2
bash collect_data.sh grasp_classify demo 0
```

## Manual Installation Instructions

### Requirements

- System: Linux with NVIDIA GPU
- Python 3.10
- NVIDIA Isaac Sim 4.5 + Isaac Lab 2.1.1
- [NVIDIA cuRobo](https://curobo.org)
- [TacEx](https://github.com/DH-Ng/TacEx): **Must be built from the local `third_party/TacEx` source** (contains project-specific modifications)

### Installation & Setup

#### Step 1: Clone the Repository

```bash
git clone https://github.com/univtac/UniVTAC.git
cd UniVTAC
```

#### Step 2: Create a Conda Environment

```bash
conda create -n UniVTAC python=3.10 -y
conda activate UniVTAC
```

#### Step 3: Install cuRobo

cuRobo is used for GPU-accelerated collision-aware motion planning. Follow the official [cuRobo Installation Guide](https://curobo.org/get_started/1_install_instructions.html).

#### Step 4: Install TacEx (Modified Source)

> **Important:** Do **not** install TacEx from the public repository. UniVTAC requires a modified version of TacEx that is bundled in `third_party/TacEx`. Some internal APIs have been adapted for UniVTAC's tactile sensor pipeline.

``` bash
cd third_party/TacEx
```

If you have a working Isaac Lab environment, you can directly install TacEx. Otherwise, **you need to install Isaac Sim 4.5 and Isaac Lab 2.1.1**. Below is a quick summary, but here is the [full installation guide](https://isaac-sim.github.io/IsaacLab/main/source/setup/installation/index.html).

<details>
<summary>Quick summary for Installing Isaac Sim and Isaac Lab for Ubuntu 22.04</summary>

> [!note]
> To install Isaac Sim for Ubuntu 20.04 follow the [binary installation guide](https://isaac-sim.github.io/IsaacLab/main/source/setup/installation/binaries_installation.html).

##### Isaac Sim - Linux pip installation

```bash
# install cuda-enabled pytorch
pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu118
pip install --upgrade pip
# install isaac sim packages
pip install 'isaacsim[all,extscache]==4.5.0' --extra-index-url https://pypi.nvidia.com
```

> verify that the Isaac Sim installation works by calling `isaacsim` in the terminal

###### Isaac Lab

```bash
# install dependencies via apt (Ubuntu)
sudo apt install cmake build-essential
git clone https://github.com/isaac-sim/IsaacLab
cd IsaacLab
# use Isaac Lab version 2.1.1
git checkout v2.1.1
# activate the Isaac Sim python env
conda activate UniVTAC
# install isaaclab extensions (with --editable flag)
./isaaclab.sh --install # or "./isaaclab.sh -i"
```

To verify the Isaac Lab Installation:

```bash
conda activate UniVTAC
python scripts/reinforcement_learning/rsl_rl/train.py --task=Isaac-Ant-v0 --headless
```

</details>

##### Installing TacEx [Core]

**1.** Activate the Isaac Env
```bash
conda activate UniVTAC
```

**2.** Install the core packages of TacEx
```bash
# Script will pip install core TacEx packages with --editable flag)
./tacex.sh -i
```

> You can install the extensions one by one via e.g. `python -m pip install -e source/tacex_uipc`

**3.** Verify that TacEx works by running an example:

```bash
python ./scripts/demos/tactile_sim_approaches/check_taxim_sim.py --debug_vis
```

And here is an RL example:
```bash
python ./scripts/reinforcement_learning/skrl/train.py --task TacEx-Ball-Rolling-Tactile-RGB-v0 --num_envs 512 --enable_cameras
```
> You can view the sensor output in the IsaacLab Tab: `Scene Debug Visualization > Observations > sensor_output`

##### Installing TacEx [UIPC]
The `tacex_uipc` package is responsible for the [UIPC](https://spirimirror.github.io/libuipc-doc/) simulation in TacEx.

**1.** Install the [libuipc dependencies](https://spirimirror.github.io/libuipc-doc/build_install/linux/):
* If not installed yet, install Vcpkg

```bash
mkdir ~/Toolchain
cd ~/Toolchain
git clone https://github.com/microsoft/vcpkg.git
cd vcpkg
./bootstrap-vcpkg.sh -disableMetrics
```

* Set the System Environment Variable  `CMAKE_TOOLCHAIN_FILE` to let CMake detect Vcpkg. If you installed it like above, you can do this:

```bash
# Write in ~/.bashrc
export CMAKE_TOOLCHAIN_FILE="$HOME/Toolchain/vcpkg/scripts/buildsystems/vcpkg.cmake"
```

* We also need `CMake 3.26`, `GCC 11.4` and `Cuda 12.4` to build libuipc. Install this into the Isaac Sim python env:

```bash
# Inside the root dir of TacEx repo
conda activate UniVTAC
conda env update -n UniVTAC --file ./source/tacex_uipc/libuipc/conda/env.yaml
```
> If Cuda 12.4 does not work for, try updating your Nvidia drivers or try to use an older Cuda version by adjusting the env.yaml file (e.g. Cuda 12.2).

**2.** Install `tacex_uipc`
```bash
# This also builds `libuipc` and pip installs the python bindings.
conda activate UniVTAC
pip install -e source/tacex_uipc -v
```
> You can also install all TacEx packages with `./tacex.sh -i all`.

**3.** Verify that the `tacex_uipc` works by running a data collection example:

```bash
bash collect_data.sh grasp_classify demo 0
```
