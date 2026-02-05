# Home Assistant Voice Pipeline - Local LLM Setup

## Overview

Local voice processing for Home Assistant using a Nabu mic, with GPU-accelerated inference on TrueNAS and TTS on Kubernetes.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            VOICE COMMAND FLOW                               │
└─────────────────────────────────────────────────────────────────────────────┘

   YOU: "Hey Nabu, turn on the living room lights"
                          │
                          ▼
              ┌───────────────────┐
              │     Nabu Mic      │  ← Wakeword detection happens locally
              │   (on your LAN)   │
              └─────────┬─────────┘
                        │ audio stream
                        ▼
              ┌───────────────────┐
              │  Home Assistant   │  ← Routes audio to pipeline
              │  (Zdroid/RPi)     │    Lightweight coordination only
              └─────────┬─────────┘
                        │
        ┌───────────────┴───────────────┐
        │                               │
        ▼                               ▼
┌───────────────────────┐    ┌───────────────────────┐
│       TrueNAS         │    │    talos-ramhaus      │
│     (1660 Ti GPU)     │    │   (Kubernetes/CPU)    │
├───────────────────────┤    ├───────────────────────┤
│ ┌───────────────────┐ │    │ ┌───────────────────┐ │
│ │  Whisper (STT)    │ │    │ │   Piper (TTS)     │ │
│ │  GPU-accelerated  │ │    │ │   CPU is fast     │ │
│ └───────────────────┘ │    │ └───────────────────┘ │
│ ┌───────────────────┐ │    └───────────────────────┘
│ │  Ollama (LLM)     │ │
│ │  GPU-accelerated  │ │
│ └───────────────────┘ │
└───────────────────────┘
```

### Pipeline Steps

1. **WAKE** - Nabu hears "Hey Nabu" → wakes up, streams audio to HA
2. **STT** - HA sends audio to Whisper → transcribes to text
3. **INTENT** - HA parses intent OR sends to Ollama for complex queries
4. **ACTION** - HA executes the command (e.g., turn on lights)
5. **RESPONSE** - HA generates response text
6. **TTS** - Text sent to Piper → audio stream back
7. **PLAY** - Audio plays through Nabu speaker

**Expected round-trip: ~2-4 seconds with GPU**

## Hardware

### TrueNAS (GPU inference - STT & LLM)

| Component | Spec |
|-----------|------|
| GPU | NVIDIA GTX 1660 Ti (6GB VRAM) |
| CPU | Intel Core i5-4670K @ 3.40GHz |
| Role | Runs Whisper (STT), Ollama (LLM) |

**VRAM Budget:**

| Service | VRAM Usage |
|---------|------------|
| Whisper large-v3 | ~1.5GB |
| Mistral 7B Q4 (or similar) | ~4GB |
| **Total** | ~5.5GB |

> Note: Jellyfin also uses this GPU for transcoding. NVENC/NVDEC are separate silicon from CUDA cores, so they shouldn't compete for compute. VRAM is shared but should be fine with a few streams.

### talos-ramhaus (Kubernetes - TTS)

| Spec | Value |
|------|-------|
| CPU | 16 cores |
| RAM | ~128GB |
| GPU | None |
| Role | Runs Piper (TTS) |

Piper runs great on CPU (~50-200ms per response). No need for GPU acceleration. Running it on the cluster keeps it in GitOps/ArgoCD workflow and reduces load on TrueNAS.

### Home Assistant Host (Zdroid/RPi)

- Runs Home Assistant only
- Lightweight coordination, no heavy processing
- Connects to TrueNAS and Kubernetes services over LAN

## Services to Deploy on TrueNAS

### 1. Ollama (LLM)

- **Container:** `ollama/ollama`
- **Port:** 11434
- **GPU:** Required
- **Models:** Mistral 7B, Llama 3 8B, or similar 7B quantized model

### 2. Wyoming-Whisper (STT)

- **Container:** `rhasspy/wyoming-whisper`
- **Port:** 10300
- **GPU:** Required for fast inference
- **Model:** `large-v3` or `medium` (faster, slightly less accurate)

## Services to Deploy on Kubernetes (talos-ramhaus)

### Wyoming-Piper (TTS)

- **Container:** `rhasspy/wyoming-piper`
- **Port:** 10200
- **GPU:** Not required (CPU is fast enough)
- **Voice:** Choose from available Piper voices
- **Deploy via:** Kustomize + ArgoCD

## Home Assistant Configuration

Once services are running, configure HA to use them:

1. Add Wyoming integration for Whisper (STT) pointing to TrueNAS IP:10300
2. Add Wyoming integration for Piper (TTS) pointing to Kubernetes service IP:10200
3. Add Ollama integration (or use OpenAI-compatible API) pointing to TrueNAS IP:11434
4. Create a Voice Assistant pipeline using these services
5. Assign the pipeline to the Nabu mic

## TODO

### TrueNAS Setup
- [ ] Set up GPU passthrough for containers on TrueNAS Scale
- [ ] Deploy Ollama container with GPU access
- [ ] Deploy Wyoming-Whisper container with GPU access
- [ ] Pull and test LLM model (Mistral 7B or similar)

### Kubernetes Setup
- [ ] Create Kustomize manifests for Wyoming-Piper
- [ ] Deploy to talos-ramhaus via ArgoCD
- [ ] Expose service for Home Assistant access

### Home Assistant Setup
- [ ] Configure Wyoming integrations (Whisper + Piper)
- [ ] Configure Ollama integration
- [ ] Create voice pipeline
- [ ] Test end-to-end with Nabu mic
- [ ] Tune model selection based on performance

## Notes

- If voice responses are slow during Jellyfin transcoding, consider using Whisper `medium` model to reduce VRAM usage
- Ollama unloads models after idle timeout by default, which frees VRAM but adds cold-start latency
- Can adjust Ollama's `OLLAMA_KEEP_ALIVE` env var to control model unload behavior
