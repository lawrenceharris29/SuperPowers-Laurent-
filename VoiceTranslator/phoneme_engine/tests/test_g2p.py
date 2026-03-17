import pytest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from g2p import ThaiG2P


@pytest.fixture
def g2p():
    return ThaiG2P(phoneme_dict_path=os.path.join(
        os.path.dirname(__file__), "..", "..", "ios", "VoiceTranslator", "Resources", "thai_phonemes.json"
    ))


def test_minimal_pairs(g2p):
    assert g2p.convert("กา") == "kaː˧"
    assert g2p.convert("ก่า") == "kaː˨˩"
    assert g2p.convert("ก้า") == "kaː˥˩"
    assert g2p.convert("ก๊า") == "kaː˦˥"
    assert g2p.convert("ก๋า") == "kaː˩˧˥"


def test_common_words(g2p):
    # Depending on pythainlp version, exact IPA might vary slightly.
    # This validates pipeline execution and tone replacement.
    res = g2p.convert("สวัสดีครับ")
    assert "sa" in res
    assert "wat̚" in res
    assert "kʰrap̚" in res
    assert "˥˩" in res or "˦˥" in res  # Tone marker check


def test_encode(g2p):
    ipa = "kaː˧"
    tokens = g2p.encode(ipa)
    assert len(tokens) > 0
    assert isinstance(tokens[0], int)
