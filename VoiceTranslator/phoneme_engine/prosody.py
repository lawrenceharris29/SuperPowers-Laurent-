import json
from typing import Dict, Any, List


class ProsodyModel:
    """Generates prosody features for VITS input."""

    def __init__(self, sample_rate: int = 22050):
        self.sample_rate = sample_rate

    def estimate_prosody(self, ipa_string: str, original_text: str) -> Dict[str, Any]:
        """
        Estimate durations and pitch contours based on phonemes and tones.
        Returns a JSON-serializable dictionary.
        """
        words = ipa_string.split(" ")
        syllables = []
        durations = []
        pitch_contours = []

        for word in words:
            word_syllables = word.split(".")
            for i, syl in enumerate(word_syllables):
                syllables.append(syl)

                # Rule-based duration estimation
                # Base duration ~200ms
                dur = 200
                if "ː" in syl:  # Long vowel
                    dur += 100
                if i == len(word_syllables) - 1:  # Word final lengthening
                    dur += 50

                durations.append(dur)

                # Pitch contour based on IPA tone markers
                if "˧" in syl:
                    contour = [100, 100, 100]       # Mid
                elif "˨˩" in syl:
                    contour = [90, 80, 70]           # Low
                elif "˥˩" in syl:
                    contour = [120, 140, 80]         # Falling
                elif "˦˥" in syl:
                    contour = [110, 130, 150]        # High
                elif "˩˧˥" in syl:
                    contour = [80, 70, 130]          # Rising
                else:
                    contour = [100, 100, 100]

                pitch_contours.append(contour)

        # Apply phrase-final lengthening
        if durations:
            durations[-1] += 100

        # Check for question intonation (e.g. ไหม)
        if "ไหม" in original_text and pitch_contours:
            pitch_contours[-1] = [100, 120, 160]  # Shift up

        return {
            "phonemes": syllables,
            "syllable_durations_ms": durations,
            "pitch_contours": pitch_contours,
            "emphasis": [1.0] * len(syllables),
            "tempo": 1.0,
            "emotion": "neutral"
        }

    def to_json(self, prosody_data: Dict[str, Any]) -> str:
        return json.dumps(prosody_data, ensure_ascii=False)
