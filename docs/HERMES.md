# Pladder as Hermes Agent's speech-to-text

[Hermes Agent](https://github.com/NousResearch/hermes-agent) transcribes voice
messages, from Telegram or its own voice mode, with a speech-to-text provider.
Besides its built-in ones it runs any shell command declared under
`stt.providers`, and `pladder-cli` is such a command: it takes an audio file and
prints the transcript to stdout, nothing else. Voice messages are then
transcribed by Parakeet on the Neural Engine, on the Mac Hermes runs on, with no
API key and no network.

Hermes has to run on the Mac: the CLI needs Apple Silicon and macOS 26.

## Install the CLI

Build it once and copy it somewhere stable; the binary under `.build` is
replaced by every build.

```sh
swift build -c release --product pladder-cli
sudo install .build/release/pladder-cli /usr/local/bin/
```

The first run downloads Parakeet (about 460 MB) into the same cache the app
uses, so with the app installed there is nothing to download.

```sh
pladder-cli some-voice-note.ogg
```

## Configure Hermes

In `~/.hermes/config.yaml`:

```yaml
stt:
  provider: pladder
  providers:
    pladder:
      type: command
      command: "/usr/local/bin/pladder-cli {input_path} --process"
      timeout: 120
```

`--process` runs the app's processors over the text: fillers removed, your
dictionary applied, spoken punctuation. It reads the app's settings file for the
dictionary and the processor toggles and never writes it. Leave the flag out
for Parakeet's text as it came.

## What to expect

- **Speed.** Hermes starts a process per message. With the model already
  compiled, loading takes 0.1 to 0.3 s and a short voice note is transcribed in
  about 0.2 s on an M1.
- **Formats.** Hermes hands command providers the file as it arrived. The CLI
  reads WAV, M4A, MP3, FLAC, CAF and Ogg Opus, which covers Telegram voice
  notes. It cannot open WebM; for a source that sends it, convert first:
  `command: "ffmpeg -loglevel error -i {input_path} -f wav {output_dir}/in.wav && /usr/local/bin/pladder-cli {output_dir}/in.wav --process"`.
- **Language.** Parakeet detects the language itself, one of the 25 European
  languages it knows, so Hermes's `stt.language` and `{language}` are ignored.
- **Errors.** A file the CLI cannot read, or a model that fails to load, exits
  with status 1 and a message on stderr, which Hermes reports as the
  provider's error.
- **No polish.** The polish models, Apple Intelligence and S1-mini, are not
  applied; the CLI stops after the processors.
