"""Check real generated arrangements against the board's note/routing limits."""
import unittest

from gen_scores import SONGS


class Arrangements(unittest.TestCase):
    def test_little_star_has_independent_simultaneous_parts(self):
        for song in SONGS[:1]:
            with self.subTest(song=song['name']):
                tracks = song.get('tracks', [])
                self.assertEqual({t['wave'] for t in tracks}, {0, 3})
                spans = []
                lengths = []
                for track in tracks:
                    time = 0
                    for note in track['notes']:
                        pitch, beats, vel = note
                        self.assertGreater(beats, 0)
                        if pitch:
                            self.assertTrue(60 <= pitch <= 84)
                            self.assertTrue(1 <= vel <= 255)
                            spans.append((time, time + beats * track['gate'], pitch, track['wave']))
                        time += beats
                    lengths.append(time)
                self.assertEqual(lengths[0], lengths[1], 'Both parts must finish the phrase together')
                # Conventional arrangements use distinct registers for clarity.
                overlaps = 0
                for start, end, pitch, wave in spans:
                    for s2, e2, p2, w2 in spans:
                        if wave != w2 and start < e2 and s2 < end:
                            overlaps += 1
                            self.assertNotEqual(pitch, p2, 'Keep melody and accompaniment registers distinct')
                self.assertGreater(overlaps, 10, 'Must be a duet, not timbres alternating in time')
                self.assertGreater(len({v[2] for v in tracks[0]['notes']}), 1, 'Phrases need dynamics')

    def test_other_scores_use_one_explicit_instrument(self):
        self.assertEqual(len(SONGS), 6, 'Keep the extra duet diagnostic out of the demo library')
        for song, wave in zip(SONGS[1:], [0, 3, 3, 0, 0]):
            with self.subTest(song=song['name']):
                self.assertEqual(len(song['tracks']), 1)
                part = song['tracks'][0]
                self.assertEqual(part['wave'], wave)
                self.assertEqual([(n[0], n[1]) for n in part['notes']],
                                 [tuple(n[:2]) for n in song['notes']],
                                 'Solo playback must keep the original melody and rhythm')
                self.assertEqual(part['vari'], 2 if wave == 3 else 0)
                self.assertIn('独奏', song['arrangement'])
                for pitch, beats, velocity in part['notes']:
                    self.assertTrue(pitch == 0 or 60 <= pitch <= 84)
                    self.assertGreater(beats, 0)
                    self.assertTrue(1 <= velocity <= 255)

    def test_scale_remains_full_range_diagnostic(self):
        self.assertEqual([n[0] for n in SONGS[5]['notes']], list(range(60, 85)))
        self.assertEqual(len(SONGS[5]['tracks']), 1)
        self.assertEqual(SONGS[5]['tracks'][0]['wave'], 0)


if __name__ == '__main__':
    unittest.main()
