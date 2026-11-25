"""Convert our PS4 definition (ps4_model.py) plus the released weights to Core ML.

Two models come out:
    PS4Embed.mlpackage    enroll wav (1, 160000) 16 kHz, 10 s  ->  speaker embedding (1, 192)
    PS4Extract.mlpackage  mix wav (1, N), embedding (1, 192)    ->  target wav (1, N)
                          N is one of LENGTHS (seconds * 16000); pad up to the next one.

torch.stft / torch.istft do not convert, so this file rewrites them as fixed
convolutions with DFT kernels (STFT = conv1d, iSTFT = conv_transpose1d plus the
window-square envelope). `check()` compares them with ps4_model.PS4.forward.

Run (in a throwaway venv with torch, torchaudio, coremltools, numpy, soundfile):
    python -I export_coreml.py --ckpt <checkpoint_epoch037.pt> --out <dir> [--check-wav <wav>]

The checkpoint is a pickle; it is opened with torch.load(weights_only=True) only.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ps4_model import PS4, build_ps4  # noqa: E402

LENGTHS = [1, 2, 4, 6, 8, 12, 16, 24, 32]  # seconds
ENROLL_SAMPLES = 160_000


def load_weights(ckpt: str) -> PS4:
    ck = torch.load(ckpt, map_location="cpu", weights_only=True)
    sd = ck.get("model", ck.get("state_dict", ck)) if isinstance(ck, dict) else ck
    sd = {k[7:] if k.startswith("module.") else k: v for k, v in sd.items()}
    m = build_ps4()
    m.load_state_dict(sd, strict=True)
    return m.eval()


def dft_kernels(n_fft: int, window: torch.Tensor):
    """Forward kernels (2*bins, 1, n_fft): rows 0..bins-1 give the real part, the rest the imaginary part."""
    bins = n_fft // 2 + 1
    n = torch.arange(n_fft, dtype=torch.float64)
    k = torch.arange(bins, dtype=torch.float64)[:, None]
    ang = 2 * math.pi * k * n / n_fft
    w = window.double()
    fwd = torch.cat([torch.cos(ang) * w, -torch.sin(ang) * w], 0)[:, None, :]
    # Inverse (onesided irfft, times the synthesis window), for conv_transpose1d: (2*bins, 1, n_fft)
    c = torch.full((bins, 1), 2.0, dtype=torch.float64)
    c[0] = 1.0
    c[-1] = 1.0
    inv = torch.cat([c * torch.cos(ang), -c * torch.sin(ang)], 0) / n_fft * w
    return fwd.float(), inv[:, None, :].float()


class ConvSTFT(nn.Module):
    """torch.stft(center=True, reflect pad, onesided) as a conv1d. Returns (B, 2, bins, frames)."""

    def __init__(self, n_fft: int, hop: int, window: torch.Tensor):
        super().__init__()
        self.n_fft, self.hop, self.bins = n_fft, hop, n_fft // 2 + 1
        fwd, _ = dft_kernels(n_fft, window)
        self.register_buffer("kernel", fwd)

    def forward(self, wav):  # (1, T)
        x = F.pad(wav[:, None, :], (self.n_fft // 2, self.n_fft // 2), mode="reflect")
        y = F.conv1d(x, self.kernel, stride=self.hop)  # (1, 2*bins, frames)
        return y.reshape(1, 2, self.bins, -1)


class ConvISTFT(nn.Module):
    """torch.istft(center=True) as conv_transpose1d, divided by the overlapped window-square."""

    def __init__(self, n_fft: int, hop: int, window: torch.Tensor):
        super().__init__()
        self.n_fft, self.hop = n_fft, hop
        _, inv = dft_kernels(n_fft, window)
        self.register_buffer("kernel", inv)
        self.register_buffer("wsq", (window.float() ** 2)[None, None, :])

    def forward(self, ri):  # ri (B, 2*bins, frames) -> (B, hop * (frames - 1)), the input length for T % hop == 0
        y = F.conv_transpose1d(ri, self.kernel, stride=self.hop)
        ones = torch.ones_like(ri[:, :1, :])
        env = F.conv_transpose1d(ones, self.wsq, stride=self.hop)
        y = y / env.clamp(min=1e-8)
        half = self.n_fft // 2
        return y[:, 0, half:-half]


def res_rnn(r, x):
    """ps4_model.ResRNN.forward with GroupNorm(1, C) written out (Core ML cannot take a dynamic batch there)."""
    mu = x.mean(dim=(1, 2), keepdim=True)
    var = ((x - mu) ** 2).mean(dim=(1, 2), keepdim=True)
    h = (x - mu) / torch.sqrt(var + r.norm.eps) * r.norm.weight[None, :, None] + r.norm.bias[None, :, None]
    h, _ = r.rnn(h.transpose(1, 2))
    return x + r.proj(h).transpose(1, 2)


class PS4Extract(nn.Module):
    """Our PS4 separator with the STFT/iSTFT as convolutions and the embedding as an input."""

    def __init__(self, m: PS4):
        super().__init__()
        self.m = m
        self.stft = ConvSTFT(m.win, m.stride, m.stft_window)
        self.istft = ConvISTFT(m.win, m.stride, m.stft_window)

    def forward(self, mix, emb):
        """Batch 1, no shape reads (Core ML cannot cast traced sizes). mix length must be a multiple of 128."""
        m = self.m
        ri = self.stft(mix)  # (1, 2, bins, frames)
        feats, start = [], 0
        for w, bn in zip(m.band_width, m.BN):
            feats.append(bn(ri[:, :, start:start + w].reshape(1, 2 * w, -1)))
            start += w
        x = m.separator.separation[0](torch.stack(feats, 1), emb)  # (1, nband, dim, frames)
        nb, d = m.nband, m.feature_dim
        for blk in m.separator.separation[1:]:
            y = res_rnn(blk.band_rnn, x.reshape(nb, d, -1))  # along time, per band
            y = y.permute(2, 1, 0)  # (frames, dim, nband)
            y = res_rnn(blk.band_comm, y)  # across bands, per frame
            x = y.permute(2, 1, 0).reshape(1, nb, d, -1)
        res, ims, start = [], [], 0
        for i, (w, head) in enumerate(zip(m.band_width, m.mask)):
            mk = head(x[:, i]).reshape(1, 2, 2, w, -1)
            mk = mk[:, 0] * torch.sigmoid(mk[:, 1])
            br, bi = ri[:, 0, start:start + w], ri[:, 1, start:start + w]
            res.append(br * mk[:, 0] - bi * mk[:, 1])
            ims.append(br * mk[:, 1] + bi * mk[:, 0])
            start += w
        est = torch.cat([torch.cat(res, 1), torch.cat(ims, 1)], 1)  # (1, 2*bins, frames)
        return self.istft(est)


class PS4Embed(nn.Module):
    """Pre-emphasis, 80-bin log-mel (the checkpoint's own mel filterbank), mean norm, ECAPA-TDNN."""

    def __init__(self, m: PS4):
        super().__init__()
        self.m = m
        spec = m.spk_encoder.spectrogram
        self.stft = ConvSTFT(spec.n_fft, spec.hop_length, spec.window)
        self.register_buffer("fb", m.spk_encoder.mel_scale.fb.clone())  # (bins, mels)

    def forward(self, enroll):
        x = self.m.preEmphasis(enroll)
        ri = self.stft(x)
        power = ri[:, 0] ** 2 + ri[:, 1] ** 2  # (B, bins, frames)
        mel = torch.matmul(power.transpose(1, 2), self.fb)  # (B, frames, mels)
        f = torch.log(mel + 1e-8)
        f = f - f.mean(dim=1, keepdim=True)
        return self.m.spk_model(f)


def sisdr(est, ref):
    est = est - est.mean()
    ref = ref - ref.mean()
    t = np.dot(est, ref) / (np.dot(ref, ref) + 1e-12) * ref
    return 10 * np.log10(np.dot(t, t) / (np.dot(est - t, est - t) + 1e-12))


def check(m: PS4, wav: np.ndarray):
    """Conv-STFT graph vs ps4_model.PS4.forward on the same audio."""
    ext, emb = PS4Extract(m).eval(), PS4Embed(m).eval()
    with torch.inference_mode():
        x = torch.from_numpy(wav[None, :48000].astype(np.float32))
        e = torch.from_numpy(np.resize(wav, ENROLL_SAMPLES)[None].astype(np.float32))
        ref_emb = m.embed(e)
        my_emb = emb(e)
        ref = m(x, e)[0].numpy()
        mine = ext(x, ref_emb)[0].numpy()
    cos = F.cosine_similarity(ref_emb, my_emb).item()
    print(f"check: embedding cosine {cos:.6f}, extract SI-SDR vs torch.stft path {sisdr(mine, ref):.1f} dB")
    return cos, sisdr(mine, ref)


def convert(m: PS4, out: str, precision: str):
    import coremltools as ct

    prec = ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32
    os.makedirs(out, exist_ok=True)
    emb = PS4Embed(m).eval()
    with torch.inference_mode():
        ts = torch.jit.trace(emb, torch.randn(1, ENROLL_SAMPLES) * 0.1)
    ml = ct.convert(ts, inputs=[ct.TensorType("enroll", shape=(1, ENROLL_SAMPLES))],
                    outputs=[ct.TensorType("embedding")], convert_to="mlprogram",
                    compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS14)
    ml.short_description = "PS4 speaker embedding (Ning et al., Apache-2.0); our definition"
    ml.save(os.path.join(out, "PS4Embed.mlpackage"))

    ext = PS4Extract(m).eval()
    shapes = [(1, s * 16000) for s in LENGTHS]
    with torch.inference_mode():
        ts = torch.jit.trace(ext, (torch.randn(1, 32000) * 0.1, torch.randn(1, 192)))
    ml = ct.convert(ts, inputs=[ct.TensorType("mix", shape=ct.EnumeratedShapes(shapes=shapes, default=shapes[2])),
                                ct.TensorType("embedding", shape=(1, 192))],
                    outputs=[ct.TensorType("target")], convert_to="mlprogram",
                    compute_precision=prec, minimum_deployment_target=ct.target.macOS14)
    ml.short_description = "PS4 target speaker extraction (Ning et al., Apache-2.0); our definition"
    ml.save(os.path.join(out, f"PS4Extract-{precision}.mlpackage"))
    print("saved to", out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--check-wav")
    ap.add_argument("--precision", default="fp16", choices=["fp16", "fp32"])
    ap.add_argument("--no-convert", action="store_true")
    a = ap.parse_args()
    model = load_weights(a.ckpt)
    if a.check_wav:
        import soundfile as sf
        w, sr = sf.read(a.check_wav, dtype="float32")
        assert sr == 16000
        check(model, w if w.ndim == 1 else w.mean(1))
    if not a.no_convert:
        convert(model, a.out, a.precision)
