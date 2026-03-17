import pytest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from prosody import ProsodyModel


def test_prosody_generation():
    model = ProsodyModel()
    ipa = "sa˨˩.wat̚˨˩.diː˧ kʰrap̚˦˥"
    original = "สวัสดีครับ"

    data = model.estimate_prosody(ipa, original)

    assert "syllable_durations_ms" in data
    assert "pitch_contours" in data
    assert len(data["syllable_durations_ms"]) == 4  # sa, wat, di, krap
    assert data["pitch_contours"][2] == [100, 100, 100]  # diː˧ (mid tone)
    assert data["pitch_contours"][3] == [110, 130, 150]  # kʰrap̚˦˥ (high tone)
