"""Multilingual place lexicon and room-number parsing."""
import pytest

from inview_worker.contracts import PlaceCategory
from inview_worker.semantics import place_lexicon, room_numbers


def categories(text: str) -> list[str]:
    return [m.category for m in place_lexicon.load().match(text)]


@pytest.mark.parametrize("text, category, language", [
    ("Restroom", "restroom", "en"), ("TOILETS", "restroom", "en"), ("WC", "restroom", "en"),
    ("Baños", "restroom", "es"), ("ASEOS", "restroom", "es"), ("Toilettes", "restroom", "fr"),
    ("Toiletten", "restroom", "de"), ("Casa de banho", "restroom", "pt"), ("Bagni", "restroom", "it"),
    ("卫生间", "restroom", "zh"), ("トイレ", "restroom", "ja"), ("화장실", "restroom", "ko"),
    ("دورات المياه", "restroom", "ar"), ("शौचालय", "restroom", "hi"),
    ("EXIT", "exit", "en"), ("Salida", "exit", "es"), ("SORTIE", "exit", "fr"), ("Ausgang", "exit", "de"),
    ("Saída", "exit", "pt"), ("Uscita", "exit", "it"), ("مخرج", "exit", "ar"), ("निकास", "exit", "hi"),
    ("출구", "exit", "ko"),
    ("Elevator", "elevator", "en"), ("Lift", "elevator", "en"), ("Ascensor", "elevator", "es"),
    ("Ascenseur", "elevator", "fr"), ("Aufzug", "elevator", "de"), ("Elevador", "elevator", "es"),
    ("电梯", "elevator", "zh"), ("エレベーター", "elevator", "ja"), ("엘리베이터", "elevator", "ko"),
    ("مصعد", "elevator", "ar"), ("लिफ्ट", "elevator", "hi"),
    ("Stairs", "stairs", "en"), ("Escaleras", "stairs", "es"), ("Treppe", "stairs", "de"), ("階段", "stairs", "ja"),
    ("Information", "information", "en"), ("Información", "information", "es"), ("案内所", "information", "ja"),
    ("Reception", "reception", "en"), ("Empfang", "reception", "de"), ("受付", "reception", "ja"),
    ("First aid", "first_aid", "en"), ("Primeros auxilios", "first_aid", "es"), ("Erste Hilfe", "first_aid", "de"),
    ("Emergency exit", "emergency_exit", "en"), ("Notausgang", "emergency_exit", "de"), ("非常口", "emergency_exit", "ja"),
    ("Sortie de secours", "emergency_exit", "fr"), ("Accessible toilet", "accessible_restroom", "en"),
    ("Toilettes PMR", "accessible_restroom", "fr"), ("多目的トイレ", "accessible_restroom", "ja"),
    ("Entrance", "entrance", "en"), ("Eingang", "entrance", "de"), ("Rampa", "ramp", "es"),
])
def test_multilingual_terms_match_their_category(text, category, language):
    match = place_lexicon.load().match(text)[0]
    assert match.category == category
    assert match.exact
    assert language in place_lexicon.load().languages_of(match.term)
    assert PlaceCategory(category)


def test_normalisation_handles_case_accents_full_width_and_arabic_variants():
    assert place_lexicon.normalize("ＥＸＩＴ") == "exit"
    assert place_lexicon.normalize("BAÑOS") == "banos"
    assert place_lexicon.normalize("Feuerlöscher") == "feuerloscher"
    assert place_lexicon.normalize("مَخْرَج") == "مخرج"
    assert categories("ＥＸＩＴ") == ["exit"]


def test_longer_terms_shadow_the_words_inside_them():
    assert categories("EMERGENCY EXIT") == ["emergency_exit"]
    assert categories("Salida de emergencia") == ["emergency_exit"]
    assert categories("Accessible restroom") == ["accessible_restroom"]
    assert sorted(categories("Entrance / Exit")) == ["entrance", "exit"]


def test_negations_veto_their_category():
    for text in ("NOT AN EXIT", "No exit", "Sin salida", "Pas de sortie", "Kein Ausgang", "非出口"):
        assert "exit" not in categories(text), text
    assert "entrance" not in categories("No entry")
    assert "entrance" not in categories("立入禁止")
    for text in ("NOT AN EMERGENCY EXIT", "NOT A FIRE EXIT", "非常口ではありません"):
        assert not {"exit", "emergency_exit"} & set(categories(text))


def test_term_readings_keep_bilingual_evidence_for_one_category():
    matches = place_lexicon.load().match_terms("Toilets / Aseos")
    assert {(m.category, m.language) for m in matches} == {("restroom", "en"), ("restroom", "es")}
    assert categories("Toilets / Aseos") == ["restroom"]


def test_latin_terms_need_word_boundaries_but_cjk_and_korean_do_not():
    assert categories("exiting traffic") == []
    assert categories("Toiletries") == []
    assert categories("화장실은 2층") == ["restroom"]          # Korean particle attached
    assert categories("请使用电梯") == ["elevator"]             # no spaces in Chinese
    assert categories("女") == ["restroom"] and categories("女士用品") == []  # 1-char terms only whole


def test_script_detection():
    assert place_lexicon.script("トイレ") == "Jpan"
    assert place_lexicon.script("卫生间") == "Hani"
    assert place_lexicon.script("화장실") == "Hang"
    assert place_lexicon.script("مخرج") == "Arab"
    assert place_lexicon.script("निकास") == "Deva"
    assert place_lexicon.script("Exit") == "Latn"
    assert place_lexicon.script("214") is None


def test_every_category_has_display_names_in_every_language():
    lexicon = place_lexicon.load()
    for category, names in lexicon.names.items():
        assert PlaceCategory(category)
        assert set(names) == set(lexicon.languages), category


@pytest.mark.parametrize("text, number, confidence, language", [
    ("Room 214", "214", 0.9, "en"), ("Rm. 3.12", "3.12", 0.9, "en"), ("RM 3.12", "3.12", 0.9, "en"),
    ("Suite 100B", "100B", 0.9, "en"), ("Salle 12", "12", 0.9, "fr"), ("Raum 1.04", "1.04", 0.9, "de"),
    ("Sala 7", "7", 0.9, None), ("Aula 12", "12", 0.9, None), ("301号室", "301", 0.9, "ja"),
    ("301室", "301", 0.9, None), ("301호", "301", 0.9, "ko"), ("غرفة ٢١٤", "214", 0.9, "ar"),
    ("कमरा 5", "5", 0.9, "hi"), ("Room No. 12", "12", 0.9, "en"),
    ("214", "214", 0.55, None), ("B-204", "B-204", 0.55, None), ("12A", "12A", 0.55, None),
])
def test_room_numbers(text, number, confidence, language):
    parsed = room_numbers.parse(text)
    assert parsed == room_numbers.RoomNumber(number, confidence, language)


@pytest.mark.parametrize("text", ["B1", "L2", "7", "Exit 3", "Office hours", "EXIT", "", "12345", "10:30", "12/24", "3호선", "2号线"])
def test_not_room_numbers(text):
    assert room_numbers.parse(text) is None


def test_room_display_names_are_localised():
    names = room_numbers.display_names("214")
    assert names["en"] == "Room 214" and names["fr"] == "Salle 214" and names["ja"] == "214号室"
    assert names["ko"] == "214호" and names["ar"] == "غرفة 214"
