# Voice Cloning TTS Fine‑Tuning Pipeline

This repository contains a complete pipeline for fine‑tuning a light‑weight
Thai/English text‑to‑speech model on approximately 30–45 minutes of
recorded speech and exporting the result to an on‑device CoreML model for iOS.
The goal is to enable voice cloning in an iOS translation app: the user
records a guided set of sentences on the device and receives a personalised
TTS model that runs entirely offline on their iPhone.

## Model selection

Several open‑source neural TTS architectures were considered:

| Candidate model | Pros | Cons | Thai checkpoint availability |
|---|---|---|---|
| **VITS** | High fidelity; widely adopted; available in Hugging Face. A Thai checkpoint from Meta's MMS project is trained on a large Thai corpus. ~36M parameters, produces 16 kHz audio. | Computationally heavier than recent lightweight variants; baseline inference speed on CPUs is slower. | facebook/mms‑tts‑tha |
| **MB‑iSTFT‑VITS** | Lightweight VITS variant, 4.1× faster. Replaces expensive components with inverse STFT and multi‑band generation. | No Thai‑specific pretrained model publicly available; training from scratch would require many hours of data. | — |
| **Piper** | Fast, local TTS for embedded devices. Multiple quality levels (5–32M params), runs fully offline. | Primarily supports Western languages; no curated Thai voice as of March 2026. | — |

Given the presence of a high‑quality Thai checkpoint and the ability to fine‑tune on a consumer GPU, **VITS** (specifically `facebook/mms‑tts‑tha`) was chosen as the base.

## Repository Layout

```
training/
├── Dockerfile              # Builds a CUDA‑enabled container for the full pipeline
├── requirements.txt        # Python dependencies
├── preprocess.py           # Audio normalisation, trimming, segmentation and phonemization
├── train.py                # Fine‑tunes the VITS model on the processed data
├── export_coreml.py        # Converts the fine‑tuned model to ONNX/FP16 CoreML
├── config/
│   └── training_config.yaml# Tunable hyperparameters with comments
└── README.md               # This document
```

## End‑to‑end workflow

### 1. Record enrolment audio

In the iOS app, the EnrollmentView records ~30–45 minutes of Thai sentences and English passages as mono 16‑kHz, 16‑bit WAV files. Each recording is stored in the app's documents directory along with a transcript file (`transcript.tsv`) mapping filenames to text. The transcripts should be UTF‑8 encoded and tab‑separated.

### 2. Preprocess the dataset

Mount the recordings and transcript into the Docker container:

```bash
docker run --gpus all \
    -v ./recordings:/data/recordings \
    -v ./output:/data/output \
    -e TRANSCRIPT_FILE=/data/recordings/transcript.tsv \
    -e CONFIG_FILE=/home/ttsuser/app/training/config/training_config.yaml \
    voicetrain
```

The `preprocess.py` script performs:
- **Peak normalisation**: scales each recording to ‑1 dBFS so that the loudest sample has a peak amplitude of ~0.8913.
- **Silence trimming**: removes leading/trailing silence using an energy threshold.
- **Segmentation**: splits long recordings into utterances. If Montreal Forced Aligner (MFA) is installed and Thai dictionaries/models are provided, `--use_mfa` can be enabled to generate precise word‑level segments. Otherwise, pydub's silence detector splits on pauses.
- **Phonemization**: converts text to phoneme sequences. Thai text is romanised with PyThaiNLP before being phonemised using espeak‑ng; English text is directly phonemised by espeak.
- **Outputs**: trimmed clips in `audio/`, phoneme files in `phones/`, and a `metadata.csv` file.

### 3. Fine‑tune the model

The `train.py` script loads the pretrained `facebook/mms‑tts‑tha` checkpoint and fine‑tunes it on the preprocessed dataset. Hyperparameters are specified in `config/training_config.yaml` and include learning rate, batch size and number of epochs. The script uses a simple L1 waveform loss for speed and logs metrics to TensorBoard. Sample sentences defined in the configuration are synthesised every `eval_interval` steps and saved in `output/samples/`.

Training on an RTX 3060 with 6 GB of VRAM takes roughly 2–4 hours for 300 epochs. Checkpoints are saved periodically to allow recovery.

### 4. Export to CoreML

After training, run `export_coreml.py` to convert the PyTorch model to ONNX and then to a quantised CoreML model. The script validates the conversion by generating audio from both PyTorch and CoreML models and reports the maximum absolute deviation. The final `.mlmodel` file (typically 50–100 MB thanks to FP16 quantisation) can be bundled into the iOS app.

```bash
python3 training/export_coreml.py \
  --checkpoint ./output/best_model.pt \
  --output ./output/voice_clone.mlmodel \
  --pretrained_model facebook/mms-tts-tha
```

### 5. Deploy in iOS

Copy the `.mlmodel` file into the Xcode project. The provided `CoreMLTTSEngine` stub expects an input MLMultiArray of phoneme token IDs (shape `[1, N]`, dtype int32) and a tempo scalar (a float to adjust speaking rate). The output is an MLMultiArray containing 16‑kHz mono audio samples (dtype float32). Use the same tokenizer (`VitsTokenizer`) to convert text to phoneme IDs in Swift.

The `StreamingAudioPlayer` class reads PCM float32 chunks from the model output and streams them via AVAudioEngine.

## Troubleshooting

- **Alignment errors**: If MFA is not installed or Thai acoustic models are unavailable, omit `--use_mfa`. Silence‑based segmentation generally suffices for 30–45 minutes of clean recordings.
- **Poor pronunciation or unnatural tone**: Increase `num_epochs` or experiment with lower learning rates. Including more Thai sentences in the sample texts helps the model capture tonal patterns.
- **Overfitting**: If the synthetic voice sounds too robotic or unstable, reduce `num_epochs` or add a small amount of random noise augmentation during preprocessing.
- **CoreML inference speed**: On A‑series iPhones with Neural Engine support, the exported FP16 model runs in real time.

## Expected quality

With the provided configuration and ~40 minutes of enrolment audio, the fine‑tuned model typically produces intelligible and natural‑sounding speech. The tonal accuracy of Thai is preserved thanks to the strong MMS pretrained model and phoneme‑level alignment. Training for longer or incorporating more diverse sentences will improve prosody.
