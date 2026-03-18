# End-to-End Integration Testing Plan

## Overview

This document defines the testing strategy for the VoiceTranslator pipeline.
Tests are organized into tiers by what they require to run.

## Test Tiers

### Tier 1: Unit Tests (Simulator, No Network)

Run in Xcode on simulator. No API key or microphone needed.

| Test | Component | What it verifies |
|------|-----------|-----------------|
| Pipeline state machine | AudioPipeline | idle → listening → translating → synthesizing → speaking → idle transitions |
| State reset | AudioPipeline | `reset()` returns to idle, clears transcript/translation |
| Interrupt during speaking | AudioPipeline | Can restart listening while speaking |
| Block start during translating | AudioPipeline | Ignores `startListening()` during translation |
| Tokenizer loads inventory | PhonemeTokenizer | Parses `thai_phonemes.json` without errors |
| Tokenizer padding | PhonemeTokenizer | Pads output to `maxSequenceLength` |
| Tokenization latency | PhonemeTokenizer | < 5ms for typical Thai sentence |
| Audio player init | StreamingAudioPlayer | Creates engine without crash |
| Buffer scheduling | StreamingAudioPlayer | Schedules PCM chunks for playback |
| Buffer creation latency | StreamingAudioPlayer | < 1ms per 1-second buffer |
| Normalization | AudioUtilities | Peak normalizes to target amplitude |
| CoreML engine reports unloaded | CoreMLTTSEngine | `isModelLoaded` is false before loading |
| Speaker gender particles | TranslationService | Male → ครับ, Female → ค่ะ |

### Tier 2: API Integration Tests (Simulator, Network Required)

Require `ANTHROPIC_API_KEY` environment variable. Skip gracefully if not set.

| Test | Component | What it verifies |
|------|-----------|-----------------|
| Thai-only output | TranslationService | No Latin characters in translation |
| Male particle usage | TranslationService | ครับ appears for male speaker |
| Female particle usage | TranslationService | ค่ะ/คะ appears for female speaker |
| Greeting adaptation | TranslationService | "Hi" → contains สวัสดี |
| Phrase emission | TranslationService | `onPhrase` fires at least once |
| Conversation history | TranslationService | Context maintained across turns |

### Tier 3: Device Tests (Physical iPhone Required)

Require a physical device with microphone, speaker, and enrolled voice model.

| Test | What it verifies | How to validate |
|------|-----------------|-----------------|
| STT recognition | Microphone → English text | Speak "Hello" and verify transcript |
| Full pipeline round-trip | Speak English → hear Thai | Hold button, speak, release, listen |
| Latency budget | Total < 2.0s | Check console logs for pipeline timing |
| Audio session handoff | STT mic → TTS speaker | No audio glitches during transition |
| Interrupt handling | Tap during playback restarts | Press while Thai is playing |
| Background/foreground | App survives backgrounding | Background during translation, return |
| Model hot-loading | New model loads without restart | Replace .mlmodel, verify it loads |

## Latency Budget

Target total latency: **0.8–2.0 seconds** (speak → hear Thai).

| Stage | Budget | Measured by |
|-------|--------|-------------|
| STT (Apple Speech) | 0–200ms after silence | `silenceTimeout` (1.5s) + processing |
| Claude API (first token) | 200–500ms | `firstPhraseTime - translationStartTime` |
| Claude API (full response) | 300–800ms | `Full translation latency` log |
| Phoneme tokenization | < 5ms | Benchmark test |
| CoreML TTS inference | 50–200ms per phrase | `CoreMLTTS` log |
| Audio buffer + playback start | < 10ms | `Buffer creation latency` test |

With speculative TTS, the TTS stage overlaps with translation streaming,
reducing effective latency by 100–300ms.

## Running Tests

```bash
# Tier 1 (simulator)
xcodebuild test -scheme VoiceTranslator -destination 'platform=iOS Simulator,name=iPhone 15'

# Tier 2 (with API key)
ANTHROPIC_API_KEY=sk-ant-... xcodebuild test -scheme VoiceTranslator \
  -destination 'platform=iOS Simulator,name=iPhone 15'

# Tier 3 (physical device)
xcodebuild test -scheme VoiceTranslator -destination 'id=<device-udid>'
```

## Quality Evaluation

Use the evaluation rubric from `enrollment/evaluation_rubric.md` and the
100-sentence test suite from `enrollment/prompt_test_suite.json` to assess
translation quality. Key metrics:

1. **Intelligibility**: Can a Thai native speaker understand the output?
2. **Naturalness**: Does it sound like spoken Thai, not translated Thai?
3. **Tonal accuracy**: Are tones correct (verified by native speaker)?
4. **Speaker similarity**: Does the cloned voice sound like the enrolled speaker?
5. **Latency**: Is the response fast enough for conversational flow?
