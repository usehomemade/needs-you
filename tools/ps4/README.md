# PS4 (target speaker extraction)

PS4 pulls one enrolled speaker's voice out of a mixed recording. It is a BSRNN separator plus an ECAPA-TDNN speaker encoder, at 16 kHz.

## Status (24 Nov 2026)

- `ps4_model.py` is our own PyTorch definition. It loads the released weights with `strict=True` as written: 754 keys, none missing, none extra, no shape mismatches.
- `export_coreml.py` converts it to Core ML. STFT and iSTFT stay inside the graph as fixed DFT convolutions. Its `check()` matches the `torch.stft` path at 124 dB SI-SDR, and the speaker embedding at cosine 1.0.
- In the app it is Settings → Models → **Voice extraction (PS4, experimental)**, off by default. When on, every transcription pass runs on the extracted voice except the quick Parakeet "done" checks. If the output comes back more than 30 dB quieter than the input, the original audio is kept (`ps4:` lines in `audio.log`).
- Nothing from the upstream repo was run. Only the weights file was downloaded, and it was opened with `torch.load(weights_only=True)`.

## Weights

- URL: https://huggingface.co/TaurenMountain/PS4/resolve/main/checkpoint_epoch037.pt
- 282,746,518 bytes, SHA-256 `3d5621c89e4af7d6a42180604aa191962636826b244c86cc3ac5bc2508064196` (matches the Hub LFS oid)
- Not committed. The Core ML files go to `~/Library/Application Support/Needs You/models/ps4/`.

## Rebuild the Core ML models

```bash
uv venv --python 3.12 ~/tmp/ps4-venv
VIRTUAL_ENV=~/tmp/ps4-venv uv pip install torch==2.7.0 torchaudio==2.7.0 coremltools numpy soundfile
mkdir -p ~/tmp/ps4-weights && curl -L -o ~/tmp/ps4-weights/checkpoint_epoch037.pt <URL above>   # check the SHA-256
~/tmp/ps4-venv/bin/python -I tools/ps4/export_coreml.py --ckpt ~/tmp/ps4-weights/checkpoint_epoch037.pt \
    --out "$HOME/Library/Application Support/Needs You/models/ps4"
```

The app compiles the `.mlpackage` files on first use. PS4 conditions on up to 10 s of his voice in `ps4-enroll.wav`. Learn My Voice and Training → Learn From Recordings rewrite that file.

Test hook: `needs-you voice-test <in.wav> <out.wav> --title ps4`. It runs extraction on a file even while the switch is off.

## Measured on this Mac (M5 Pro)

Core ML fp16, per clip length:

| Compute units | 1 s | 4 s | 6 s | CPU |
|---|---|---|---|---|
| CPU + GPU (used) | 30 ms | 92 ms | 128 ms | 40-55 % of one core |
| CPU only | 91 ms | 346 ms | 512 ms | about 4.4 cores |
| CPU + Neural Engine | 240 ms | 911 ms | 1367 ms | 1 core (the BiLSTMs fall back) |

- In the app: 6 s takes 140-290 ms, and 54 s takes 1.9 s (in 8 s pieces). The first call compiles and loads the model, about 2 s.
- RAM in the app: +0.5 to 0.8 GB while loaded. The model unloads after 10 idle minutes. 32 s pieces took the app to 2 GB, which is why pieces are 8 s.
- Core ML output vs PyTorch: 22-37 dB SI-SDR in Python, 55 dB for the Swift path.

Quality, as SI-SDR gain over the mix, with 6 s clips mixed with the game track or music at 0 and -6 dB:

- TTS voices (Samantha enrolled; game, music or a second TTS voice as the interferer): +7 to +13 dB. A voice that is not enrolled is cut by about 42 dB.
- His saved Mac-mic clips (enrollment `sp/enroll.wav`, 6 clips): +0.1 dB at 0 dB SNR and about +4.7 dB at -6 dB SNR. The output stays near 0 dB SI-SDR.
- Without the 80 Hz high-pass, his clips got 15-25 dB worse: they carry a large DC offset, and PS4 then cut his voice.
- PS4's speaker encoder finds his clips inconsistent: median cosine 0.45 between his own clips, against 0.87-0.94 within one TTS voice. That is the likely reason it does better on clean TTS than on the far-field Mac mic.
- Upstream trained PS4 on ASR, speaker-similarity, VAD and DNSMOS losses, not SI-SDR. The real test is whether Whisper gets his words right: Training → Evaluate with the switch on and off, plus the live test.

## Licence

The upstream model and its weights are Apache-2.0 (per the model card). If the weights ship, keep the attribution: Ning et al., "PS4: Proxy-Supervised Joint Training for Real Target Speaker Extraction".
