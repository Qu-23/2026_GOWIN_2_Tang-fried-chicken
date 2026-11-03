# FFT and 64-band display reducer

The three RTL files in this directory are copied unchanged from the measured
`build/hdmi_capacity/fft_1024_compact/src` experiment. `visual_fft.sv` and
`visual_frame_store.v` are byte-identical to the local upstream files in
`D:/Gowin/projects/Github_projects/fpga-main/boards/tang_mega_138k_pro/src`.
The coefficient ROM preserves all 1,024 reachable entries of the upstream
4,096-entry ROM, selecting source indices `4*k`. Its clocked read remains one
cycle. The compact ROM supports the fixed LOGN=10 use here; do not substitute
another LOGN without regenerating and checking the ROM.

No arithmetic or control fixes were needed after independent numerical tests.
The local upstream files have no license header, and there is no top-level
LICENSE in that checkout. This records provenance without asserting a license.
`build/timbre_checks/tb_av2_fft/numerical_evidence.json` records upstream and
private source SHA-256 hashes, coefficient comparison, fixture/output hashes,
simulator log hash, and runtime. The capacity experiment's
`coefficient_check.json` records the original reduction.

`../hdmi_spectrum.sv` instantiates `visual_fft` as `fft`, with LOGN=10 and
WINDOW=1. Input is the actual signed 16-bit DAC mono fold, supplied by the
caller with its sample-valid pulse. It has no backpressure or generated tone.
The core scales each radix-2 stage by two (FFT/N); a coherent Hann sine has
approximately A/4 in its main bin and A/8 in each adjacent bin. Reported power
is exactly signed real squared plus signed imaginary squared.

The 64 bands discard DC and bins above 240:

| Bands | FFT bins | Width |
|---|---|---|
| 0–15 | 1–16 | 1 bin |
| 16–31 | 17–48 | 2 bins |
| 32–47 | 49–112 | 4 bins |
| 48–63 | 113–240 | 8 bins |

At 49,667 samples/s, bin spacing is 48.5029297 Hz; bin 240 is 11,640.703125 Hz.
Each band takes its largest bin power. The approximate log2(power) uses its
leading bit and next two mantissa bits, subtracts a power floor of 64, then
maps approximately 4.5 pixels per power octave, capped at 88. This displays
about 59 dB above the floor. A full-scale coherent Hann sine reaches 88;
silence and signals below the floor give zero. This is a display scale, not a
calibrated dBFS instrument.

The reducer has one running 37-bit peak and a resetless 128x8 synchronous
front/back level RAM. All 64 entries of a back bank are written before it
becomes eligible. Bank publication occurs only on `publish` with a completed
bank. A completed bank is retained until publication, and whole subsequent
FFT output frames are skipped while it waits. Publication during a skipped
frame cannot resume that frame. `read_addr` has one clock of latency;
`ready` becomes high after the first completed-bank publication and remains
high until reset. Before then, `level` is zero. `dropped_frames` reports input
snapshot drops in the FFT mailbox; intentional display-frame skips do not
increment it.

The standalone compact core previously measured 9 BSRAMs. The reducer adds
1,024 storage bits and should need at most one additional BSRAM; the final
combined Gowin synthesis and routing are performed by the release builder.

Run from the project root using the bundled Python interpreter:

```
python analysis/check_av2_fft.py --core-only
python analysis/check_av2_fft.py
```

The bench sends 12 complete frames at 73.333333 MHz and 49,667 samples/s,
including continuous frames, reset, mixed tones, coherent Hann side bins,
full scale, below-floor signal, silence, and a comb covering all 64 bands.
NumPy's floating FFT supplies independent complex and bar-height targets.
Checks also require exact power/indexing, stable pre-publication output,
retained banks, whole skipped frames, mid-skipped-frame publication, silence
clearing, and no input capture drops. The behavioral TDD baseline compiled
and simulated but failed the published tone-height check; its source is
`build/timbre_checks/tb_av2_fft/red_spectrum.sv`, with failure recorded in
`build/hdmi_audio_v2/fft_tdd_red.log`.
