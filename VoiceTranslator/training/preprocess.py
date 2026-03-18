#!/usr/bin/env python3
"""
Preprocessing pipeline for Thai voice cloning TTS fine‑tuning.

This script performs the following steps:
1. Reads all WAV files from a recordings directory and the accompanying
   transcript file (a CSV/TSV with two columns: filename and text).
2. Peak normalises each audio file to ‑1 dBFS to ensure consistent volume.
3. Trims leading and trailing silence using an energy‑based threshold.
4. Optionally segments long recordings into utterance‑level clips using
   Montreal Forced Aligner (MFA) if available. Alignment results are
   parsed from TextGrid files. When MFA is not installed, the script
   falls back to simple silence‑based segmentation using pydub.
5. Converts text to a phoneme sequence using the phonemizer library for
   English passages and PyThaiNLP for Thai text. Espeak‑NG is used via
   phonemizer to produce phonemic transcriptions.
6. Writes the processed clips and phoneme transcripts to an output
   directory in a format that training scripts can consume.

Usage:

    python preprocess.py --recordings ./recordings --transcript ./transcript.tsv \
        --output ./preprocessed

The transcript file should be tab‑separated with lines of the form:

    filename.wav   สวัสดีครับ นี่คือภาษาไทย
    another.wav    Hello world

The output directory will contain two subdirectories:

    audio/   – normalised, trimmed (and possibly segmented) audio clips (.wav)
    phones/  – one text file per clip containing a space‑separated list of
               phoneme tokens.

The script also writes a metadata.csv file mapping each clip to its
phonemic transcript and original text. This file can be used by the
training pipeline.
"""

import argparse
import csv
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import soundfile as sf
import librosa
from phonemizer import phonemize
from phonemizer.backend import EspeakBackend
import pydub
from pydub import AudioSegment
from pydub.silence import split_on_silence
from pythainlp import romanize
from praatio import tgio

logger = logging.getLogger(__name__)


def read_transcripts(transcript_path: Path) -> Dict[str, str]:
    """Reads a tab or comma separated transcript file.

    Returns a dictionary mapping file names (without extension) to raw text.
    """
    mapping: Dict[str, str] = {}
    with open(transcript_path, "r", encoding="utf-8") as f:
        reader = csv.reader(f, delimiter="\t")
        for row in reader:
            if not row:
                continue
            if len(row) < 2:
                logger.warning("Skipping malformed line in transcript: %s", row)
                continue
            name, text = row[0].strip(), row[1].strip()
            name_no_ext = os.path.splitext(name)[0]
            mapping[name_no_ext] = text
    return mapping


def peak_normalize(audio: np.ndarray) -> np.ndarray:
    """Normalises an audio waveform to ‑1 dBFS.

    The audio is assumed to be floating point in range [‑1.0, 1.0].
    """
    # ‑1 dBFS corresponds to a peak amplitude of 10**(-1/20) ≈ 0.8913
    target_peak = 10 ** (-1 / 20)
    max_amp = np.max(np.abs(audio))
    if max_amp == 0:
        return audio
    gain = target_peak / max_amp
    return np.clip(audio * gain, -1.0, 1.0)


def trim_silence(audio: np.ndarray, sr: int, top_db: float = 40.0) -> np.ndarray:
    """Trims leading and trailing silence from a waveform using librosa.

    Args:
        audio: 1‑D numpy array of audio samples.
        sr: Sample rate of the audio.
        top_db: Threshold in decibels below peak to consider as silence.

    Returns:
        Trimmed audio.
    """
    non_silent, _ = librosa.effects.trim(audio, top_db=top_db)
    return non_silent


def segment_with_mfa(wav_path: Path, text: str, mfa_model: str, mfa_dictionary: str,
                      temp_dir: Path) -> List[Tuple[np.ndarray, str]]:
    """Segments a long utterance into smaller clips using Montreal Forced Aligner.

    This function calls `mfa align` and reads the resulting TextGrid to
    determine segment boundaries.

    Args:
        wav_path: Path to the wave file.
        text: Corresponding transcription.
        mfa_model: Name of the pretrained MFA acoustic model (e.g. "thai_mfa" or
                   path to a .zip model file).
        mfa_dictionary: Path to an MFA compatible pronunciation dictionary.
        temp_dir: Temporary directory for MFA output.

    Returns:
        List of (audio_clip, transcript_fragment) tuples.
    """
    # Write a minimal dataset for MFA: wav and text file
    dataset_dir = temp_dir / "dataset"
    dataset_dir.mkdir(parents=True, exist_ok=True)
    wav_target = dataset_dir / wav_path.name
    # Copy audio into dataset folder
    if wav_target.resolve() != wav_path.resolve():
        wav_data, sr = sf.read(wav_path)
        sf.write(wav_target, wav_data, sr)
    with open(dataset_dir / (wav_path.stem + ".txt"), "w", encoding="utf-8") as f:
        f.write(text)
    # Run MFA alignment
    aligned_dir = temp_dir / "aligned"
    aligned_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "mfa", "align", str(dataset_dir), mfa_dictionary, mfa_model, str(aligned_dir),
        "--overwrite"
    ]
    logger.info("Running MFA: %s", " ".join(cmd))
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        logger.error("Montreal Forced Aligner (mfa) executable not found. "
                     "Install MFA or skip alignment.")
        return [(sf.read(wav_path)[0], text)]
    except subprocess.CalledProcessError as e:
        logger.error("MFA alignment failed: %s", e)
        return [(sf.read(wav_path)[0], text)]
    # Load TextGrid results
    tg_path = aligned_dir / wav_path.with_suffix(".TextGrid").name
    if not tg_path.exists():
        logger.error("Alignment file %s not found. Returning original audio.", tg_path)
        return [(sf.read(wav_path)[0], text)]
    tg = tgio.openTextgrid(tg_path)
    tier_name = tg.tierNameList[0]
    tier = tg.tierDict[tier_name]
    segments: List[Tuple[np.ndarray, str]] = []
    audio_data, sr = sf.read(wav_path)
    for interval in tier.entryList:
        start_time, end_time, label = interval
        if not label or label.strip() == "":
            continue
        start_sample = int(start_time * sr)
        end_sample = int(end_time * sr)
        clip = audio_data[start_sample:end_sample]
        segments.append((clip, label))
    return segments


def segment_with_silence(audio: AudioSegment, min_silence_len: int = 500,
                         silence_thresh: int = -40, keep_silence: int = 100) -> List[AudioSegment]:
    """Segments audio based on silence using pydub.

    Args:
        audio: pydub.AudioSegment object.
        min_silence_len: Minimum length of silence (ms) that will be used for a split.
        silence_thresh: Volume threshold (dBFS) below which is considered silence.
        keep_silence: Amount of silence (ms) to leave at the beginning and end of each segment.
    Returns:
        List of AudioSegment objects.
    """
    chunks = split_on_silence(audio, min_silence_len=min_silence_len,
                              silence_thresh=silence_thresh, keep_silence=keep_silence)
    return chunks


def text_to_phonemes(text: str, lang_hint: str = None) -> str:
    """Converts a raw text string to a sequence of phoneme tokens.

    For Thai, PyThaiNLP's romanize function is used to produce a Latin
    transcription which is subsequently phonemized using espeak-ng via
    phonemizer. For English and other languages, phonemizer is called directly.

    Args:
        text: Raw input text.
        lang_hint: Optional ISO‑639 language code. If provided and equal to
                   'th', Thai specific processing is applied.
    Returns:
        A space‑separated string of phoneme tokens.
    """
    # Normalise whitespace and remove problematic characters
    clean = " ".join(text.strip().split())
    if lang_hint == "th":
        # Romanize Thai to Latin script. This is a rough approximation but
        # provides a consistent representation for espeak‑ng.
        roman = romanize(clean)
        try:
            # Use espeak‑ng backend with Thai language to produce phonemes.
            phonemes = phonemize(roman, language="th", backend="espeak",
                                strip=True, language_switch="remove-flags")
        except Exception:
            # Fallback to romanised text split into characters
            phonemes = " ".join(list(roman))
    else:
        # Default to English phonemization using espeak
        try:
            phonemes = phonemize(clean, language="en", backend="espeak",
                                strip=True, language_switch="remove-flags")
        except Exception:
            phonemes = " ".join(list(clean))
    # Replace multiple spaces with a single space and return
    return " ".join(phonemes.split())


def process_recordings(recordings_dir: Path, transcripts: Dict[str, str],
                       output_dir: Path, use_mfa: bool = False,
                       mfa_model: str = None, mfa_dictionary: str = None) -> None:
    """Processes all recordings and saves processed clips and metadata.

    Args:
        recordings_dir: Directory containing WAV files.
        transcripts: Mapping of file stems to raw text.
        output_dir: Directory where processed data will be written.
        use_mfa: Whether to use Montreal Forced Aligner for segmentation.
        mfa_model: Name or path of the MFA acoustic model (required if
                   use_mfa is True).
        mfa_dictionary: Path to the pronunciation dictionary (required if
                        use_mfa is True).
    """
    audio_out = output_dir / "audio"
    phones_out = output_dir / "phones"
    audio_out.mkdir(parents=True, exist_ok=True)
    phones_out.mkdir(parents=True, exist_ok=True)
    metadata_path = output_dir / "metadata.csv"
    with open(metadata_path, "w", encoding="utf-8", newline="") as meta_f:
        writer = csv.writer(meta_f)
        writer.writerow(["clip", "text", "phonemes"])
        for wav_path in sorted(recordings_dir.glob("*.wav")):
            stem = wav_path.stem
            if stem not in transcripts:
                logger.warning("No transcript found for %s, skipping.", wav_path)
                continue
            text = transcripts[stem]
            logger.info("Processing %s", wav_path.name)
            # Load audio
            audio, sr = sf.read(wav_path, always_2d=False)
            # Convert int16 to float32 range [-1,1]
            if audio.dtype != np.float32:
                max_int = np.iinfo(audio.dtype).max
                audio = audio.astype(np.float32) / max_int
            # Normalise
            audio = peak_normalize(audio)
            # Trim silence
            audio = trim_silence(audio, sr)
            segments: List[Tuple[np.ndarray, str]] = []
            if use_mfa and mfa_model and mfa_dictionary:
                temp_dir = output_dir / "_mfa_temp" / stem
                temp_dir.mkdir(parents=True, exist_ok=True)
                segments = segment_with_mfa(wav_path, text, mfa_model, mfa_dictionary, temp_dir)
            else:
                # Simple silence based segmentation
                seg_audio = AudioSegment(
                    audio.tobytes(), frame_rate=sr, sample_width=audio.dtype.itemsize,
                    channels=1
                )
                chunks = segment_with_silence(seg_audio)
                for chunk in chunks:
                    # Convert back to numpy
                    data = np.array(chunk.get_array_of_samples()).astype(np.float32)
                    data /= 2 ** 15  # 16 bit signed
                    segments.append((data, text))
            # Determine language hint: Thai if text contains Thai characters
            lang_hint = "th" if any('ก' <= ch <= '๙' for ch in text) else "en"
            phoneme_cache: Dict[str, str] = {}
            for i, (clip, transcript_fragment) in enumerate(segments):
                # Compute phonemes; cache by transcript to avoid repeated calls
                if transcript_fragment not in phoneme_cache:
                    phoneme_cache[transcript_fragment] = text_to_phonemes(transcript_fragment, lang_hint)
                phonemes = phoneme_cache[transcript_fragment]
                clip_name = f"{stem}_{i:03d}.wav"
                clip_path = audio_out / clip_name
                # Save audio
                sf.write(clip_path, clip, sr, subtype='PCM_16')
                # Save phoneme file
                phones_file = phones_out / f"{stem}_{i:03d}.txt"
                with open(phones_file, "w", encoding="utf-8") as pf:
                    pf.write(phonemes)
                writer.writerow([clip_name, transcript_fragment, phonemes])
    logger.info("Processing complete. Metadata written to %s", metadata_path)


def main(argv: List[str] = None) -> int:
    parser = argparse.ArgumentParser(description="Preprocess speech dataset for TTS fine‑tuning")
    parser.add_argument("--recordings", type=str, required=True,
                        help="Directory containing WAV recordings (16kHz, 16‑bit, mono)")
    parser.add_argument("--transcript", type=str, required=True,
                        help="Path to transcript file mapping filename to text (tab separated)")
    parser.add_argument("--output", type=str, required=True,
                        help="Directory where preprocessed data will be stored")
    parser.add_argument("--use_mfa", action="store_true",
                        help="Use Montreal Forced Aligner for segmentation instead of silence based")
    parser.add_argument("--mfa_model", type=str, default=None,
                        help="MFA acoustic model (name or path). Required if --use_mfa is set")
    parser.add_argument("--mfa_dictionary", type=str, default=None,
                        help="Path to MFA pronunciation dictionary. Required if --use_mfa is set")
    parser.add_argument("--log_level", type=str, default="INFO",
                        help="Logging level (DEBUG, INFO, WARNING, ERROR)")
    args = parser.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.INFO),
                        format="[%(levelname)s] %(message)s")

    recordings_dir = Path(args.recordings)
    transcript_path = Path(args.transcript)
    output_dir = Path(args.output)

    if not recordings_dir.is_dir():
        logger.error("Recordings directory %s not found", recordings_dir)
        return 1
    if not transcript_path.exists():
        logger.error("Transcript file %s not found", transcript_path)
        return 1
    transcripts = read_transcripts(transcript_path)
    logger.info("Loaded %d transcript entries", len(transcripts))
    process_recordings(recordings_dir, transcripts, output_dir,
                       use_mfa=args.use_mfa, mfa_model=args.mfa_model, mfa_dictionary=args.mfa_dictionary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
