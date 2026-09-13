# Audio fixture

`tone.mp3.base64` contains a synthetic 440 Hz tone, 0.5 seconds, 44.1 kHz stereo
MP3 at 32 kbit/s, stored as text for review and decoded into a temporary file by
the tests. It contains no recorded speech or personal data. Generated with:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=0.5' \
  -ac 2 -c:a libmp3lame -b:a 32k -map_metadata -1 -write_xing 0 tone.mp3
base64 -i tone.mp3 -o tone.mp3.base64
```

Tests use macOS's built-in `afconvert`; they do not require ffmpeg.
