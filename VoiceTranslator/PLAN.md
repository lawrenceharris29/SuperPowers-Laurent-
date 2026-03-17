# VoiceTranslator — Architecture & Implementation Plan

## Overview

A barebones iOS voice-only translation app: English → Thai.
You speak English, it speaks back the Thai translation **in your cloned voice**.

No text UI. Just a walkie-talkie button and a language indicator.

**Voice approach:** Your pre-recorded voice samples + a lightweight neural TTS model
fine-tuned on your recordings. No third-party voice cloning service. No GPU server.

---

## Revised Architecture

```
┌─────────┐    ┌───────────┐    ┌──────────────────────────┐    ┌────────────────┐
│   Mic   │───▶│  STT      │───▶│  Claude API              │───▶│  On-Device TTS │───▶ Speaker
│ (iPhone)│    │ (on-device)│    │  1. Translate EN → TH    │    │  (VITS/Piper)  │
└─────────┘    └───────────┘    │  2. Output phoneme seq   │    │  Fine-tuned on │
                Apple Speech     │  3. Prosody hints        │    │  YOUR voice    │
                ~200ms           └──────────────────────────┘    └────────────────┘
                                   ~500-1500ms                     ~100-300ms
                                                                   (on-device!)
```

**Total latency target: 0.8-2 seconds** — faster than XTTS approach because TTS is on-device.

---

## The Voice Pipeline: How It Actually Works

### Step 1: Voice Enrollment (one-time, ~30-45 min)
You record structured audio following guided prompts:
- Thai syllable matrix (consonant × vowel × tone combinations)
- Natural reading passages in English (for timbre/cadence capture)
- Emotional range samples (calm, excited, emphatic)
- Sustained vowels and consonant transitions

### Step 2: Fine-Tune a Lightweight TTS Model (offline, ~2-4 hours on a GPU)
- Take a pre-trained **VITS** or **Piper TTS** model for Thai
- Fine-tune it on your ~30-45 min of recordings
- Export to **CoreML** (.mlmodel) for on-device inference on iPhone
- Model size: ~50-100MB (fits easily on device)

### Step 3: Runtime Pipeline
1. You speak English → Apple Speech transcribes on-device
2. Claude translates to natural spoken Thai + phoneme hints
3. Your fine-tuned TTS model synthesizes Thai audio **on-device**
4. Audio plays through speaker — in your voice

---

## Workstream Decomposition & Model Assignments

The project breaks into **5 independent workstreams** that can run in parallel.
Each is assigned to the AI model best suited for it.

```
                        ┌─────────────────────────┐
                        │   YOU (Human)            │
                        │   Voice recordings       │
                        │   Final integration      │
                        │   Device testing         │
                        └────────────┬────────────┘
                                     │
             ┌───────────┬───────────┼───────────┬───────────┐
             ▼           ▼           ▼           ▼           ▼
        ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
        │ STREAM 1│ │ STREAM 2│ │ STREAM 3│ │ STREAM 4│ │ STREAM 5│
        │Claude   │ │ GPT-4o  │ │ Gemini  │ │ Kimi    │ │ Claude  │
        │iOS App  │ │ TTS     │ │ Phoneme │ │ Thai    │ │Pipeline │
        │ Core    │ │Training │ │ & Audio │ │Linguist │ │  Glue   │
        └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘
```

---

## STREAM 1: iOS App Core (Claude)
**Assigned to: Claude (Opus/Sonnet)**
**Why:** Best at Swift/SwiftUI, iOS frameworks, architectural decisions.

### Tasks
- [ ] **1.1** Create Xcode project skeleton (SwiftUI, iOS 17+)
- [ ] **1.2** AudioSessionManager — configure AVAudioSession for playAndRecord
- [ ] **1.3** SpeechRecognitionService — Apple Speech framework, on-device mode
  - Partial result streaming
  - End-of-utterance detection (silence timeout + isFinal)
- [ ] **1.4** TranslationView — walkie-talkie UI
  - Single large circular button (press-and-hold or toggle)
  - Pulsing animation while recording
  - Language indicator badge
  - State machine: idle → recording → translating → speaking
- [ ] **1.5** AnthropicClient — streaming SSE client for Claude Messages API
  - URLSession-based SSE parsing
  - Handles partial token assembly
- [ ] **1.6** TranslationService — connects STT → Claude → receives Thai text
- [ ] **1.7** SettingsView — API key entry, backend URL, voice profile selector
- [ ] **1.8** EnrollmentView — guided recording flow with prompts
  - Record to WAV (16kHz, 16-bit, mono)
  - Upload to training pipeline
  - Display progress

### Deliverables
```
ios/VoiceTranslator/
├── App/VoiceTranslatorApp.swift
├── Views/{TranslationView, EnrollmentView, SettingsView}.swift
├── ViewModels/{TranslationViewModel, EnrollmentViewModel}.swift
├── Services/{AudioSessionManager, SpeechRecognitionService,
│             TranslationService}.swift
├── Networking/AnthropicClient.swift
└── Models/{TranslationState, VoiceProfile}.swift
```

---

## STREAM 2: TTS Model Training Pipeline (GPT-4o)
**Assigned to: GPT-4o**
**Why:** Strong at Python ML pipelines, familiar with VITS/Piper training workflows,
good at writing training scripts and data processing code.

### Tasks
- [ ] **2.1** Research & select base TTS model
  - Evaluate: VITS, Piper TTS, MB-iSTFT-VITS for Thai
  - Criteria: Thai language support, fine-tuning ease, CoreML export feasibility
  - Recommend model + justify
- [ ] **2.2** Write audio preprocessing pipeline
  - Input: raw WAV recordings from enrollment
  - Normalize volume, trim silence, segment into utterances
  - Generate text-audio alignment (Montreal Forced Aligner or similar)
  - Output: training-ready dataset (audio clips + phoneme transcripts)
- [ ] **2.3** Write fine-tuning script
  - Load pre-trained Thai TTS checkpoint
  - Fine-tune on user's voice samples (~30-45 min of audio)
  - Hyperparameter config (learning rate, epochs, batch size)
  - Validation: generate test utterances, compute MOS estimate
- [ ] **2.4** Write CoreML export script
  - Convert PyTorch VITS/Piper model → ONNX → CoreML (.mlmodel)
  - Quantize to float16 for smaller model size
  - Validate output matches PyTorch inference
- [ ] **2.5** Write Dockerfile for training environment
  - CUDA + PyTorch + training dependencies
  - Mount points for audio data in / model out
  - Single command: `docker run ... --data /recordings --output /model`
- [ ] **2.6** Document the full training workflow (README)

### Deliverables
```
training/
├── Dockerfile
├── requirements.txt
├── preprocess.py          # Audio preprocessing + alignment
├── train.py               # Fine-tuning script
├── export_coreml.py       # PyTorch → CoreML conversion
├── config/
│   └── training_config.yaml
└── README.md
```

---

## STREAM 3: Phoneme Engine & Audio Utilities (Gemini)
**Assigned to: Gemini (2.5 Pro)**
**Why:** Strong at research-heavy tasks, good at signal processing,
can handle the linguistics + DSP intersection well.

### Tasks
- [ ] **3.1** Thai phoneme inventory & mapping
  - Complete Thai phoneme set (initials, vowels, finals, tones)
  - IPA ↔ Thai script mapping table
  - Phoneme-to-VITS-token mapping (depends on Stream 2's model choice)
- [ ] **3.2** Thai text-to-phoneme converter (G2P)
  - Input: Thai text (e.g., "สวัสดีครับ")
  - Output: phoneme sequence + tone markers (e.g., "s a˨˩ w a t̚˨˩ d iː˧ k r a p̚˨˩")
  - Use PyThaiNLP or build custom rules
  - Handle Thai's lack of spaces (word segmentation)
- [ ] **3.3** Prosody annotation system
  - Given a Thai sentence, generate prosody hints:
    - Duration per syllable (ms)
    - Pitch contour (for 5 Thai tones)
    - Emphasis/stress markers
  - Output format that VITS/Piper can consume
- [ ] **3.4** Audio utility library (Swift)
  - WAV file read/write
  - PCM buffer management
  - Audio format conversion (sample rate, bit depth)
  - Streaming audio player (AVAudioEngine-based, plays chunks as they arrive)
  - Silence detection (RMS energy threshold)
- [ ] **3.5** CoreML inference wrapper (Swift)
  - Load .mlmodel at app startup
  - Feed phoneme sequence + prosody → get audio PCM buffer
  - Manage inference on background thread
  - Memory management (model loading/unloading)

### Deliverables
```
phoneme/
├── thai_phonemes.json         # Complete phoneme inventory
├── g2p.py                     # Thai grapheme-to-phoneme
├── prosody.py                 # Prosody annotation
└── tests/

ios/VoiceTranslator/Audio/
├── AudioUtilities.swift       # WAV, PCM, format conversion
├── StreamingAudioPlayer.swift # Chunk-based playback
├── SilenceDetector.swift      # Energy-based silence detection
└── CoreMLTTSEngine.swift      # On-device TTS inference
```

---

## STREAM 4: Thai Language & Enrollment Design (Kimi)
**Assigned to: Kimi**
**Why:** Strong in Asian languages, excellent Thai understanding,
can design linguistically rigorous enrollment scripts.

### Tasks
- [ ] **4.1** Design the voice enrollment recording script
  - Create a structured list of Thai sentences/phrases that maximally cover:
    - All 44 Thai consonants in initial position
    - All 21 vowel forms (short + long)
    - All 5 tones in varied contexts
    - Common consonant clusters (กร, กล, ปร, etc.)
    - Final consonants (ก, น, ม, ง, etc.)
  - Organize into ~50-70 short sentences
  - Include romanization (for a non-Thai speaker to read phonetically)
  - Include English translations (so the speaker understands context)
  - Target: 30-45 minutes of natural reading pace

- [ ] **4.2** Design English reading passages for voice capture
  - 3-4 paragraphs that cover English's full phonetic range
  - Varied emotional register (news anchor, casual, excited, empathetic)
  - These capture the speaker's natural timbre/cadence in their native language

- [ ] **4.3** Create translation prompt test suite
  - 100 English sentences spanning:
    - Casual conversation ("Hey, where's the bathroom?")
    - Formal requests ("Could you please bring the check?")
    - Emotional content ("I'm really excited to be here!")
    - Complex sentences ("If the weather's nice tomorrow, let's go to the temple")
    - Idioms that need cultural adaptation, not literal translation
  - Expected Thai translations (colloquial register) for each
  - Tone/politeness annotations (ครับ/ค่ะ particle usage, etc.)

- [ ] **4.4** Thai TTS quality evaluation rubric
  - Scoring criteria for voice clone quality:
    - Tone accuracy (1-5 scale per utterance)
    - Naturalness (MOS-like scoring)
    - Speaker similarity (ABX test design)
    - Intelligibility (can a Thai speaker understand?)
  - Create 20 test sentences for evaluation
  - Document evaluation methodology

### Deliverables
```
enrollment/
├── thai_recording_script.md    # Structured recording prompts
├── english_passages.md         # English timbre capture texts
├── prompt_test_suite.json      # 100 EN→TH test pairs
├── evaluation_rubric.md        # Quality scoring methodology
└── evaluation_sentences.json   # 20 TTS test sentences
```

---

## STREAM 5: Pipeline Orchestration & Integration (Claude)
**Assigned to: Claude (Opus/Sonnet)**
**Why:** This is the glue. Needs to understand all 4 other streams and wire them together.
Claude is best at cross-system architectural thinking.

### Tasks
- [ ] **5.1** AudioPipeline orchestrator (Swift)
  - State machine: idle → listening → transcribing → translating → synthesizing → playing
  - Connects: STT → TranslationService → CoreMLTTSEngine → StreamingAudioPlayer
  - Handles partial results: start translating before STT is final
  - Phrase-level chunking: send complete Thai phrases to TTS as they stream in
  - Error recovery at each stage

- [ ] **5.2** Claude translation prompt engineering
  - System prompt for natural spoken Thai (ภาษาพูด)
  - Conversational context window (prior 5 exchanges)
  - Instruct Claude to output phoneme hints alongside Thai text:
    ```json
    {
      "thai_text": "สวัสดีครับ",
      "phonemes": "sa˨˩.wat̚˨˩.diː˧.krap̚˨˩",
      "prosody": {"tempo": "normal", "emotion": "friendly"}
    }
    ```
  - Test and iterate with Stream 4's test suite

- [ ] **5.3** Latency optimization
  - Profile each pipeline stage
  - Implement speculative execution:
    - Start translating from partial STT (cancel if STT revises)
    - Pre-warm CoreML model on app launch
    - Buffer first TTS chunk while second generates
  - Target: <1.5s from end-of-speech to first audio output

- [ ] **5.4** End-to-end integration testing plan
  - Test harness that simulates: audio file → STT → Claude → TTS → output audio
  - Latency benchmarks per stage
  - Quality metrics (using Stream 4's rubric)

- [ ] **5.5** Configuration & deployment
  - API key management (Keychain)
  - CoreML model bundling vs. download-on-first-use
  - App size budget (~100-150MB with model)

### Deliverables
```
ios/VoiceTranslator/
├── Services/AudioPipeline.swift       # Orchestrator
├── Services/TranslationPrompts.swift  # Prompt engineering
└── Config/AppConfiguration.swift      # Keys, URLs, settings

docs/
├── integration_test_plan.md
└── latency_benchmarks.md
```

---

## Dependency Graph & Execution Order

```
Week 1-2                    Week 2-3                   Week 3-4
─────────                   ─────────                  ─────────

STREAM 4 (Kimi)             STREAM 2 (GPT) ◀── depends on 4.1 (recording script)
├─ Recording scripts        ├─ Preprocessing pipeline
├─ English passages         ├─ Training script
├─ Test suite               ├─ CoreML export
└─ Eval rubric              └─ Docker training env

STREAM 1 (Claude)           STREAM 3 (Gemini)          STREAM 5 (Claude)
├─ iOS project skeleton     ├─ Phoneme inventory       ├─ AudioPipeline
├─ Audio session            ├─ G2P converter           ├─ Prompt engineering
├─ STT service              ├─ Audio utilities (Swift)  ├─ Latency optimization
├─ Walkie-talkie UI         ├─ CoreML TTS wrapper      └─ Integration testing
├─ Claude API client        └─ Streaming player
└─ Enrollment UI

                   YOU (Human) — Throughout
                   ├─ Record voice samples (after Stream 4 delivers scripts)
                   ├─ Run training pipeline (after Stream 2 delivers scripts)
                   ├─ Test on physical iPhone
                   └─ Evaluate output quality (using Stream 4's rubric)
```

### Critical Path
```
Stream 4 (enrollment scripts) → YOU (record voice) → Stream 2 (train model)
→ Stream 3 (CoreML wrapper) → Stream 5 (integration) → YOU (device testing)
```

Streams 1 and 3 can start immediately and run fully in parallel.
Stream 4 should start first since Stream 2 depends on its recording script.

---

## What Each Model Should Receive

### Prompt for GPT-4o (Stream 2)
```
Build a complete TTS model fine-tuning pipeline for voice cloning.

Context: We're building an iOS app that translates English → Thai and speaks
the output in the user's cloned voice. The user will record ~30-45 minutes of
guided Thai sentences and English passages. We need to fine-tune a lightweight
TTS model on these recordings, then export to CoreML for on-device inference.

Requirements:
- Base model: VITS or Piper TTS (must support Thai, must be fine-tunable)
- Input: WAV recordings (16kHz, 16-bit, mono) + text transcripts
- Output: CoreML model (~50-100MB) that takes phoneme sequences → audio
- Training should work on a single consumer GPU (RTX 3060+)
- Provide: preprocessing, training, CoreML export scripts + Dockerfile

Deliverables: Python scripts, Dockerfile, config YAML, README.
```

### Prompt for Gemini (Stream 3)
```
Build the phoneme engine and audio utility layer for a Thai voice translation app.

Context: iOS app translates English → Thai, synthesizes speech on-device using
a CoreML TTS model (VITS-based). You're building two things:

1. PYTHON: Thai text-to-phoneme (G2P) converter
   - Input: Thai text → Output: IPA phoneme sequence with tone markers
   - Handle word segmentation (Thai has no spaces)
   - Use PyThaiNLP or custom rules
   - Include prosody annotation (duration, pitch contour, emphasis)

2. SWIFT: Audio utilities for iOS
   - StreamingAudioPlayer (AVAudioEngine, plays PCM chunks incrementally)
   - CoreML TTS inference wrapper (load model, feed phonemes, get audio)
   - Audio format utilities (WAV read/write, sample rate conversion)
   - Silence detector (RMS energy threshold for end-of-utterance)

Deliverables: Python package + Swift source files.
```

### Prompt for Kimi (Stream 4)
```
Design the linguistic assets for a Thai voice cloning + translation app.

Context: A user will record their voice reading structured prompts. These
recordings train a TTS model to speak Thai in their voice. We need:

1. Thai recording script (~50-70 sentences covering all phonemes, tones,
   consonant clusters). Include romanization + English translations.
   Target: 30-45 min of recording at natural pace.

2. English reading passages (3-4 paragraphs) for voice timbre capture.
   Varied emotional registers.

3. Translation test suite: 100 English sentences with expected Thai
   translations (colloquial ภาษาพูด register). Span casual, formal,
   emotional, complex, idiomatic.

4. TTS quality evaluation rubric and 20 test sentences.

Output: Markdown files and JSON datasets.
```

---

## Cost Summary (Revised — No GPU Server)

| Component | Cost |
|-----------|------|
| Apple Speech (STT) | Free (on-device) |
| Claude API (Translation) | ~$0.003-0.03 per translation |
| TTS (on-device) | Free after initial training |
| One-time GPU training | ~$2-5 (RunPod, 2-4 hours) |
| **Monthly cost (moderate use)** | **~$1-10/month** (just Claude API) |

---

## Open Questions

1. **VITS vs. Piper?** GPT-4o (Stream 2) should evaluate and recommend.
2. **CoreML performance on iPhone?** Need to benchmark — if too slow, may need
   to quantize more aggressively or use Apple's Neural Engine.
3. **Should Claude output phonemes directly?** Or should we do G2P on-device?
   Doing it in Claude's prompt reduces one processing step but increases token cost.
4. **Recording in Thai vs. English?** If you don't speak Thai, the enrollment
   recordings would be phonetic reading (romanized Thai). Quality may suffer vs.
   a native speaker's recordings. Need to test.
5. **Model size vs. quality tradeoff?** 50MB model = faster/smaller but lower quality.
   100MB+ = better quality but slower inference and bigger app.
