# VoiceTranslator — Architecture & Implementation Plan

## Overview

A barebones iOS voice-only translation app: English → Thai.
You speak English, it speaks back the Thai translation **in your cloned voice**.

No text UI. Just a walkie-talkie button and a language indicator.

---

## Architecture: The Audio Pipeline

```
┌─────────┐     ┌───────────┐     ┌──────────────┐     ┌─────────────┐
│   Mic   │────▶│  STT      │────▶│  Translation │────▶│  TTS        │────▶ Speaker
│ (iPhone)│     │ (on-device)│     │  (Claude API)│     │ (XTTS v2)  │
└─────────┘     └───────────┘     └──────────────┘     └─────────────┘
                Apple Speech        Streaming SSE        Backend server
                ~200ms latency      ~500-1500ms          ~300-800ms
```

**Total latency target: 1-2.5 seconds** (vs. Google Translate's 3-5s for voice)

---

## Component Decisions

### 1. Speech-to-Text: Apple Speech Framework (on-device)

**Why:** Zero network latency, free, good English accuracy, iOS-native.

- Uses `SFSpeechRecognizer` with `.onDeviceRecognition` (iOS 17+)
- Real-time partial results — we can start translating before the user finishes speaking
- Falls back to server-based recognition on older devices

**Key challenge:** Detecting when the user is "done" speaking (end-of-utterance detection). We'll use a silence timeout (~1.5s) combined with `SFSpeechRecognitionResult.isFinal`.

### 2. Translation: Claude API (Anthropic)

**Why:** Excellent at natural/conversational translation, streaming support, strong Thai capability.

- Uses Claude's streaming Messages API (SSE)
- System prompt engineered for **natural spoken Thai**, not formal/written Thai
- Thai has formal (ภาษาเขียน) vs. colloquial (ภาษาพูด) registers — we want colloquial
- Prompt includes context window: prior 5 exchanges for conversational coherence
- Streams token-by-token — we accumulate until we have a complete phrase, then send to TTS

**Translation prompt strategy:**
```
You are a real-time voice translator. Translate the following spoken English
into natural spoken Thai (ภาษาพูด, not formal written Thai).
- Use colloquial register appropriate for everyday conversation
- Preserve the speaker's tone and intent (casual, urgent, polite, etc.)
- Do NOT add explanations — output ONLY the Thai translation
- Use Thai script (not romanization)
```

**Key challenge:** Streaming partial translations are tricky — Thai sentence structure differs from English (SOV elements, particles at end). We need to buffer until we have a syntactically complete chunk.

### 3. Voice Cloning & TTS: Open-Source XTTS v2 (on a backend server)

**Why:** Free, open-source, supports cross-lingual voice cloning, good quality.

The user chose open-source over ElevenLabs. Here's what that means:

#### XTTS v2 (by Coqui — now community-maintained)
- **Cross-lingual voice cloning** from ~10-30 seconds of reference audio
- Supports Thai output (one of 17 supported languages)
- Requires a GPU server (model is ~1.8GB, needs CUDA for real-time speeds)
- Apache 2.0 / CPML license (free for personal use)
- Can stream audio output via chunked WAV/PCM

#### Alternative: OpenVoice v2 (by MyShell)
- Instant voice cloning — even faster enrollment
- Better tone/style transfer
- MIT license
- Good fallback if XTTS quality is insufficient for Thai

#### The Backend Server
Since these models can't run on iPhone, we need a Python backend:

```
┌─────────────────────────────────────┐
│         Backend Server (Python)      │
│                                      │
│  FastAPI + WebSocket                 │
│  ├── /api/enroll    (upload samples) │
│  ├── /api/synthesize (TTS request)   │
│  ├── /ws/stream     (streaming TTS)  │
│  │                                   │
│  XTTS v2 model (GPU)                 │
│  Voice profiles stored on disk       │
└─────────────────────────────────────┘
```

**Hosting options:**
- Local Mac with GPU (development)
- RunPod / Vast.ai / Lambda Labs (cheap GPU cloud, ~$0.30-0.80/hr)
- Self-hosted on any NVIDIA GPU machine (RTX 3060+ recommended)

**Key challenges:**
1. **Cross-lingual quality:** XTTS cloning an English voice and outputting Thai is the hardest scenario. Thai tones may not transfer perfectly.
2. **Latency:** GPU inference takes 300-800ms for a sentence. We can reduce perceived latency by streaming audio chunks.
3. **Thai tone accuracy:** Thai has 5 tones — the model needs to produce correct tones or the translation becomes unintelligible. XTTS handles this reasonably but isn't perfect.

### 4. Voice Enrollment

The user must record voice samples before the app works. Here's the enrollment flow:

#### What to Record
1. **Reading passage** (~30 seconds): A paragraph read naturally. This gives the model your baseline pitch, timbre, and cadence.
2. **Emotional range** (~15 seconds): Happy/excited sentence, calm sentence, emphatic sentence.
3. **Sustained vowels** (~10 seconds): "Ahhh", "Eeee", "Ooooh" — helps capture vocal timbre.

**Total: ~1 minute of audio** (XTTS needs ~10-30s minimum, more is better)

#### Enrollment Flow
1. App shows a recording screen with prompts to read aloud
2. Audio recorded as WAV (16kHz, 16-bit mono)
3. Uploaded to backend server via `/api/enroll`
4. Server processes and stores the voice embedding
5. Returns a `voice_profile_id` stored in iOS Keychain
6. Future TTS requests include this ID

---

## Project Structure

```
VoiceTranslator/
├── ios/                              # iOS App (Swift/SwiftUI)
│   ├── VoiceTranslator.xcodeproj
│   └── VoiceTranslator/
│       ├── App/
│       │   ├── VoiceTranslatorApp.swift
│       │   └── Info.plist
│       ├── Views/
│       │   ├── TranslationView.swift       # Main: walkie-talkie button
│       │   ├── EnrollmentView.swift         # Voice recording flow
│       │   └── SettingsView.swift           # API config, language
│       ├── ViewModels/
│       │   ├── TranslationViewModel.swift
│       │   └── EnrollmentViewModel.swift
│       ├── Services/
│       │   ├── SpeechRecognitionService.swift   # Apple Speech STT
│       │   ├── TranslationService.swift          # Claude API streaming
│       │   ├── VoiceSynthesisService.swift       # Calls backend TTS
│       │   ├── AudioSessionManager.swift         # AVAudioSession config
│       │   └── AudioPipeline.swift               # Orchestrator
│       ├── Audio/
│       │   ├── StreamingAudioPlayer.swift         # Plays PCM chunks
│       │   └── AudioRecorder.swift                # For enrollment
│       ├── Networking/
│       │   ├── AnthropicClient.swift              # Claude Messages API
│       │   └── TTSBackendClient.swift             # XTTS backend API
│       ├── Models/
│       │   ├── VoiceProfile.swift
│       │   └── TranslationState.swift
│       └── Resources/
│           └── Assets.xcassets
│
├── backend/                          # Python TTS Server
│   ├── requirements.txt
│   ├── server.py                     # FastAPI main
│   ├── tts_engine.py                 # XTTS v2 wrapper
│   ├── voice_store.py                # Voice profile management
│   ├── audio_utils.py                # Format conversion
│   └── Dockerfile                    # For deployment
│
├── enrollment_scripts/               # Prompt texts for voice enrollment
│   └── reading_prompts.txt
│
├── PLAN.md                           # This file
└── README.md
```

---

## Technical Hurdles & Mitigations

### Hurdle 1: iOS Audio Session Conflicts
**Problem:** iOS doesn't allow simultaneous mic input + speaker output in the default audio session mode.
**Mitigation:** Use `AVAudioSession.Category.playAndRecord` with `.defaultToSpeaker` option. Configure `AVAudioSession` once at app launch with proper routing.

### Hurdle 2: End-of-Utterance Detection
**Problem:** When does the user "stop talking"? Too aggressive = cuts off mid-sentence. Too slow = adds latency.
**Mitigation:** Dual strategy: (a) 1.5s silence timeout, (b) send partial results to Claude as they arrive, marked as `[partial]` vs `[final]`. Start translating on partials, confirm/correct on final.

### Hurdle 3: Thai Tone Accuracy in Voice-Cloned TTS
**Problem:** XTTS may not perfectly reproduce Thai's 5 tones when cloning an English speaker's voice. Wrong tones = wrong meaning in Thai.
**Mitigation:**
- Test extensively with native Thai speakers
- If XTTS tone accuracy is poor, fall back to OpenVoice v2 which has better tone transfer
- As a last resort, use a high-quality Thai TTS voice (not cloned) and apply voice conversion post-hoc

### Hurdle 4: Latency Budget
**Problem:** 3 sequential network/compute steps add up.
**Mitigation — pipeline parallelism:**
```
Time ──▶
User speaks:  [====recording====]
STT:           [==partial==][==final==]
Translation:        [===streaming tokens===]
TTS:                     [==chunk1==][==chunk2==]
Playback:                      [▶play1][▶play2]
```
- Start translating from partial STT results
- Send each translated sentence/phrase to TTS immediately (don't wait for full translation)
- Stream audio playback as TTS chunks arrive
- **Target: first audio plays ~1s after user stops speaking**

### Hurdle 5: Backend Server Availability
**Problem:** Open-source TTS requires a GPU server the user must host/pay for.
**Mitigation:**
- Provide Docker image for easy self-hosting
- Document RunPod/Vast.ai setup (~$0.30/hr for a 3060)
- The server can sleep when idle and wake on request (for cost savings)
- Future: add ElevenLabs as an optional paid alternative that requires no self-hosting

### Hurdle 6: Voice Cloning Quality Cross-Lingually
**Problem:** Cloning an English voice and synthesizing Thai is an unsolved research problem at consumer quality levels. The voice may sound "like you but off."
**Mitigation:**
- Set realistic expectations: the voice will have your timbre and pitch, but Thai phonemes will sound like a Thai speaker with your voice characteristics — not literally you speaking Thai
- This is actually the *ideal* outcome for translation
- Collect enrollment samples with varied intonation to give the model more to work with

### Hurdle 7: API Key Security on iOS
**Problem:** Shipping an Anthropic API key inside an iOS app binary is insecure.
**Mitigation:**
- User enters their own API key in Settings (stored in iOS Keychain)
- Alternatively, proxy Claude API calls through the backend server (so the key lives server-side)
- For personal use, direct API key in Keychain is fine

### Hurdle 8: Network Dependency
**Problem:** Translation + TTS both require network. No offline mode possible.
**Mitigation:**
- Clear UI feedback when offline (pulsing red indicator)
- Queue failed requests for retry
- Future: explore on-device translation models (but quality will be much lower for EN→TH)

---

## Implementation Phases

### Phase 1: Foundation (iOS project + audio basics)
- [ ] Create Xcode project with SwiftUI
- [ ] Configure AVAudioSession for playAndRecord
- [ ] Implement AudioRecorder (record to WAV buffer)
- [ ] Implement SpeechRecognitionService (Apple Speech, on-device)
- [ ] Build the walkie-talkie UI (single button, press-and-hold or toggle)
- [ ] Verify: speak English → see transcription in console

### Phase 2: Translation Pipeline
- [ ] Implement AnthropicClient with streaming SSE
- [ ] Design and test translation prompt (EN → spoken Thai)
- [ ] Implement TranslationService (feeds STT output → Claude → Thai text)
- [ ] Verify: speak English → console shows Thai translation streaming in

### Phase 3: Backend TTS Server
- [ ] Set up Python FastAPI server
- [ ] Integrate XTTS v2 model
- [ ] Implement /api/enroll endpoint (accept WAV, create voice profile)
- [ ] Implement /api/synthesize endpoint (text + voice_id → audio)
- [ ] Implement /ws/stream endpoint (streaming audio output)
- [ ] Dockerize for easy deployment
- [ ] Verify: POST Thai text → receive audio in cloned voice

### Phase 4: Voice Enrollment (iOS)
- [ ] Build EnrollmentView with reading prompts
- [ ] Record and upload voice samples to backend
- [ ] Store voice_profile_id in Keychain
- [ ] Verify: complete enrollment flow end-to-end

### Phase 5: End-to-End Integration
- [ ] Wire AudioPipeline: STT → Translation → TTS → Playback
- [ ] Implement StreamingAudioPlayer (play PCM chunks as they arrive)
- [ ] Add silence detection / end-of-utterance logic
- [ ] Implement phrase-level chunking (send complete phrases to TTS, don't wait for full translation)
- [ ] Verify: speak English → hear Thai in your voice

### Phase 6: Polish & Optimization
- [ ] Latency profiling and optimization
- [ ] Error handling (network failures, API errors, empty responses)
- [ ] Settings screen (backend URL, API key, voice profile management)
- [ ] Haptic feedback on state transitions
- [ ] App icon and minimal launch screen

---

## Cost Estimates (Personal Use)

| Component | Cost |
|-----------|------|
| Apple Speech (STT) | Free (on-device) |
| Claude API (Translation) | ~$0.001-0.003 per translation (Haiku) or ~$0.01-0.03 (Sonnet) |
| XTTS Backend (GPU) | ~$0.30-0.80/hr on cloud, or free if self-hosted |
| **Total per month (moderate use)** | **~$5-30/month** depending on usage and hosting |

---

## Open Questions to Resolve During Development

1. **Which Claude model for translation?** Haiku is fastest/cheapest but may produce lower quality Thai. Sonnet is the sweet spot. Opus is overkill for translation.
2. **XTTS v2 vs. OpenVoice v2?** Need to A/B test both with Thai output. XTTS has broader language support but OpenVoice may handle tones better.
3. **Press-and-hold vs. toggle for recording?** Press-and-hold is more walkie-talkie-like but fatiguing for long utterances. Toggle (tap to start, tap to stop) may be better.
4. **Bidirectional?** Currently planned as EN→TH only. Adding TH→EN later would require Thai STT (Apple Speech supports Thai).
