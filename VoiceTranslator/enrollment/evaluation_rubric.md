# Thai TTS Evaluation Rubric

## Overview
This rubric provides scoring criteria for evaluating the quality of Thai text-to-speech output from the voice cloning system. Each dimension is scored 1-5.

---

## Dimension 1: Tonal Accuracy (Weight: 30%)

| Score | Description |
|-------|-------------|
| 5 | All 5 tones (mid, low, falling, high, rising) are clearly distinguishable and match native speaker patterns |
| 4 | 4/5 tones correct; minor deviations in one tone that don't cause confusion |
| 3 | 3/5 tones correct; some tonal confusion but meaning generally recoverable from context |
| 2 | Frequent tonal errors; native listener must rely heavily on context |
| 1 | Tones largely absent or random; unintelligible to native speakers |

### Key Test Cases
- Minimal pairs: กา/ก่า/ก้า/ก๊า/ก๋า (all 5 tones on same syllable)
- Tone sandhi in connected speech
- Question intonation (ไหม/มั้ย particles)

---

## Dimension 2: Segmental Quality (Weight: 25%)

| Score | Description |
|-------|-------------|
| 5 | All consonants (initial/final), vowels (short/long), and diphthongs are accurate |
| 4 | Minor issues with rare consonants (ฌ, ฑ, ฬ) or diphthongs; common phonemes correct |
| 3 | Noticeable issues with aspiration contrasts (ก/ข, ต/ถ, ป/พ) or vowel length |
| 2 | Multiple segmental errors affecting intelligibility |
| 1 | Severe distortion; phonemes unrecognizable |

### Key Test Cases
- Aspiration contrasts: ก vs ข, ต vs ถ, ป vs พ
- Vowel length: กิน (short i) vs กีน (long ii)
- Final consonants: -ก, -ด, -บ (unreleased stops)
- Consonant clusters: กร, กล, กว, ปร, ปล, ตร

---

## Dimension 3: Prosody & Rhythm (Weight: 20%)

| Score | Description |
|-------|-------------|
| 5 | Natural Thai rhythmic patterns; appropriate phrase-level intonation; correct pausing |
| 4 | Generally natural; minor issues with phrase boundaries or speech rate |
| 3 | Somewhat robotic; phrase grouping occasionally unnatural |
| 2 | Monotonous or inappropriately choppy; poor phrase-level prosody |
| 1 | No discernible prosodic structure |

### Key Test Cases
- Sentence-final lengthening
- Question vs statement intonation
- Discourse markers (แหละ, นะ, ครับ/ค่ะ)
- Emotional variation (excitement, calm, anger)

---

## Dimension 4: Speaker Similarity (Weight: 15%)

| Score | Description |
|-------|-------------|
| 5 | Indistinguishable from enrollment recordings; timbre, pitch range, and vocal quality match |
| 4 | Clearly the same speaker; minor differences in edge cases |
| 3 | Recognizable as the same speaker but with noticeable differences |
| 2 | Some similarity but would not pass as the same speaker |
| 1 | No resemblance to enrollment speaker |

### Evaluation Method
- A/B comparison with enrollment passages
- MOS (Mean Opinion Score) from 3+ listeners
- Speaker embedding cosine similarity (target > 0.85)

---

## Dimension 5: Naturalness (Weight: 10%)

| Score | Description |
|-------|-------------|
| 5 | Could pass as natural human speech; no artifacts |
| 4 | Mostly natural; rare minor artifacts (slight breathiness, micro-glitches) |
| 3 | Audibly synthetic but comfortable to listen to |
| 2 | Clearly synthetic; artifacts are distracting |
| 1 | Highly robotic; uncomfortable to listen to |

### Key Artifacts to Check
- Metallic/buzzing quality
- Unnatural breath sounds
- Clicking or popping
- Abrupt transitions between phonemes

---

## Scoring Protocol

1. **Select test sentences** from `evaluation_sentences.json` (5 easy, 8 medium, 4 hard, 3 stress-test)
2. **Generate TTS output** for each sentence
3. **Score each dimension** independently (1-5)
4. **Calculate weighted total**: `(Tone * 0.30) + (Segmental * 0.25) + (Prosody * 0.20) + (Similarity * 0.15) + (Naturalness * 0.10)`
5. **Record per-sentence scores** for regression tracking

### Pass/Fail Thresholds
- **Production ready**: Weighted total >= 4.0, no dimension below 3
- **Beta quality**: Weighted total >= 3.5, no dimension below 2
- **Needs improvement**: Weighted total < 3.5 or any dimension at 1

---

## Category Coverage Requirements

Test suite must include at least:
- 10 casual greetings
- 10 directions/navigation
- 10 restaurant/food
- 10 formal requests
- 10 emotional expressions
- 10 complex compound sentences
- 10 idioms/cultural adaptations
- 10 questions (yes/no, wh-, tag, alternative)
- 10 time/numbers/practical
- 20 evaluation sentences (easy through stress-test)

All 100 test pairs in `prompt_test_suite.json` cover these categories.
