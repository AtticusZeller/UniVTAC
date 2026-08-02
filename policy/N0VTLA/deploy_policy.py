"""UniVTAC policy adapter for the remote N0-VTLA ZMQ inference server."""

from __future__ import annotations

import logging
import os
import time

import cv2
import msgpack
import numpy as np
import torch
import zmq

from .._base_policy import BasePolicy


class Policy(BasePolicy):
    """Send UniVTAC observations to N0-VTLA and execute full action chunks."""

    def __init__(self, args: dict) -> None:
        self.server_addr = os.environ.get(
            "N0VTLA_ZMQ_ADDR", str(args.get("server_addr", "tcp://127.0.0.1:5557"))
        )
        self.prompt = str(args.get("prompt", "insert hole"))
        self.timeout_ms = int(args.get("timeout_ms", 300_000))
        self.expected_horizon = int(args.get("expected_horizon", 50))
        self.raw_action_dim = int(args.get("raw_action_dim", 8))

        self._context = zmq.Context()
        self._socket = self._context.socket(zmq.REQ)
        self._socket.setsockopt(zmq.LINGER, 0)
        self._socket.setsockopt(zmq.SNDTIMEO, self.timeout_ms)
        self._socket.setsockopt(zmq.RCVTIMEO, self.timeout_ms)
        self._socket.connect(self.server_addr)
        self._server_infer_ms: list[float] = []
        self._roundtrip_ms: list[float] = []
        logging.info("N0-VTLA client connected to %s", self.server_addr)

    @staticmethod
    def _uint8_hwc(value: torch.Tensor | np.ndarray) -> np.ndarray:
        """Convert a simulator image to contiguous RGB uint8 HWC."""
        if isinstance(value, torch.Tensor):
            array = value.detach().cpu().numpy()
        else:
            array = np.asarray(value)
        if array.ndim == 3 and array.shape[0] in (1, 3) and array.shape[-1] not in (1, 3):
            array = np.transpose(array, (1, 2, 0))
        if np.issubdtype(array.dtype, np.floating):
            if array.size and float(np.nanmax(array)) <= 1.0:
                array = array * 255.0
            array = np.clip(array, 0, 255)
        array = np.ascontiguousarray(array, dtype=np.uint8)
        if array.ndim != 3 or array.shape[-1] != 3:
            raise ValueError(f"expected an RGB HWC image, got {array.shape}")
        return array

    @classmethod
    def _png(cls, value: torch.Tensor | np.ndarray) -> bytes:
        """Encode one RGB frame as PNG for the ZMQ wire protocol."""
        rgb = cls._uint8_hwc(value)
        ok, encoded = cv2.imencode(".png", rgb[..., ::-1])
        if not ok:
            raise ValueError("failed to encode RGB frame as PNG")
        return encoded.tobytes()

    def _request(self, payload: dict) -> dict:
        """Perform one REQ/REP exchange and validate the reply envelope."""
        try:
            self._socket.send(msgpack.packb(payload, use_bin_type=True))
            reply = msgpack.unpackb(self._socket.recv(), raw=False)
        except zmq.ZMQError as exc:
            raise RuntimeError(f"N0-VTLA ZMQ request to {self.server_addr} failed: {exc}") from exc
        if not isinstance(reply, dict):
            raise RuntimeError(f"N0-VTLA returned a non-mapping reply: {type(reply).__name__}")
        if reply.get("status") != "ok":
            raise RuntimeError(f"N0-VTLA inference failed: {reply.get('message', reply)}")
        return reply

    def _encode_observation(self, observation: dict) -> dict:
        """Map the UniVTAC single-arm observation onto the N0-VTLA wire schema."""
        state = observation["embodiment"]["joint"][: self.raw_action_dim]
        if isinstance(state, torch.Tensor):
            state = state.detach().cpu().numpy()
        state = np.asarray(state, dtype=np.float32).reshape(-1)
        if state.shape != (self.raw_action_dim,):
            raise ValueError(
                f"expected {self.raw_action_dim} joint values, got shape {state.shape}"
            )

        return {
            "cmd": "predict",
            "state": state.tolist(),
            "prompt": self.prompt,
            "observation/image": self._png(observation["observation"]["head"]["rgb"]),
            "observation/wrist_image": self._png(observation["observation"]["wrist"]["rgb"]),
            "observation/left_tactile": self._png(
                observation["tactile"]["left_tactile"]["rgb_marker"]
            ),
            "observation/right_tactile": self._png(
                observation["tactile"]["right_tactile"]["rgb_marker"]
            ),
        }

    def eval(self, task, observation: dict) -> None:
        """Request one chunk and execute every action unless the episode terminates."""
        started = time.perf_counter()
        reply = self._request(self._encode_observation(observation))
        roundtrip_ms = (time.perf_counter() - started) * 1000.0
        actions = np.asarray(reply["actions"], dtype=np.float32)
        if actions.shape != (self.expected_horizon, 32):
            raise ValueError(
                "unexpected N0-VTLA action shape: "
                f"{actions.shape}, expected {(self.expected_horizon, 32)}"
            )
        if not np.isfinite(actions).all():
            raise ValueError("N0-VTLA returned non-finite actions")

        server_ms = float(reply.get("infer_time_ms", float("nan")))
        self._server_infer_ms.append(server_ms)
        self._roundtrip_ms.append(roundtrip_ms)
        logging.info(
            "N0-VTLA chunk %d: server=%.1f ms roundtrip=%.1f ms",
            len(self._roundtrip_ms),
            server_ms,
            roundtrip_ms,
        )

        for action in actions[:, : self.raw_action_dim]:
            action_tensor = torch.as_tensor(action, device=task.device, dtype=torch.float32)
            _, success = task.take_action(action_tensor, action_type="qpos")
            if success or task.take_action_cnt >= task.cfg.step_lim:
                break

    def reset(self) -> None:
        """Reset the server's per-episode tactile baseline."""
        self._request({"cmd": "reset"})

    def close(self) -> None:
        """Close the transport and report aggregate request latency."""
        if self._roundtrip_ms:
            logging.info(
                "N0-VTLA latency over %d chunks: server_mean=%.1f ms roundtrip_mean=%.1f ms",
                len(self._roundtrip_ms),
                float(np.nanmean(self._server_infer_ms)),
                float(np.mean(self._roundtrip_ms)),
            )
        self._socket.close(linger=0)
        self._context.term()
