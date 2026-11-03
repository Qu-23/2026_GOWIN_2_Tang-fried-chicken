#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_scores.py —— 生成手机 App 用的在线曲谱库 (web/scores/*.json + index.json)

每首歌曲保留 notes 主旋律供旧版/脱机 S/K 协议使用；tracks 明确网页演奏音色。
演示曲库仅《小星星》使用双音色合奏，其余曲目为电钢或大提琴独奏。
合奏通过逐音指定音色的 A5 二进制帧发送，不能用 S/K 文本表示。
旧版曲谱格式:
    S<tempo>          速度 40..240 BPM
    K<note>,<beats>   note = MIDI 音号, 0 = 休止; beats 以四分音符为 1

音域限制: 固件 note_table.v 只有 MIDI 60..84 (C4..C6) 25 个音，
   超出范围的音在板子上会被钳位到两端，所以生成时直接拦下来报错。

用法:
    python tools/gen_scores.py
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "web", "scores"))

LO, HI = 60, 84          # C4..C6

NAMES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def n(s):
    """'C4' / 'F#5' / 'Bb4' -> MIDI 号"""
    p = s.strip()
    if p in ("-", "R", "r", "0"):
        return 0
    i = 1
    semi = NAMES[p[0].upper()]
    while i < len(p) and p[i] in "#b":
        semi += 1 if p[i] == "#" else -1
        i += 1
    octv = int(p[i:])
    return 12 * (octv + 1) + semi


def seq(spec):
    """'C4/1 D4/0.5 R/0.5' -> [[60,1],[62,0.5],[0,0.5]]"""
    out = []
    for tok in spec.split():
        if "/" in tok:
            a, b = tok.split("/")
        else:
            a, b = tok, "1"
        out.append([n(a), float(b)])
    return out


def song(name, author, tempo, spec, desc=""):
    notes = seq(spec)
    for note, _ in notes:
        if note != 0 and not (LO <= note <= HI):
            raise SystemExit("%s: 音 %d 超出固件音域 %d..%d" % (name, note, LO, HI))
    return {"name": name, "author": author, "tempo": tempo,
            "desc": desc, "notes": notes}


SONGS = [
    song("小星星", "法国民谣", 96,
         "C4/1 C4/1 G4/1 G4/1 A4/1 A4/1 G4/2 "
         "F4/1 F4/1 E4/1 E4/1 D4/1 D4/1 C4/2 "
         "G4/1 G4/1 F4/1 F4/1 E4/1 E4/1 D4/2 "
         "G4/1 G4/1 F4/1 F4/1 E4/1 E4/1 D4/2 "
         "C4/1 C4/1 G4/1 G4/1 A4/1 A4/1 G4/2 "
         "F4/1 F4/1 E4/1 E4/1 D4/1 D4/1 C4/2",
         "最基础的 C 大调儿歌，用来验音准和连奏"),

    song("欢乐颂", "贝多芬", 108,
         "E4/1 E4/1 F4/1 G4/1 G4/1 F4/1 E4/1 D4/1 "
         "C4/1 C4/1 D4/1 E4/1 E4/1.5 D4/0.5 D4/2 "
         "E4/1 E4/1 F4/1 G4/1 G4/1 F4/1 E4/1 D4/1 "
         "C4/1 C4/1 D4/1 E4/1 D4/1.5 C4/0.5 C4/2 "
         "D4/1 D4/1 E4/1 C4/1 D4/1 E4/0.5 F4/0.5 E4/1 C4/1 "
         "D4/1 E4/0.5 F4/0.5 E4/1 D4/1 C4/1 D4/1 G3/2 "
         "E4/1 E4/1 F4/1 G4/1 G4/1 F4/1 E4/1 D4/1 "
         "C4/1 C4/1 D4/1 E4/1 D4/1.5 C4/0.5 C4/2".replace("G3/2", "C4/1 D4/1"),
         "古典旋律，跨度大，能听出电钢的动态"),

    song("卡农（片段）", "帕赫贝尔", 72,
         "C5/1 B4/1 A4/1 G4/1 F4/1 E4/1 F4/1 G4/1 "
         "A4/1 B4/1 C5/1 B4/1 A4/2 G4/2 "
         "F4/1 E4/1 D4/1 E4/1 F4/1 G4/1 A4/1 B4/1 "
         "C5/2 B4/1 A4/1 G4/2 E4/2 "
         "A4/1 B4/1 C5/1 D5/1 E5/1 D5/1 C5/1 B4/1 "
         "A4/1 G4/1 F4/1 G4/1 A4/2 B4/2",
         "慢速分解和弦，适合展示大提琴音色的持续音"),

    song("送别", "李叔同", 66,
         "G4/1 G4/1 E4/2 G4/1 A4/1 G4/2 "
         "E4/1 D4/1 C4/2 D4/1 E4/1 D4/2 "
         "G4/1 G4/1 E4/2 G4/1 A4/1 C5/2 "
         "B4/1 A4/1 G4/2 A4/1 B4/1 A4/2 "
         "E4/1 G4/1 A4/2 G4/1 E4/1 D4/2 "
         "C4/1 D4/1 E4/2 G4/1 E4/1 D4/2 "
         "C4/1 C4/1 A3/2 C4/1 D4/1 E4/2".replace("A3/2", "A4/2"),
         "慢速长音多，最能暴露低音区的嗡鸣问题"),

    song("生日快乐", "希尔姐妹", 120,
         "G4/0.75 G4/0.25 A4/1 G4/1 C5/1 B4/2 "
         "G4/0.75 G4/0.25 A4/1 G4/1 D5/1 C5/2 "
         "G4/0.75 G4/0.25 G5/1 E5/1 C5/1 B4/1 A4/2 "
         "F5/0.75 F5/0.25 E5/1 C5/1 D5/1 C5/2",
         "短小、有跳进，适合现场快速演示"),

    song("音阶上行", "测试", 120,
         "C4/0.5 C#4/0.5 D4/0.5 D#4/0.5 E4/0.5 F4/0.5 F#4/0.5 G4/0.5 "
         "G#4/0.5 A4/0.5 A#4/0.5 B4/0.5 C5/0.5 C#5/0.5 D5/0.5 D#5/0.5 "
         "E5/0.5 F5/0.5 F#5/0.5 G5/0.5 G#5/0.5 A5/0.5 A#5/0.5 B5/0.5 C6/1",
         "半音阶全音域扫频，检查有没有走调 / 断音"),
]


def arrange(score, shift, cello_spec):
    """Independent EP melody and bowed accompaniment in the playable 25-key range.

    Parts use different registers for musical clarity; v2 firmware also permits
    unisons across instruments. Original notes stay as the offline melody.
    """
    ep, beat = [], 0
    for pitch, length in score['notes']:
        vel = 176 + (8 if beat % 4 == 0 else 0)
        vel += 5 if 2 <= beat % 8 < 6 else -3
        if length >= 2:
            vel -= 5
        ep.append([pitch + shift if pitch else 0, length, vel])
        beat += length
    cello, beat = [], 0
    for pitch, length in seq(cello_spec):
        cello.append([pitch, length, 132 if beat % 4 == 0 else 122])
        beat += length
    tracks = [
        dict(name='电钢旋律', wave=0, vari=0, vib=0, gate=.86, notes=ep),
        dict(name='大提琴伴奏', wave=3, vari=2, vib=2, gate=.96, notes=cello),
    ]
    if sum(x[1] for x in ep) != sum(x[1] for x in cello):
        raise ValueError(score['name'] + ': 合奏声部长度不一致')
    for track in tracks:
        for pitch, _, _ in track['notes']:
            if pitch and not LO <= pitch <= HI:
                raise ValueError(score['name'] + ': 合奏超出音域')
    score.update(version=2, arrangement='电钢＋大提琴合奏', tracks=tracks)
    score['desc'] = '电钢奏旋律，大提琴以长弓和弦音伴奏；脱机版仅含原主旋律。'


# C-major melody above C5; cello outlines tonic/subdominant/dominant below G4.
arrange(SONGS[0], 12,
        'C4/2 E4/2 C4/2 E4/2 F4/2 D4/2 G4/2 C4/2 '
        'C4/2 E4/2 F4/2 D4/2 C4/2 E4/2 G4/2 D4/2 '
        'C4/2 E4/2 C4/2 E4/2 F4/2 D4/2 G4/2 C4/2')


def solo(score, wave):
    """Pin the instrument without transposing or changing the original rhythm."""
    cello = wave == 3
    name = '大提琴独奏' if cello else '电钢独奏'
    notes, beat = [], 0
    for pitch, length in score['notes']:
        velocity = (136 if cello else 176) + (8 if beat % 4 == 0 else 0)
        notes.append([pitch, length, velocity])
        beat += length
    score.update(version=2, arrangement=name, tracks=[dict(
        name=name, wave=wave, vari=2 if cello else 0, vib=2 if cello else 0,
        gate=.96 if cello else .86, notes=notes)])


for score, wave in zip(SONGS[1:], [0, 3, 3, 0, 0]):
    solo(score, wave)


def main():
    os.makedirs(OUT, exist_ok=True)
    idx = []
    for i, s in enumerate(SONGS):
        fn = "song%02d.json" % i
        with open(os.path.join(OUT, fn), "w", encoding="utf-8") as f:
            json.dump(s, f, ensure_ascii=False, indent=1)
        count = sum(1 for tr in s.get('tracks', [{'notes': s['notes']}])
                    for note in tr['notes'] if note[0])
        idx.append({"file": fn, "name": s["name"], "author": s["author"],
                    "notes": count, "tempo": s["tempo"],
                    "arrangement": s.get('arrangement', '单音测试')})
        print("%-10s %2d 音  %s" % (s["name"], count, fn))
    with open(os.path.join(OUT, "index.json"), "w", encoding="utf-8") as f:
        json.dump(idx, f, ensure_ascii=False, indent=1)
    print("index.json: %d 首" % len(idx))


if __name__ == "__main__":
    main()
