## 1.3.3

- New `example/info_without_decoding.dart`, the first runnable use of
  `audioInfo` in this package. The README already timed it against
  `decodeAudio`; this measures the other half, which is memory: the fixtures
  decode to 33-52x their size on disk, and a decoded album is most of a
  gigabyte to answer a question the header already holds.

## 1.3.2

- The section on why to reach for this rather than the alternative now sits
  directly under the recording, instead of below a long explanation. Someone
  deciding whether to install it reads the choice before the mechanics, and
  the section was landing past the fold where it answered nobody.

## 1.3.1

- The README opens with a recording of the package running, rendered from a
  real execution rather than drawn: the command is run, its exit code checked,
  and the frames built from the bytes it printed. `tools/term-trailer.sh` in
  the portfolio repository makes it, so it can be regenerated when the numbers
  move.

## 1.3.0

- The README now answers, in its first screen, why to reach for this rather
  than the zero-dependency route or the package that already owns the
  category. Both answers carry the file and line, or the issue number, that
  a reader can check. A "reach for it when" list and a sentence on when to
  skip it follow, because a page that only argues for itself is not useful
  for deciding.

## 1.2.2

- Documents how to ship a standalone binary. `dart compile exe` refuses outright
  on a package with a build hook; `dart build cli` runs the hook and writes the
  executable and its library into a `bundle/` directory. The binary resolves the
  library through a relative `../lib`, so a copy of it on its own fails at the
  first call, which is why the whole folder has to ship. Both halves were run to
  produce the output quoted in the README.

## 1.2.1

- New example, `example/speech_input.dart`: the conversion in front of a speech
  model, run end to end. It decodes the stereo fixture, writes the 16 kHz mono
  WAV with `toSpeechPcm`, then takes a 12 kHz tone down to 16 kHz twice, once
  through `resample()` and once by plain decimation, and reports the energy
  left at the 4 kHz alias by each path: 0.1% against 88.3% on an Apple
  M-series laptop. The cost of skipping the filter stops being a claim once
  the unfiltered number is on your own screen.
- The README's "Feeding a speech model" section now says who actually needs
  that conversion, read from the wrappers' own docs at their current versions:
  `whisper_ggml` 2.6.0 bundles FFmpeg on Android, iOS and macOS but converts
  nothing on Windows or Linux without an `ffmpeg` on `PATH`, and its live
  entry point takes 16 kHz mono PCM16 on every platform; `vosk_flutter` 0.3.48
  never converts. The gap is narrower than "everyone needs this", and real
  where it exists.
- Both examples write their WAV into a fresh temp directory and print the
  path. The old default dropped the file into whatever directory you ran the
  example from; in a checkout it turned up in `git status`. The 1.2.0 archive
  itself shipped one, a stray 172 KiB `sine_44100_stereo_1s.ogg.wav` at the
  package root produced exactly that way, and this release removes it.
- The `decodeAudio` and `audioInfo` doc comments still said they throw for
  anything that is "neither Ogg Vorbis nor MP3". WAV has been decoded since
  1.1.0; the docs now name all three formats. Two dartdoc ranges written as
  `[-1.0, 1.0]` rendered as broken reference links and are backticked now.
- A pub.dev screenshot caption read "stb_vorbis or m inimp3": the description
  was YAML-folded across a line break in the middle of the word. Both captions
  are single lines now.
- The README documents that `dart compile exe` currently produces a binary
  that cannot resolve the native library: the compile exits 0 and the binary
  dies on its first decode, on Dart 3.11.0. `dart run` and `dart test` are
  unaffected.

## 1.2.0

- **Add `toSpeechPcm`, `resample` and `toMono`.** Whisper, wav2vec 2.0 and Vosk
  all want 16 kHz mono 16-bit PCM, and a decoded file is almost never that.
  Every caller feeding a speech model was writing that conversion by hand,
  against a package that was already holding the samples. `toSpeechPcm(pcm)` is
  the one line between the two.
- Downsampling low-passes before it interpolates. Skipping that is the mistake
  the feature exists to prevent: 44.1 kHz to 16 kHz without a filter folds
  everything above 8 kHz back into the band as a tone that was never recorded,
  and it cannot be taken out afterwards. Measured: a 12 kHz tone resampled to
  16 kHz lands at 4 kHz with under 5% of its original energy, and the test
  asserts that ratio, which is what keeps the filter from being dropped without
  the suite going red. Four deliberate defects in the new code were injected and
  four turned it red; the fifth changes gain by 0.1% and is documented in place
  rather than pinned.
- `toMono` averages channels instead of keeping one, and rounds away from zero
  so quiet material does not drift toward silence.
- Honest scope, also in the README: this is linear interpolation over a
  filtered signal, which suits speech features and analysis. It is not a
  mastering-grade polyphase resampler.

## 1.1.1

- The example runs without an argument. It used to print a usage line and exit
  64 unless you had an audio file to hand, which is the first thing anyone
  following the Example tab on pub.dev would hit. With no argument it now
  decodes `test/fixtures/sine_44100_stereo_1s.ogg`, which ships in the archive,
  and prints the format, rate, channels, frames, duration and ASCII waveform
  before writing the WAV. The output says the tone is a steady sine so the flat
  waveform reads as correct rather than broken. A path argument behaves as
  before, and the WAV is now written to the file's basename rather than beside
  the input.

## 1.1.0

- **Read WAV, so the package can open what `encodeWav` writes.** `encodeWav`
  has been here since the start, but `detectFormat` did not know the RIFF
  signature: feed its own output back to `decodeAudio` and it threw
  "unrecognized audio format". Anyone walking a directory of mixed audio hit
  the same wall on the one format that needs no decoder at all.

  `decodeWav` and `wavInfo` are pure Dart — a WAV file is a header and the
  samples — and handle integer PCM at 8, 16, 24 and 32 bits plus IEEE float at
  32 and 64, converting each to the signed 16-bit samples `PcmAudio` carries.
  8-bit is unsigned and centred on 128, unlike every other width, and float is
  clamped so an overshooting recording or a NaN from a broken encoder cannot
  wrap into a loud opposite-sign sample. `detectFormat` returns
  `AudioFormat.wav`, and `decodeAudio` and `audioInfo` dispatch to them.

  `wavInfo` reads the frame count from the size of the data chunk rather than
  by counting, so it costs the same on a four-second clip and a four-hour one.

  A compressed payload in a RIFF wrapper — ADPCM, µ-law, an MP3 inside a WAV —
  is named in the error rather than decoded as noise. The big-endian RIFX
  variant is not read.

## 1.0.2

- **Declare the SDK this package can actually resolve on.** The constraint read
  `^3.9.0`, but the `hooks` dependency that runs the native build requires
  `>=3.10.0`. On Dart 3.9 the package looked supported and then failed to
  resolve, with an error naming `hooks` rather than anything the reader had
  asked for. The pubspec and the README now both say 3.10.

## 1.0.1

Two bugs found by exercising the package against its own pub.dev description on
a real device and a real file sweep, rather than against its own tests.

### Android crashed at runtime, and the build was green

`flutter build apk` succeeded for all three ABIs, and then on device:

```
dlopen failed: cannot locate symbol "log" referenced by libaudio_decode.so
```

stb_vorbis and minimp3 call `log`, `pow`, `sin`, `exp` and `ldexp`. Android
keeps those in a separate `libm`, and its linker will not resolve a symbol from
a library that is not in `DT_NEEDED`. The build hook never linked it, so the
shipped `.so` listed only `libdl.so` and `libc.so`.

Every other target hid the omission: macOS and iOS get math from `libSystem`,
and glibc 2.34 folded `libm` into `libc`. Android was the one platform where it
was fatal, and the one platform a Dart `test/` directory cannot reach.

`hook/build.dart` now links `m` on Android and Linux. Verified by reading
`DT_NEEDED` out of the built `.so`: it was `[libdl.so, libc.so]` and is now
`[libm.so, libdl.so, libc.so]`.

If you shipped 1.0.0 to Android, it did not work. Sorry.

### A truncated file could decode to nothing and report success

Truncating an Ogg part way through its first audio page returned a `PcmAudio`
with `frameCount == 0` and threw nothing. Any caller validating an upload by
catching an exception accepted a file that produced no audio at all. A decode
that yields no frames now throws `AudioDecodeException`.

The README's claim that truncated Ogg files "fail and throw" was also wrong,
and is corrected rather than defended. Measured behaviour: a cut inside the
header throws, a cut after the header decodes what arrived and returns it, and
a cut yielding nothing now throws. Detecting a missing tail needs the
end-of-stream page flag, which this package does not check yet, and the README
now says so.

New `test/truncation_test.dart` sweeps truncation points instead of pinning one
percentage, because which offset produces the empty decode depends on where the
page boundaries fall. Confirmed red before the fix and green after.

## 1.0.0

The API is stable. No behaviour changes; this freezes the surface after an
adversarial pass over the FFI boundary, and documents one thing that pass turned
up.

- **Documented what a truncated file does, which differs by format.** The README
  said undecodable bytes throw, which is true, but a cut-off file is a separate
  case. Ogg is a checksummed container, so a truncated one throws. MP3 is a bare
  frame sequence carrying no total length, so a truncated one is
  indistinguishable from a shorter recording: it decodes the frames that arrived
  and returns them silently — measured, a third of a file decodes to about a
  third of the audio. Nothing can detect that from the bytes, so the README now
  says to check `PcmAudio.duration` against what you expected when the input may
  be a partial download.

Verified by execution and now covered by `test/native_safety_test.dart`: empty
input raises `ArgumentError` and garbage raises `AudioDecodeException`; a
truncated Ogg throws while a truncated MP3 returns fewer frames at the same
sample rate; repeated decode/encode does not leak (growth across batches
flattens instead of staying linear, which is the shape a leak would have);
`encodeWav` writes exactly a 44-byte header plus the samples; and `toMono`
leaves already-mono audio unchanged.

`native_toolchain_c` is pre-1.0 but is a build-time dependency and does not
reach the public API frozen here.

## 0.5.1

- Add `example/README.md` for pub.dev's Example tab (it was empty). It walks
  through the command-line example — detect the format, decode to PCM, print an
  ASCII waveform, write a WAV — with the real output against the repo's sine
  fixture. Docs only.

## 0.5.0

Two things that had to be settled before a 1.0.0 freezes them.

- **Correct a false claim.** Every release up to 0.4.1 said this package
  "decodes the same bytes to the same samples on every platform", and the
  library documentation said it "decodes deterministically across platforms".
  That is not true, and it was never true. Compiling this package's own C for
  arm64 and for x86-64 with the same clang and the same flags and decoding the
  six test fixtures, five of them come out with different samples: about 0.03%
  of samples differ, always by one least-significant bit. Both decoders work in
  floating point and a compiler may fuse a multiply and an add on one
  architecture and not on another, which moves the last rounding. What is true,
  and is what the documentation now says, is that decoding is deterministic for
  a given build and that the reported geometry (channels, sample rate, frame
  count) matches everywhere. The practical consequence is narrow but real: a
  checksum of decoded PCM does not survive a move between architectures. The
  reason this went unnoticed is that the test suite runs on three operating
  systems but each runner only ever compares against itself.
- **Mark `PcmAudio`, `AudioInfo` and `AudioDecodeException` as `final`.** They
  are leaf types: none of them is designed to be extended or implemented, and
  nothing needs to. Sealing them now is what makes the rest of 1.x safe, since
  adding a method to an open class breaks anyone who implemented it, and
  `AudioInfo`'s `==` would otherwise be open to an asymmetric subclass. This is
  the breaking part of this release: `final` cannot be added after 1.0.0
  without a 2.0.0, while removing it later would not break anyone.

## 0.4.1

- Answer the question the README kept skipping: why decode in process rather
  than run `ffmpeg`. `bench/vs_ffmpeg.dart` measures both paths on the same
  file at four clip lengths, and the README now carries the result. The point
  is not that the codec is faster. Starting ffmpeg costs about 24.8 ms on an
  Apple M-series laptop before it decodes anything, measured by giving it a
  0.05-second clip where there is nothing to decode, and that cost is paid per
  file: at one second of audio, 98% of the subprocess time is not decoding. The
  decoding is in the same class either way, about 15.7 ms against 12.9 ms over
  thirty seconds.
- The bench compares the two decoders' output before it reports any timing, so
  a timing number cannot come from decoding less audio. Running it turned up
  one real difference, which it now reports rather than hiding: on a
  one-second clip ffmpeg's raw PCM pipe stops 128 frames early, while this
  package returns the full 44100 frames the container declares. The two agree
  exactly at five, fifteen and thirty seconds.

## 0.4.0

- Add value equality to `AudioInfo`. It now overrides `==` and `hashCode` over
  its `sampleRate`, `channels` and `frameCount` fields, so two values with the
  same geometry compare equal, share a `hashCode`, deduplicate in a `Set` and
  work as `Map` keys. This lands before the 1.0.0 freeze: giving a released
  value type value equality afterwards would change how existing `==`,
  `Set` and `Map` uses behave, which would be a breaking change. `PcmAudio`
  keeps identity equality by design, since its `samples` buffer is large and
  mutable and a structural `==` would scan every sample and rehash whenever the
  buffer is written. No existing fields or methods change.

## 0.3.2

- Fix the int32 overflow from 0.3.1 on the Ogg Vorbis path as well.
  `ad_info_vorbis` read the stream length from the final page's granule
  position as an `unsigned int` and narrowed it into the caller's `int` out
  parameter with no range check, so a stream whose granule passed 2^31 (about
  13.5 hours at 44.1 kHz) wrapped to a negative value that `oggInfo` and
  `audioInfo` surfaced as a negative `frameCount` and `duration` with no error.
  The Vorbis info path now rejects the overflow with an `AudioDecodeException`,
  the same guard the MP3 path already carried.

## 0.3.1

- Fix an int32 overflow: the MP3 decoder accumulated the per-channel sample
  count in a native `size_t` but narrowed it into the caller's `int` out
  parameter with no overflow check. A stream whose per-channel sample count
  passed 2^31 (about 13.5 hours at 44.1 kHz) wrapped to a negative value,
  which `mp3Info`/`audioInfo` surfaced as a negative `frameCount` and
  `duration` with no error, and which `decodeMp3` could turn into an unfreed
  native buffer surfaced as an unrelated `ArgumentError`. Both paths now
  reject the overflow explicitly (`AudioDecodeException`) instead of
  wrapping, and `_decode` frees the native buffer in a `finally` even if the
  copy into Dart memory throws.

## 0.3.0

- Add `PcmAudio.toFloat32()`, `PcmAudio.channel(int)` and `PcmAudio.toMono()`.
  The samples were only exposed as raw interleaved `Int16List`, so waveform,
  analysis and machine-learning callers all had to write the same
  divide-by-32768 loop and manual channel split. `toFloat32` returns the
  normalized `[-1.0, 1.0]` floats, `channel` deinterleaves one channel into a
  `Float32List`, and `toMono` averages the channels into a mono `PcmAudio`. All
  additive; existing fields and methods are unchanged.

## 0.2.3

- Widen the native-toolchain constraints so the package can be installed in a
  Flutter app at all. `hooks` 2.1.0 and `native_toolchain_c` 0.19.3 raised their
  `meta` floor to ^1.19.0, and Flutter's SDK pins `meta` to 1.17.0, so
  `flutter pub add` failed at version solving with "flutter from sdk is
  incompatible". Allowing `hooks >=2.0.2` and `native_toolchain_c >=0.19.2`
  lets the solver pick a version that works with the pinned `meta`, while a
  pure-Dart project still resolves to the newest. No API or behaviour change.

## 0.2.2

- Shorten the screenshot description. pub.dev accepts up to 200 characters but
  scores only those under 160, so the previous release published cleanly and
  quietly gave up the documentation points it was meant to earn.

## 0.2.1

- Declare the diagram in `pubspec.yaml` so pub.dev renders it on the package
  page. It was already in the repository and the README, but pub.dev shows only
  what the `screenshots:` field points at.

## 0.2.0

- Add `audioInfo`, `oggInfo` and `mp3Info`, which return an `AudioInfo` with
  `sampleRate`, `channels`, `frameCount` and `duration` without decoding to
  PCM. Reading a track's length used to mean decoding the whole file, which for
  four minutes of 44.1 kHz stereo materializes 40 MB of samples you then throw
  away. The new calls allocate no PCM: Vorbis answers from the container,
  and MP3 walks its frame headers with the decoder's synthesis step skipped.
  Measured on a one-second stereo fixture (Apple M-series, warmed up): Ogg
  107 µs against 511 µs for a full decode, MP3 0.9 µs against 217 µs. The
  reported geometry is checked against `decodeAudio` for every test fixture.

## 0.1.3

- Example: show what to do with the decoded PCM, not just how to re-encode it. It
  now reduces the samples to a one-line waveform (peak amplitude per column,
  scaled to the loudest column), the primitive a waveform view or a silence
  detector is built on.

## 0.1.2

- Docs: sharpen the pub.dev description to lead with the value and the terms people search.

## 0.1.1

- Move the stb_vorbis and minimp3 attributions out of `LICENSE` into
  `THIRD_PARTY_NOTICES.md`, so `LICENSE` is the plain MIT text that automated
  license detection recognises. The attributions themselves are unchanged and
  still ship with the package.

## 0.1.0

- Initial release.
- Ogg Vorbis decoding via stb_vorbis and MP3 decoding via minimp3, compiled
  from source with Dart build hooks.
- `decodeAudio`, `decodeOgg`, `decodeMp3`, `detectFormat` and `PcmAudio`.
- `encodeWav` writes decoded PCM to a 16-bit WAV.
