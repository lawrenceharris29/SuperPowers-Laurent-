#!/usr/bin/env python3
"""
Fine‑tune a VITS text‑to‑speech model on a small Thai/English speech dataset.

This script loads a pretrained VITS checkpoint from the Hugging Face Hub (by
default the Massively Multilingual Speech Thai model), tokenises phoneme
transcriptions and trains the model to synthesise the provided speech
waveforms. The training loop uses a simple L1 loss between the predicted and
target waveforms; although more sophisticated losses (e.g. adversarial or
multi‑scale spectrogram losses) can produce higher fidelity, this approach
trades off quality for ease of implementation and fast convergence on a small
dataset. Hyperparameters are configurable via a YAML file.

During training the script periodically synthesises a set of sample sentences
defined in the configuration and writes them to the output directory for
qualitative evaluation. Training progress is logged to TensorBoard.

Usage:

    python train.py --data ./preprocessed --config training_config.yaml --output ./output

The preprocessed directory must contain a metadata.csv file and two
subdirectories called `audio` and `phones` created by `preprocess.py`.
"""

import argparse
import dataclasses
import logging
import os
import sys
import yaml
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np
import torch
import torchaudio
from torch.utils.data import Dataset, DataLoader
from torch.nn.utils.rnn import pad_sequence
from torch.optim import AdamW
from torch.utils.tensorboard import SummaryWriter
from transformers import VitsTokenizer, VitsModel

logger = logging.getLogger(__name__)


@dataclass
class Config:
    pretrained_model: str
    learning_rate: float
    batch_size: int
    num_epochs: int
    warmup_steps: int
    save_interval: int
    eval_interval: int
    sample_texts: List[str]
    seed: int = 42


class TTSDataset(Dataset):
    """Dataset of phoneme/token ID sequences and target waveforms."""

    def __init__(self, meta_path: Path, audio_dir: Path, phones_dir: Path,
                 tokenizer: VitsTokenizer):
        self.entries = []
        with open(meta_path, "r", encoding="utf-8") as f:
            lines = f.readlines()[1:]  # skip header
        for line in lines:
            clip_name, _text, phonemes = line.strip().split(",", 2)
            self.entries.append((clip_name.strip(), phonemes.strip()))
        self.audio_dir = audio_dir
        self.phones_dir = phones_dir
        self.tokenizer = tokenizer

    def __len__(self) -> int:
        return len(self.entries)

    def __getitem__(self, idx: int):
        clip_name, phonemes = self.entries[idx]
        # Load audio as float32 [-1,1]
        wav_path = self.audio_dir / clip_name
        waveform, sr = torchaudio.load(str(wav_path))  # returns (channels, samples)
        waveform = waveform.squeeze(0)  # mono
        # Tokenise phonemes: we treat phoneme strings as text since VitsTokenizer
        # expects characters; unknown symbols will be ignored.
        # We add a leading space to signal start of sentence and normalise
        tokenized = self.tokenizer(phonemes, return_tensors="pt")
        input_ids = tokenized["input_ids"].squeeze(0)
        return input_ids, waveform


def collate_fn(batch: List[Any]) -> Dict[str, Any]:
    """Pads sequences of token IDs and stacks waveforms."""
    input_ids_list, waveforms = zip(*batch)
    # Pad input_ids to longest sequence
    padded_ids = pad_sequence(input_ids_list, batch_first=True, padding_value=0)
    attention_mask = (padded_ids != 0).long()
    # For waveforms, pad to longest waveform in batch
    max_len = max(wave.shape[0] for wave in waveforms)
    padded_waves = []
    for wave in waveforms:
        if wave.shape[0] < max_len:
            pad_len = max_len - wave.shape[0]
            wave = torch.cat([wave, torch.zeros(pad_len, dtype=wave.dtype)], dim=0)
        padded_waves.append(wave)
    stacked_waves = torch.stack(padded_waves)
    return {
        "input_ids": padded_ids,
        "attention_mask": attention_mask,
        "waveform": stacked_waves,
    }


def load_config(path: str) -> Config:
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    return Config(**cfg)


def set_seed(seed: int) -> None:
    torch.manual_seed(seed)
    np.random.seed(seed)
    torch.cuda.manual_seed_all(seed)


def save_checkpoint(model: VitsModel, optimizer: AdamW, step: int, path: Path) -> None:
    state = {
        "model_state_dict": model.state_dict(),
        "optimizer_state_dict": optimizer.state_dict(),
        "step": step,
    }
    torch.save(state, path)


def train(args: argparse.Namespace) -> None:
    config: Config = load_config(args.config)
    set_seed(config.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    # Load tokenizer and model
    logger.info("Loading pretrained model: %s", config.pretrained_model)
    tokenizer = VitsTokenizer.from_pretrained(config.pretrained_model)
    model = VitsModel.from_pretrained(config.pretrained_model)
    model = model.to(device)
    model.train()
    # Load dataset
    meta_path = Path(args.data) / "metadata.csv"
    audio_dir = Path(args.data) / "audio"
    phones_dir = Path(args.data) / "phones"
    dataset = TTSDataset(meta_path, audio_dir, phones_dir, tokenizer)
    dataloader = DataLoader(dataset, batch_size=config.batch_size, shuffle=True,
                            collate_fn=collate_fn, num_workers=0)
    # Optimizer
    optimizer = AdamW(model.parameters(), lr=config.learning_rate)
    # TensorBoard writer
    writer = SummaryWriter(log_dir=Path(args.output) / "runs")
    global_step = 0
    # Precompute sample text tokens for evaluation
    sample_inputs = []
    for text in config.sample_texts:
        # Convert to phonemes using simple romanization (for Thai) and tokenise
        lang_hint = "th" if any('ก' <= ch <= '๙' for ch in text) else "en"
        from preprocess import text_to_phonemes  # type: ignore
        phones = text_to_phonemes(text, lang_hint)
        toks = tokenizer(phones, return_tensors="pt")
        sample_inputs.append((text, toks["input_ids"].to(device), toks["attention_mask"].to(device)))
    # Training loop
    for epoch in range(config.num_epochs):
        for batch in dataloader:
            optimizer.zero_grad()
            input_ids = batch["input_ids"].to(device)
            attention_mask = batch["attention_mask"].to(device)
            target_waveforms = batch["waveform"].to(device)
            # Generate audio
            outputs = model(input_ids=input_ids, attention_mask=attention_mask)
            pred_waveforms = outputs.waveform  # shape (batch, samples)
            # Pad or crop predicted waveforms to match target length
            min_len = min(pred_waveforms.shape[1], target_waveforms.shape[1])
            loss = torch.nn.functional.l1_loss(pred_waveforms[:, :min_len],
                                               target_waveforms[:, :min_len])
            loss.backward()
            optimizer.step()
            global_step += 1
            if global_step % 10 == 0:
                writer.add_scalar('train/loss', loss.item(), global_step)
            # Evaluation and checkpointing
            if global_step % config.eval_interval == 0:
                model.eval()
                with torch.no_grad():
                    for i, (orig_text, inp_ids, attn_mask) in enumerate(sample_inputs):
                        outputs = model(input_ids=inp_ids, attention_mask=attn_mask)
                        audio = outputs.waveform[0].cpu().numpy()
                        # Write audio to file
                        out_dir = Path(args.output) / "samples"
                        out_dir.mkdir(parents=True, exist_ok=True)
                        out_path = out_dir / f"step{global_step:06d}_sample{i}.wav"
                        import soundfile as sf  # local import to avoid top level dependency
                        sf.write(out_path, audio, samplerate=model.config.sampling_rate)
                model.train()
            if global_step % config.save_interval == 0:
                ckpt_dir = Path(args.output)
                ckpt_dir.mkdir(parents=True, exist_ok=True)
                ckpt_path = ckpt_dir / f"checkpoint_{global_step:06d}.pt"
                save_checkpoint(model, optimizer, global_step, ckpt_path)
        logger.info("Epoch %d complete, latest loss %.4f", epoch + 1, loss.item())
    # Save final model
    final_ckpt = Path(args.output) / "best_model.pt"
    save_checkpoint(model, optimizer, global_step, final_ckpt)
    logger.info("Training complete. Best model saved to %s", final_ckpt)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Fine‑tune a VITS model on a custom dataset")
    parser.add_argument("--data", type=str, required=True, help="Path to preprocessed data directory")
    parser.add_argument("--config", type=str, required=True, help="YAML configuration file")
    parser.add_argument("--output", type=str, required=True, help="Directory to save checkpoints and samples")
    parser.add_argument("--log_level", type=str, default="INFO")
    args = parser.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.INFO),
                        format="[%(levelname)s] %(message)s")
    try:
        train(args)
    except KeyboardInterrupt:
        logger.warning("Training interrupted by user")
    return 0


if __name__ == "__main__":
    sys.exit(main())
