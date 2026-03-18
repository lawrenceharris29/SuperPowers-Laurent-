#!/usr/bin/env python3
"""
Export a fine‑tuned VITS PyTorch model to CoreML.

This script loads a checkpoint produced by `train.py`, exports the model to
ONNX and then converts the ONNX graph to a CoreML model. The resulting
`.mlmodel` file contains a single input for phoneme token IDs and produces
generated audio samples as a float32 MLMultiArray. Quantisation to FP16 is
enabled by default to reduce the model size for deployment on iOS devices.

After conversion the script validates the CoreML model by generating audio
from a randomly chosen phoneme sequence and computing the maximum absolute
deviation between the PyTorch and CoreML outputs.

Usage:

    python export_coreml.py --checkpoint ./output/best_model.pt --output ./output/model.mlmodel

"""

import argparse
import logging
from pathlib import Path
import tempfile

import numpy as np
import torch
import coremltools as ct
import onnx
import onnxruntime as ort
from transformers import VitsModel, VitsTokenizer

logger = logging.getLogger(__name__)


def load_model(checkpoint_path: Path, pretrained_model: str) -> VitsModel:
    """Loads the pretrained model and applies fine‑tuned weights."""
    model = VitsModel.from_pretrained(pretrained_model)
    state = torch.load(checkpoint_path, map_location="cpu")
    model.load_state_dict(state["model_state_dict"], strict=False)
    model.eval()
    return model


def export_to_onnx(model: VitsModel, tokenizer: VitsTokenizer, onnx_path: Path) -> None:
    """Exports a VITS model to ONNX with dynamic input lengths."""
    # Create a dummy input with a reasonable length
    dummy_text = "Hello"
    dummy_tokens = tokenizer(dummy_text, return_tensors="pt")
    input_ids = dummy_tokens["input_ids"]
    attention_mask = dummy_tokens["attention_mask"]
    # Export
    dynamic_axes = {
        "input_ids": {1: "seq_len"},
        "attention_mask": {1: "seq_len"},
        "waveform": {1: "audio_len"},
    }
    torch.onnx.export(
        model,
        args=(input_ids, attention_mask),
        f=str(onnx_path),
        input_names=["input_ids", "attention_mask"],
        output_names=["waveform"],
        dynamic_axes=dynamic_axes,
        opset_version=15,
    )
    logger.info("ONNX model exported to %s", onnx_path)


def convert_to_coreml(onnx_path: Path, mlmodel_path: Path) -> None:
    """Converts an ONNX model to CoreML and quantises to FP16."""
    mlmodel = ct.converters.onnx.convert(
        model=str(onnx_path),
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    # Convert parameters to FP16
    mlmodel_fp16 = ct.utils.convert_neural_network_weights_to_fp16(mlmodel)
    mlmodel_fp16.save(str(mlmodel_path))
    logger.info("CoreML model saved to %s", mlmodel_path)


def validate(model: VitsModel, tokenizer: VitsTokenizer, mlmodel_path: Path) -> None:
    """Validates the CoreML model by comparing outputs against PyTorch."""
    # Choose a random sequence of phonemes (English and Thai digits) for validation
    text = "สวัสดีครับ"  # Hello in Thai
    tokens = tokenizer(text, return_tensors="pt")
    input_ids = tokens["input_ids"]
    attention_mask = tokens["attention_mask"]
    # PyTorch inference
    with torch.no_grad():
        pt_wave = model(input_ids=input_ids, attention_mask=attention_mask).waveform[0].numpy()
    # CoreML inference
    mlmodel = ct.models.MLModel(str(mlmodel_path))
    # Prepare CoreML input: must be dictionary with MLMultiArray values
    import coremltools.proto.FeatureTypes_pb2 as ft
    inp = {
        "input_ids": input_ids.numpy().astype(np.int32),
        "attention_mask": attention_mask.numpy().astype(np.int32),
    }
    result = mlmodel.predict(inp)
    cm_wave = result["waveform"].flatten().astype(np.float32)
    # Align lengths
    min_len = min(len(pt_wave), len(cm_wave))
    diff = np.max(np.abs(pt_wave[:min_len] - cm_wave[:min_len]))
    logger.info("Maximum absolute deviation between PyTorch and CoreML outputs: %.6f", diff)


def main() -> None:
    parser = argparse.ArgumentParser(description="Export a fine‑tuned VITS model to CoreML")
    parser.add_argument("--checkpoint", type=str, required=True, help="Path to .pt checkpoint file")
    parser.add_argument("--output", type=str, required=True, help="Path to save the .mlmodel file")
    parser.add_argument("--pretrained_model", type=str, default="facebook/mms-tts-tha",
                        help="Name of the pretrained model used during training (for config)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    checkpoint_path = Path(args.checkpoint)
    mlmodel_path = Path(args.output)
    tokenizer = VitsTokenizer.from_pretrained(args.pretrained_model)
    model = load_model(checkpoint_path, args.pretrained_model)
    # Export to ONNX in a temporary directory
    with tempfile.TemporaryDirectory() as tmpdir:
        onnx_path = Path(tmpdir) / "model.onnx"
        export_to_onnx(model, tokenizer, onnx_path)
        convert_to_coreml(onnx_path, mlmodel_path)
    validate(model, tokenizer, mlmodel_path)


if __name__ == "__main__":
    main()
