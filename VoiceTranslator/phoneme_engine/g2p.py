import json
import re
from typing import List
from pythainlp.tokenize import word_tokenize
from pythainlp.transliterate import thaig2p


class ThaiG2P:
    """Thai Grapheme-to-Phoneme converter using PyThaiNLP."""

    def __init__(self, phoneme_dict_path: str = "thai_phonemes.json"):
        with open(phoneme_dict_path, 'r', encoding='utf-8') as f:
            self.phoneme_data = json.load(f)

        self.tone_map = self.phoneme_data["tones"]
        self.vocab = self.phoneme_data["vocab"]

    def _map_tone_to_ipa(self, ipa_string: str) -> str:
        """Map numeric tones from PyThaiNLP to precise IPA tone markers."""
        for num, marker in self.tone_map.items():
            ipa_string = ipa_string.replace(num, marker)
            # PyThaiNLP sometimes outputs superscript like ⁰¹²³⁴
            superscripts = {"⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4"}
            for sup, n in superscripts.items():
                if sup in ipa_string:
                    ipa_string = ipa_string.replace(sup, self.tone_map[n])
        return ipa_string

    def convert(self, text: str) -> str:
        """
        Convert Thai text to IPA string with tone markers and syllable boundaries.
        e.g. "สวัสดี" -> "sa˨˩.wat̚˨˩.diː˧"
        """
        # Strip digits (stubbed number handling)
        text = re.sub(r'\d+', '', text)

        words = word_tokenize(text, engine="newmm")
        ipa_words = []

        for word in words:
            if not word.strip():
                continue
            # thaig2p returns syllable separated by '-'
            raw_ipa = thaig2p(word)
            syllables = raw_ipa.split('-')

            # Map tones and join syllables with '.'
            mapped_syllables = [self._map_tone_to_ipa(s) for s in syllables]
            ipa_words.append(".".join(mapped_syllables))

        return " ".join(ipa_words)

    def encode(self, ipa_string: str) -> List[int]:
        """Convert IPA string to list of token IDs for TTS model."""
        tokens = []
        i = 0
        sorted_vocab_keys = sorted(self.vocab.keys(), key=len, reverse=True)

        while i < len(ipa_string):
            match = False
            for key in sorted_vocab_keys:
                if key != "<pad>" and key != "<unk>" and ipa_string.startswith(key, i):
                    tokens.append(self.vocab[key])
                    i += len(key)
                    match = True
                    break
            if not match:
                tokens.append(self.vocab["<unk>"])
                i += 1
        return tokens
