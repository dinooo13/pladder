# The model download

Parakeet TDT v3 is about 460 MB of CoreML bundles, fetched once from Hugging
Face on first launch into
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`.

## What FluidAudio already guarantees

- **Resume.** Bytes stream into `<file>.partial` with an ETag sidecar beside
  it, and a retry — or a whole new launch — continues with `Range` plus
  `If-Range` (`Shared/Download/FileDownloader.swift`). A 200 restarts the
  file, a 416 clears the partial; mixed-version bytes are never spliced.
- **Integrity.** Before the atomic move into the cache, a body that is empty,
  HTML, or any size other than the one the Hugging Face tree listing declared
  is rejected (`validateDownloadedArtifact`), so a truncated file is never
  visible to the loader.
- **Retry.** Four attempts, exponential backoff, `Retry-After` honoured,
  stall watchdog (`RetryPolicy.swift`, `DownloadTypes.swift`).
- **Corruption at load.** A bundle that fails to compile makes FluidAudio
  delete the repo directory and download it again, once (`ModelHub.loadModels`).

## What Pladder adds

`FluidAudioIncrementalEngine.performLoad` resumes any `.partial` left under
the cache before loading, because `AsrModels.download` decides by directory
existence alone and would otherwise take a half-written bundle for complete
and pay the full purge. Load failures are classified for the menu: a download
problem says so and that Retry resumes it.

## Testing it without touching the live cache

The cache path comes from the home directory, so a run under a throwaway home
downloads into it and leaves the real one alone:

```sh
swift build -c release
CFFIXED_USER_HOME=$(mktemp -d) ./.build/release/pladder-cli some.wav   # or HOME=
```

Interrupt it with Ctrl-C, run it again, and it continues from the byte it
stopped at. The trail is on OSLog subsystem `com.fluidinference`:

```sh
/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "com.fluidinference"'
```

Release builds send info-level lines there privately, so run the debug binary
(`.build/debug/pladder-cli`) when the whole trail is wanted: it mirrors every
line to the console, including `Resuming <file> from byte N` and
`Deleting cache and re-downloading…`.
