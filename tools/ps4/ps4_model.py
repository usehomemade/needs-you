"""Our own PyTorch definition of the PS4 target-speaker-extraction model.

Status (24 Nov 2026): loads the released checkpoint_epoch037.pt with strict=True
(754 keys, no missing, extra or mis-shaped keys; no changes were needed). In the app it sits behind Settings -> Models, default off.

Shape of the model (16 kHz mono):
    mixture (B, T)  --STFT-->  split into 32 frequency bands  --per-band norm+1x1 conv-->
    (B, 32, 128, frames)  --speaker gate (multiply)-->  6 x BSNet (band RNN + band-comm RNN)
    --per-band mask head-->  complex mask on the mixture STFT  --iSTFT-->  target wav (B, T)

    enrollment (B, T_e) --pre-emphasis--> 80-bin log-mel fbank --ECAPA-TDNN--> 192-d embedding

Upstream: PS4 (Ning et al.), Apache-2.0. This file is a separate implementation.

STATE_DICT_NOTES
================
Parameter and buffer names below were chosen to equal the upstream checkpoint
keys, so `model.load_state_dict(sd, strict=True)` can work once approved.

Top-level key prefixes expected in the model state dict:
    BN.<0..31>.0.*              GroupNorm of each band (weight, bias)
    BN.<0..31>.1.*              1x1 Conv1d of each band (weight, bias)
    separator.separation.0.fc.linear.{weight,bias}
                                speaker gate (Linear 192 -> 128)
    separator.separation.<1..6>.band_rnn.{norm,rnn,proj}.*
    separator.separation.<1..6>.band_comm.{norm,rnn,proj}.*
                                the six BSNet blocks (ResRNN = GroupNorm + 1-layer BiLSTM + Linear)
    mask.<0..31>.{0,1,3,5}.*    mask head per band (GroupNorm, Conv, Conv, Conv; indexes 2 and 4 are Tanh)
    spk_model.layer1.{conv,bn}.*
    spk_model.layer{2,3,4}.se_res2block.{0,1,2,3}.*
    spk_model.conv.*  spk_model.pool.{linear1,linear2}.*
    spk_model.bn.*    spk_model.linear.*
                                ECAPA-TDNN speaker encoder (frozen in upstream training)
    preEmphasis.flipped_filter  buffer, shape (1, 1, 2)
    spk_encoder.spectrogram.window, spk_encoder.mel_scale.fb
                                torchaudio MelSpectrogram buffers (persistent in torchaudio)

Not in the state dict: spk_transform, pred_linear (both nn.Identity in this
config); our STFT window buffers are registered non-persistent.

Prefix stripping a loader may need (checked: the weights are under ckpt["model"], no module. prefix):
  * The upstream script reads ckpt["model"] if present, else ckpt["state_dict"], else the
    object itself. Do the same.
  * If keys start with "module." (DataParallel/DDP), strip that prefix first.
  * Upstream loads with strict=False, so extra keys (for example a pred_linear.* head or
    num_batches_tracked entries) may exist. Compare the key sets before using strict=True.
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio

EPS = torch.finfo(torch.float32).eps


# ---------------------------------------------------------------------------
# Speaker encoder front end
# ---------------------------------------------------------------------------

class PreEmphasis(nn.Module):
    """y[t] = x[t] - coef * x[t-1], with a reflect pad on the left."""

    def __init__(self, coef: float = 0.97):
        super().__init__()
        self.register_buffer("flipped_filter", torch.tensor([[[-coef, 1.0]]]))

    def forward(self, wav: torch.Tensor) -> torch.Tensor:  # (B, T) -> (B, T)
        x = F.pad(wav.unsqueeze(1), (1, 0), mode="reflect")
        return F.conv1d(x, self.flipped_filter).squeeze(1)


# ---------------------------------------------------------------------------
# ECAPA-TDNN (512 channels, global-context attentive pooling)
# ---------------------------------------------------------------------------

class ConvReluBn(nn.Module):
    """Conv1d, then ReLU, then BatchNorm (this order, as in the checkpoint's model)."""

    def __init__(self, c_in: int, c_out: int, k: int = 1, padding: int = 0, dilation: int = 1):
        super().__init__()
        self.conv = nn.Conv1d(c_in, c_out, k, 1, padding, dilation)
        self.bn = nn.BatchNorm1d(c_out)

    def forward(self, x):
        return self.bn(F.relu(self.conv(x)))


class Res2ConvReluBn(nn.Module):
    """Multi-scale conv: the channels are split in `scale` groups, chained through small convs."""

    def __init__(self, channels: int, k: int, padding: int, dilation: int, scale: int):
        super().__init__()
        assert channels % scale == 0
        self.scale = scale
        self.width = channels // scale
        self.nums = scale - 1
        self.convs = nn.ModuleList(
            [nn.Conv1d(self.width, self.width, k, 1, padding, dilation) for _ in range(self.nums)]
        )
        self.bns = nn.ModuleList([nn.BatchNorm1d(self.width) for _ in range(self.nums)])

    def forward(self, x):
        groups = torch.split(x, self.width, dim=1)
        outs = []
        carry = groups[0]
        for i in range(self.nums):
            if i > 0:
                carry = carry + groups[i]
            carry = self.bns[i](F.relu(self.convs[i](carry)))
            outs.append(carry)
        outs.append(groups[self.nums])
        return torch.cat(outs, dim=1)


class SEConnect(nn.Module):
    """Squeeze-and-excitation over channels."""

    def __init__(self, channels: int, bottleneck: int = 128):
        super().__init__()
        self.linear1 = nn.Linear(channels, bottleneck)
        self.linear2 = nn.Linear(bottleneck, channels)

    def forward(self, x):
        s = x.mean(dim=2)
        s = torch.sigmoid(self.linear2(F.relu(self.linear1(s))))
        return x * s.unsqueeze(2)


class SERes2Block(nn.Module):
    def __init__(self, channels: int, k: int, padding: int, dilation: int, scale: int):
        super().__init__()
        self.se_res2block = nn.Sequential(
            ConvReluBn(channels, channels, 1),
            Res2ConvReluBn(channels, k, padding, dilation, scale),
            ConvReluBn(channels, channels, 1),
            SEConnect(channels),
        )

    def forward(self, x):
        return x + self.se_res2block(x)


class ASTP(nn.Module):
    """Attentive statistics pooling with global context (mean/std of the whole clip fed to the attention)."""

    def __init__(self, in_dim: int, bottleneck: int = 128):
        super().__init__()
        self.in_dim = in_dim
        self.linear1 = nn.Conv1d(in_dim * 3, bottleneck, 1)
        self.linear2 = nn.Conv1d(bottleneck, in_dim, 1)

    def forward(self, x):  # (B, C, T) -> (B, 2C)
        g_mean = x.mean(dim=-1, keepdim=True).expand_as(x)
        g_std = torch.sqrt(x.var(dim=-1, keepdim=True) + 1e-7).expand_as(x)
        att = torch.tanh(self.linear1(torch.cat([x, g_mean, g_std], dim=1)))
        att = torch.softmax(self.linear2(att), dim=2)
        mean = (att * x).sum(dim=2)
        var = (att * x * x).sum(dim=2) - mean * mean
        return torch.cat([mean, var.clamp(min=1e-7).sqrt()], dim=1)


class EcapaTdnn(nn.Module):
    def __init__(self, feat_dim: int = 80, embed_dim: int = 192, channels: int = 512):
        super().__init__()
        self.layer1 = ConvReluBn(feat_dim, channels, 5, padding=2)
        self.layer2 = SERes2Block(channels, 3, padding=2, dilation=2, scale=8)
        self.layer3 = SERes2Block(channels, 3, padding=3, dilation=3, scale=8)
        self.layer4 = SERes2Block(channels, 3, padding=4, dilation=4, scale=8)
        self.conv = nn.Conv1d(channels * 3, 512 * 3, 1)
        self.pool = ASTP(512 * 3)
        self.bn = nn.BatchNorm1d(2 * 512 * 3)
        self.linear = nn.Linear(2 * 512 * 3, embed_dim)

    def forward(self, feats: torch.Tensor) -> torch.Tensor:  # (B, T, F) -> (B, embed_dim)
        x = feats.permute(0, 2, 1)
        x1 = self.layer1(x)
        x2 = self.layer2(x1)
        x3 = self.layer3(x2)
        x4 = self.layer4(x3)
        x = F.relu(self.conv(torch.cat([x2, x3, x4], dim=1)))
        return self.linear(self.bn(self.pool(x)))


# ---------------------------------------------------------------------------
# Separation backbone
# ---------------------------------------------------------------------------

class SpeakerGate(nn.Module):
    """'multiply' fusion: a linear map of the embedding scales every feature channel.

    The attribute path (fc.linear) matches the checkpoint. The embedding is the same
    for every band and frame, so we apply the linear map once and broadcast.
    """

    class _Fc(nn.Module):
        def __init__(self, n_in: int, n_out: int):
            super().__init__()
            self.linear = nn.Linear(n_in, n_out)

        def forward(self, x):
            return self.linear(x)

    def __init__(self, embed_dim: int, feat_dim: int):
        super().__init__()
        self.fc = SpeakerGate._Fc(embed_dim, feat_dim)

    def forward(self, x: torch.Tensor, emb: torch.Tensor) -> torch.Tensor:
        # x: (B, bands, feat, T), emb: (B, embed_dim)
        return x * self.fc(emb)[:, None, :, None]


class ResRNN(nn.Module):
    """GroupNorm, one BiLSTM layer, projection back, residual add. Input (B, C, L)."""

    def __init__(self, dim: int, hidden: int):
        super().__init__()
        self.norm = nn.GroupNorm(1, dim, EPS)
        self.rnn = nn.LSTM(dim, hidden, 1, batch_first=True, bidirectional=True)
        self.proj = nn.Linear(hidden * 2, dim)

    def forward(self, x):
        h, _ = self.rnn(self.norm(x).transpose(1, 2))
        return x + self.proj(h).transpose(1, 2)


class BSNet(nn.Module):
    """One RNN pass along time inside each band, then one across bands at each frame."""

    def __init__(self, nband: int, dim: int):
        super().__init__()
        self.nband = nband
        self.dim = dim
        self.band_rnn = ResRNN(dim, dim * 2)
        self.band_comm = ResRNN(dim, dim * 2)

    def forward(self, x):  # (B, nband*dim, T)
        B, _, T = x.shape
        y = self.band_rnn(x.reshape(B * self.nband, self.dim, T))  # time axis
        y = y.reshape(B, self.nband, self.dim, T).permute(0, 3, 2, 1)  # (B, T, dim, nband)
        y = self.band_comm(y.reshape(B * T, self.dim, self.nband))  # band axis
        y = y.reshape(B, T, self.dim, self.nband).permute(0, 3, 2, 1)  # (B, nband, dim, T)
        return y.reshape(B, self.nband * self.dim, T)


class Separator(nn.Module):
    """Speaker gate once, then `num_repeat` BSNets (index 0 = gate, 1..N = BSNets)."""

    def __init__(self, nband: int, dim: int, embed_dim: int, num_repeat: int):
        super().__init__()
        self.nband = nband
        self.dim = dim
        blocks = [SpeakerGate(embed_dim, dim)] + [BSNet(nband, dim) for _ in range(num_repeat)]
        self.separation = nn.ModuleList(blocks)

    def forward(self, feats: torch.Tensor, emb: torch.Tensor) -> torch.Tensor:
        B, _, _, T = feats.shape
        x = self.separation[0](feats, emb).reshape(B, self.nband * self.dim, T)
        for block in self.separation[1:]:
            x = block(x)
        return x.reshape(B, self.nband, self.dim, T)


# ---------------------------------------------------------------------------
# Full model
# ---------------------------------------------------------------------------

def _band_widths(sr: int, n_bins: int) -> list[int]:
    nyq = sr / 2.0

    def bins(hz: int) -> int:
        return int(hz / nyq * n_bins)  # floor for positive values

    widths = [bins(100)] * 15 + [bins(200)] * 10 + [bins(500)] * 5 + [bins(2000)]
    widths.append(n_bins - sum(widths))
    return widths


class PS4(nn.Module):
    def __init__(
        self,
        sr: int = 16000,
        win: int = 512,
        stride: int = 128,
        feature_dim: int = 128,
        num_repeat: int = 6,
        spk_emb_dim: int = 192,
        fbank_dim: int = 80,
    ):
        super().__init__()
        self.win = win
        self.stride = stride
        self.feature_dim = feature_dim
        self.n_bins = win // 2 + 1
        self.band_width = _band_widths(sr, self.n_bins)  # 32 bands for the shipped config
        self.nband = len(self.band_width)

        # Speaker branch: waveform -> fbank -> embedding.
        self.preEmphasis = PreEmphasis()
        self.spk_encoder = torchaudio.transforms.MelSpectrogram(
            sample_rate=sr, n_fft=win, win_length=win, hop_length=stride,
            f_min=20, window_fn=torch.hamming_window, n_mels=fbank_dim,
        )
        self.spk_model = EcapaTdnn(fbank_dim, spk_emb_dim)

        # Per-band input stage.
        self.BN = nn.ModuleList(
            nn.Sequential(nn.GroupNorm(1, w * 2, EPS), nn.Conv1d(w * 2, feature_dim, 1))
            for w in self.band_width
        )
        self.separator = Separator(self.nband, feature_dim, spk_emb_dim, num_repeat)

        # Per-band mask head: outputs 4 * width channels (2 x 2 grid of mask parts).
        self.mask = nn.ModuleList(
            nn.Sequential(
                nn.GroupNorm(1, feature_dim, EPS),
                nn.Conv1d(feature_dim, feature_dim * 4, 1),
                nn.Tanh(),
                nn.Conv1d(feature_dim * 4, feature_dim * 4, 1),
                nn.Tanh(),
                nn.Conv1d(feature_dim * 4, w * 4, 1),
            )
            for w in self.band_width
        )

        self.register_buffer("stft_window", torch.hann_window(win), persistent=False)

    # -- speaker embedding ------------------------------------------------
    def embed(self, enroll: torch.Tensor) -> torch.Tensor:
        """enroll (B, T_e) -> (B, 192)."""
        with torch.no_grad():
            f = self.spk_encoder(self.preEmphasis(enroll)) + 1e-8
            f = f.log()
            f = f - f.mean(dim=-1, keepdim=True)  # per-utterance mean norm over time
            f = f.permute(0, 2, 1)  # (B, frames, mels)
        return self.spk_model(f)

    # -- main -------------------------------------------------------------
    def forward(self, mix: torch.Tensor, enroll: torch.Tensor) -> torch.Tensor:
        """mix (B, T), enroll (B, T_e), both 16 kHz in [-1, 1] -> target wav (B, T)."""
        B, n = mix.shape
        spec = torch.stft(mix, n_fft=self.win, hop_length=self.stride,
                          window=self.stft_window, return_complex=True)  # (B, bins, frames)
        ri = torch.stack([spec.real, spec.imag], dim=1)  # (B, 2, bins, frames)

        feats, start = [], 0
        for w, bn in zip(self.band_width, self.BN):
            band = ri[:, :, start:start + w].reshape(B, 2 * w, -1)
            feats.append(bn(band))
            start += w
        feats = torch.stack(feats, dim=1)  # (B, nband, feat, frames)

        out = self.separator(feats, self.embed(enroll))

        pieces, start = [], 0
        for i, (w, head) in enumerate(zip(self.band_width, self.mask)):
            m = head(out[:, i]).reshape(B, 2, 2, w, -1)
            m = m[:, 0] * torch.sigmoid(m[:, 1])  # (B, 2[re,im], w, frames)
            band = spec[:, start:start + w]
            re = band.real * m[:, 0] - band.imag * m[:, 1]
            im = band.real * m[:, 1] + band.imag * m[:, 0]
            pieces.append(torch.complex(re, im))
            start += w

        est = torch.cat(pieces, dim=1)
        return torch.istft(est, n_fft=self.win, hop_length=self.stride,
                           window=self.stft_window, length=n)


def build_ps4() -> PS4:
    """The configuration of the released PS4 checkpoint (epoch 37). Returns an eval-mode model
    with random weights. Does not load anything."""
    model = PS4(sr=16000, win=512, stride=128, feature_dim=128, num_repeat=6,
                spk_emb_dim=192, fbank_dim=80)
    model.eval()
    return model
