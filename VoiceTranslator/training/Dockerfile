FROM nvidia/cuda:12.3.2-cudnn8-runtime-ubuntu22.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    wget \
    espeak-ng \
    ffmpeg \
    python3-pip \
    python3-dev \
    libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# Create a non‑root user to avoid permission issues when mounting volumes
RUN useradd -ms /bin/bash ttsuser
USER ttsuser
WORKDIR /home/ttsuser/app

# Copy training code
COPY --chown=ttsuser:ttsuser . .

# Install Python dependencies
RUN pip install --no-cache-dir -r training/requirements.txt

# Expose a default data directory for recordings and outputs
VOLUME ["/data/recordings", "/data/output"]

# When the container starts, run preprocessing, training and CoreML export.
# The ENTRYPOINT script expects the following environment variables:
#   TRANSCRIPT_FILE – path to a CSV or TSV mapping audio file names to text
#   CONFIG_FILE     – YAML file with hyperparameters
#   OUTPUT_DIR      – directory where checkpoints and CoreML model are written
ENTRYPOINT ["bash", "-lc", "python3 training/preprocess.py --recordings /data/recordings --transcript $TRANSCRIPT_FILE --output /home/ttsuser/preprocessed && \\
python3 training/train.py --data /home/ttsuser/preprocessed --config $CONFIG_FILE --output $OUTPUT_DIR && \\
python3 training/export_coreml.py --checkpoint $OUTPUT_DIR/best_model.pt --output $OUTPUT_DIR/model.mlmodel"]