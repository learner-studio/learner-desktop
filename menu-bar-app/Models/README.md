# Models

`silero-vad.mlmodelc` — Silero VAD v6.0.0 (32 ms frames, unified), converted to Core ML by
FluidInference: https://huggingface.co/FluidInference/silero-vad-coreml
(`silero-vad-unified-v6.0.0.mlmodelc`). Silero VAD is MIT-licensed
(https://github.com/snakers4/silero-vad). Inputs: `audio_input` [1, 576] (64 samples of
context + 512 new, 16 kHz), `hidden_state`/`cell_state` [1, 128]; outputs `vad_output`
(speech probability) and the next states. Used by `menu-bar-app/Speech.swift`; bundled into
the app by `scripts/build-app.sh`.
