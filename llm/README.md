# Home Assistant Voice Pipeline - Local LLM Setup

## Overview

Local voice processing for Home Assistant using a Nabu Voice PE, with GPU-accelerated inference on TrueNAS and TTS on Kubernetes.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            VOICE COMMAND FLOW                               │
└─────────────────────────────────────────────────────────────────────────────┘

   YOU: "OK Nabu, turn on the kitchen lights"
                          │
                          ▼
              ┌───────────────────┐
              │  Nabu Voice PE    │  ← Wakeword detection happens locally
              │  10.0.67.22       │    ESPHome, port 6053
              │  (botnet VLAN)    │
              └─────────┬─────────┘
                        │ audio stream
                        ▼
              ┌───────────────────┐
              │  Home Assistant   │  ← Routes audio to pipeline
              │  10.0.1.33:8123  │    ODROID-C4, HAOS 17.0
              │  (untagged LAN)   │
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
│ │  base.en model    │ │    │ │   CPU is fast     │ │
│ │  GPU-accelerated  │ │    │ │   10.0.7.202      │ │
│ └───────────────────┘ │    │ └───────────────────┘ │
│ ┌───────────────────┐ │    └───────────────────────┘
│ │  Ollama (LLM)     │ │
│ │  fixt/home-3b-v3  │ │
│ │  GPU-accelerated  │ │
│ └───────────────────┘ │
└───────────────────────┘
```

### Pipeline Steps

1. **WAKE** - Nabu hears "OK Nabu" → wakes up, streams audio to HA
2. **STT** - HA sends audio to Whisper (base.en) → transcribes to text
3. **INTENT** - HA sends text to Ollama (fixt/home-3b-v3) via home-llm HACS integration
4. **ACTION** - HA executes the command (e.g., turn on lights)
5. **RESPONSE** - Model generates response text
6. **TTS** - Text sent to Piper → audio stream back
7. **PLAY** - Audio plays through Nabu speaker

## Hardware

### TrueNAS (GPU inference - STT & LLM)

| Component | Spec |
|-----------|------|
| GPU | NVIDIA GTX 1660 Ti (6GB VRAM) |
| CPU | Intel Core i5-4670K @ 3.40GHz |
| Role | Runs Whisper (STT), Ollama (LLM) |
| Ollama | Docker container `ollama/ollama:0.15.6` (TrueNAS app: `ix-ollama-ollama-1`) |

**VRAM Budget (current):**

| Service | VRAM Usage |
|---------|------------|
| Whisper small.en | ~2GB |
| fixt/home-3b-v3 | ~1.7GB |
| **Total** | ~3.7GB |

> Note: Jellyfin also uses this GPU for transcoding. NVENC/NVDEC are separate silicon from CUDA cores, so they shouldn't compete for compute. VRAM is shared but should be fine with a few streams.
>
> If STT accuracy is still poor, can upgrade to `small.en` (~2GB VRAM) and still fit in 6GB.

### talos-ramhaus (Kubernetes - TTS)

| Spec | Value |
|------|-------|
| CPU | 16 cores |
| RAM | ~128GB |
| GPU | None |
| Role | Runs Piper (TTS) |

Piper runs great on CPU (~50-200ms per response). No need for GPU acceleration. Running it on the cluster keeps it in GitOps/ArgoCD workflow and reduces load on TrueNAS.

### Home Assistant Host (ODROID-C4)

- Runs Home Assistant OS 17.0, Core 2026.2.1
- Lightweight coordination, no heavy processing
- Connects to TrueNAS and Kubernetes services over LAN

## Deployed Services

### 1. Ollama (LLM) - TrueNAS

- **Container:** `ollama/ollama:0.15.6` (TrueNAS app: `ix-ollama-ollama-1`)
- **Port:** 30068 (mapped from container port 11434)
- **GPU:** Required
- **Active Model:** `fixt/home-3b-v3` (via home-llm HACS integration)
- **Backup Model:** `qwen3:4b` (via native Ollama integration — slower but more tolerant of bad STT)

#### home-llm Integration (HACS)

The active conversation agent uses the [home-llm](https://github.com/acon96/home-llm) HACS custom integration with:
- **Backend:** Ollama API
- **Model:** `fixt/home-3b-v3`
- **Tool Call Prefix:** `` ```homeassistant ``
- **Tool Call Suffix:** `` ``` ``
- **Maximum Tool Call Attempts:** 0 (one attempt, no looping — required for Home models v1-v3)
- **Enable Legacy Tool Calling:** Yes
- **Tool Response as String:** Yes
- **ICL Examples:** Enabled (in_context_examples.csv)
- **Remember Conversation:** 0 (fresh context each turn)
- **Refresh System Prompt Every Turn:** Yes

#### Custom Model: qwen3-4b-nothink (backup)

Built from `qwen3:4b` with the thinking/reasoning section removed from the template to prevent verbose chain-of-thought output. The standard Qwen3 model outputs long reasoning dumps that slow down voice responses.

Created with:
```bash
docker exec ix-ollama-ollama-1 ollama create qwen3-4b-nothink -f /tmp/Modelfile
```

The Modelfile is based on the default `qwen3:4b` template with the `$.IsThinkSet` / `.Thinking` block removed from the assistant message section. Parameters preserved from base model:
- `top_p`: 0.95
- `repeat_penalty`: 1
- `temperature`: 0.6
- `top_k`: 20

Note: Template modification alone did NOT suppress thinking — the model still outputs thinking as plain text. The `PARAMETER think false` is not supported in Ollama 0.15.6. The `/no_think` prompt flag is also not respected by the HA Ollama integration.

#### Models Tested

| Model | Integration | Tool Calling | Speed | Notes |
|-------|-----------|-------------|-------|-------|
| qwen2.5:1.5b | Native Ollama | No - hallucinates responses | Fast | Too small, doesn't use HA tools |
| qwen2.5:3b | Native Ollama | No - hallucinates responses | Slow (~14s intent) | Same problem as 1.5b |
| fixt/home-3b-v2 | N/A | No - doesn't support tools | N/A | Doesn't support Ollama tool calling API |
| qwen3:4b | Native Ollama | Yes | Slow (thinking dumps) | Works but reasoning mode wastes time, can't be disabled |
| qwen3-4b-nothink | Native Ollama | Yes | Still slow | Template hack didn't fully suppress thinking |
| **fixt/home-3b-v3** | **home-llm (HACS)** | **Yes (legacy)** | **Fast (~1s)** | **Active choice. Works with exact phrasing, inconsistent with bad STT** |

#### Ollama Tuning Tips

- Set `OLLAMA_KEEP_ALIVE=-1` to keep model loaded in VRAM (avoids cold-start on each request)
- Context window: 4096 is sufficient for voice commands (8192 wastes VRAM)

### 2. Faster-Whisper (STT) - TrueNAS

- **Port:** 10300 (Wyoming protocol)
- **GPU:** Required for fast inference
- **Model:** `small.en` (English-only, ~2GB VRAM)

#### Whisper Model Notes

| Model | VRAM | Accuracy | Notes |
|-------|------|----------|-------|
| large-v3 | ~3GB | Best | Too slow, competed with Ollama for 6GB VRAM |
| **small.en** | **~2GB** | **Good** | **Current choice. Upgraded from base.en** |
| base.en | ~1.5GB | Decent | Previous choice. Mishears sometimes |
| tiny.en | ~1GB | Poor | Too many mishearings ("life" instead of "light", "going on" instead of "lights on") |

The biggest bottleneck is STT accuracy — the LLM can't match commands when Whisper mishears them. Consider upgrading to `small.en` if accuracy remains a problem.

### 3. Wyoming-Piper (TTS) - Kubernetes

- **Namespace:** `piper`
- **Service IP:** `10.0.7.202:10200` (MetalLB LoadBalancer)
- **Node:** `talos-ramhaus`
- **GPU:** Not required (CPU is fast enough)
- **Voice:** `en_US-lessac-medium`

## Home Assistant Configuration

### Integrations

1. **ESPHome** - Nabu Voice PE at `10.0.67.22:6053`
2. **Wyoming** - Whisper (STT) pointing to TrueNAS
3. **Wyoming** - Piper (TTS) pointing to `10.0.7.202:10200`
4. **home-llm (HACS)** - Conversation agent via Ollama API at TrueNAS:30068, model `fixt/home-3b-v3`
5. **Ollama** (native) - Backup conversation agent at TrueNAS:30068, model `qwen3:4b`
6. **HACS** - Installed for home-llm and Sonoff LAN integrations
7. **Sonoff LAN** (HACS) - Local control of Sonoff/eWeLink devices (migrated from Alexa/cloud)

### Voice Pipeline

- **STT:** Faster Whisper (small.en)
- **Conversation Agent:** home-llm (fixt/home-3b-v3)
- **TTS:** Piper (en_US-kristin-medium voice)

### Device Exposure

Devices must be exposed to Assist via **Settings > Voice Assistants > Expose** with appropriate aliases. Currently exposed:
- **Kitchen Lights** (Kasa smart switch, domain: `switch`, area: Kitchen) at `10.0.67.21`
  - Aliases: "kitchen light" (singular)
- **Sonoff devices** — migrated from eWeLink/Alexa to Sonoff LAN integration, exposed to Assist via Nabu

### Voice Command Tips

The `fixt/home-3b-v3` model works best with clear command phrasing:
- "Turn on the kitchen lights" / "Turn off the kitchen lights" (works)
- "Kitchen light off" / "kitchen going on" (does NOT work reliably)

Speak clearly and close to the Nabu mic. Use full "turn on/off the [device]" phrasing.

## Network Notes

- Nabu Voice PE, Kasa switch, and Sonoff devices are on the **botnet VLAN** (`10.0.67.0/24`)
- Home Assistant is on the **untagged LAN** (`10.0.1.0/24`)
- HA can reach into the botnet VLAN (firewall rule allows `10.0.1.33` → `10.0.67.0/24`)
- mDNS/auto-discovery does not cross VLANs — devices must be added by IP

## Known Issues

- **HA Ollama JSON serialization bug** ([#158916](https://github.com/home-assistant/core/issues/158916)): Asking "what time is it?" causes `HassGetCurrentTime` to return a `datetime.time` object that can't be serialized. All subsequent requests in that conversation fail. Fix is merged upstream; avoid time queries until patched in your HA version.
- **Qwen3 thinking mode cannot be disabled**: Neither `/no_think` in prompts, `PARAMETER think false` in Modelfile, template modification, nor `think: false` API parameter works in Ollama 0.15.6. The HA Ollama integration also doesn't filter thinking output.
- **fixt/home-3b-v3 inconsistency**: Model sometimes generates Python code or garbled output (`lessless`, `pythonpython`) instead of proper tool calls, especially when STT input is noisy or imprecise.
- **STT accuracy**: Upgraded to `small.en`. Previously `base.en` mishearing "lights" as "life", "going on", etc. Monitor if `small.en` resolves this.
- **Switch vs Light domain confusion**: The Kasa device is domain `switch` but users say "light". Added "kitchen light" as alias to help matching.

## TODO

- [x] Upgrade Whisper to `small.en`
- [ ] Set `OLLAMA_KEEP_ALIVE=-1` on TrueNAS to avoid cold-start latency
- [x] Migrate Sonoff/eWeLink devices to Sonoff LAN integration
- [x] Expose Sonoff devices to Assist with aliases
- [x] Test voice control of Sonoff devices via Nabu
- [ ] Revisit LLM options when better local models or GPU upgrade available
