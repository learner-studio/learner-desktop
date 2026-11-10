# Models

`silero-vad.mlmodelc` — Silero VAD v6.0.0 (32 ms frames, unified), converted to Core ML by
FluidInference: https://huggingface.co/FluidInference/silero-vad-coreml
(`silero-vad-unified-v6.0.0.mlmodelc`). Silero VAD is MIT-licensed
(https://github.com/snakers4/silero-vad). Inputs: `audio_input` [1, 576] (64 samples of
context + 512 new, 16 kHz), `hidden_state`/`cell_state` [1, 128]; outputs `vad_output`
(speech probability) and the next states. Used by `menu-bar-app/Speech.swift`; bundled into
the app by `scripts/build-app.sh`.

`3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx` (not in git; `scripts/fetch-voice-id.sh`
fetches it, pinned by SHA-256) — 3D-Speaker CAM++ trained on VoxCeleb, 512-dim speaker
embeddings at 16 kHz, Apache-2.0 (https://github.com/modelscope/3D-Speaker), as exported by
sherpa-onnx (https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models).
Used by `menu-bar-app/VoiceID.swift`; bundled into the app by `scripts/build-app.sh`.
