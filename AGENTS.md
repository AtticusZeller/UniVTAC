# UniVTAC Repository Guide

- Treat this repository as a visuo-tactile simulation and manipulation benchmark
  built on NVIDIA Isaac Lab and the bundled, project-specific TacEx source.
- Keep task implementations under `envs/`, collection and evaluation mechanics
  under `scripts/`, and policy-specific code under `policy/`.
- Preserve the supported environment boundary: Linux, Python 3.10, Isaac Sim 4.5,
  Isaac Lab 2.1.1, cuRobo, and `third_party/TacEx`. Do not replace the bundled TacEx
  with its public upstream without validating UniVTAC's modified tactile APIs.
- Use the repository's shell entry points for collection and evaluation. Record
  workspace-level experiment configuration and evidence in the parent
  `vla-post-train` repository rather than duplicating orchestration here.
- Keep datasets, checkpoints, generated videos, evaluation results, simulator
  installations, and other large artifacts out of Git.
- Before changing a task, read `docs/TaskCreation.md`; before changing setup,
  collection, or deployment behavior, read the corresponding guide under `docs/`.
