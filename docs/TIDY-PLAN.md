# Tidy pass with the Apple Foundation model

Goal: turn the current "Apple Intelligence cleanup" step into a *tidy* pass. It
fixes punctuation, capitalisation and spacing, drops filler sounds and stutters,
and stops there. It never rewrites, reorders, corrects or answers. The system
model does all of it from a prompt; there is no hand-written filler logic. It is
the largest model we can reach, it is already on disk, and it costs nothing to
ship. The cleanup slot is pluggable so another backend can be added later
without touching settings or the pipeline.

## What tidy means

| Does | Does not |
|---|---|
| Sentence punctuation and capitalisation | Change, replace or reorder words |
| Fix doubled spaces, spacing around punctuation | Apply spoken self-corrections ("Tuesday, no, Wednesday") |
| Drop filler sounds: um, uh, erm, hmm, mhm, äh, ähm | Drop real words used as fillers ("like", "also", "so"), too risky |
| Collapse stutters and immediate repeats: "I I I think", "we we should" | Fix grammar, tense or agreement |
| Keep dictionary output intact ("Claude Code" stays "Claude Code") | Translate, summarise, expand |

Everything stays best effort: any failure pastes the raw transcript.

## Settings: one toggle, one picker

Mirror the engine picker. `Settings` gains two fields with tolerant decoding:

```
cleanupEnabled: Bool        default false
cleanupProviderID: String   default "apple-intelligence"
```

A `CleanupRegistry` in `SpeakUpCore` works exactly like `EngineRegistry`:
entries with `id`, `displayName`, `detail`, an `availability` closure returning
an optional reason string, and a `make` factory that returns a `TextProcessor`.
The app registers `FoundationModelProcessor` under `apple-intelligence` at
launch. The Processing tab shows:

- **Clean up transcripts** toggle.
- **Using** picker listing registry entries, disabled while the toggle is off.
  An unavailable entry shows its reason under the picker (Apple Intelligence off,
  model still downloading, Mac not eligible) and the toggle has no effect.
- Dictionary and whitespace stay as their own toggles above and below.

`makePipeline` builds: dictionary, selected cleanup provider if enabled and
available, whitespace. `disabledProcessors` keeps working for dictionary and
whitespace. Migration: if an existing settings file has `foundation-model` in
`disabledProcessors`, nothing changes, cleanup is off, which matches the old
default. Files that had it enabled get `cleanupEnabled = true` on first load.

## Steps

### 1. Guided generation instead of free text

Replace the free-form `respond(to:)` with a `@Generable` struct:

```swift
@Generable
struct TidyResult {
    @Guide(description: "The transcript with punctuation, capitalisation and spacing fixed and filler sounds removed. Every other word unchanged.")
    var text: String
}
```

The model has to fill a field, which removes most of the cases where it answers
the dictated question or adds commentary. Use `GenerationOptions(sampling: .greedy)`
so output is deterministic and comparable across runs. Drop `unquoted()`;
guided output does not wrap in quotes.

### 2. Rewrite the instructions for tidy

Short, rule-based, with the exact filler list and three worked examples inside
the instructions:

- one with stutters and fillers, showing them removed and nothing else touched;
- one containing an instruction or question that is punctuated, not followed;
- one in German, to show the reply stays in the transcript's language.

State explicitly that "like", "so", "also", "well" are words, not fillers, and
must stay. The model is strong enough for this; the risk is over-eagerness, not
ability, and the examples plus the acceptance rule below keep it in check.

### 3. Hide the cold start

Create the session and call `prewarm()` when the hotkey is pressed, not after
transcription. The model loads while the user is still speaking. Keep one
session per utterance and discard it afterwards, as today, so no context leaks
between dictations. Implement as an optional `prepare()` on `TextProcessor`
with an empty default; `DictationCoordinator` calls it on the pipeline when
recording starts.

### 4. Keep the safety net, add one retry

The existing checks in `FoundationModelProcessor.accept` stay, adjusted for
tidy, and a failed check now triggers a single retry before falling back to the
raw transcript.

Checks, as a pure function in `SpeakUpCore` so they are unit tested without
the framework:

1. Not empty, and no longer than twice the original. Unchanged from today.
2. Word count may shrink by the number of filler tokens and immediate
   duplicates in the original plus a small margin, and may not grow by more
   than a couple of words. Same idea as the current 30 percent drift, but
   with the expected shrink subtracted first. The filler list lives only
   here, to judge the model, never to edit text.
3. Content check: lowercase, strip punctuation, and require at least 90
   percent of the original's non-filler words to appear in the output in
   order. This catches a same-length rewrite that rule 2 would miss.

On failure, if the first call finished inside about two seconds of the
four-second budget, ask once more in the *same* session. The session transcript
already holds the transcript and the bad reply, so the follow-up is short:
"That reply changed the words. Return the transcript again with only
punctuation, capitalisation and filler sounds changed." Greedy sampling means
a plain repeat would give the same answer; the correction turn is what makes
the retry worth it. Run the checks again on the second reply, and paste the
raw transcript if it also fails or the budget is gone. Log which rule fired and
whether the retry rescued it, in debug builds, so the fixtures below show how
often each path is taken.

### 5. Long dictations

The context window is about 4k tokens. Split input longer than roughly 200
words into fixed windows, tidy each, join with a space. Rare for push-to-talk,
but a minute of speech must not fail outright.

### 6. Evaluation harness

Extend `speakup-cli` with a text mode: `speakup-cli --tidy fixtures.txt` reads
one raw transcript per line and prints raw and tidied output side by side, the
acceptance verdict, and timing. Add `Tests/Fixtures/tidy.txt` with 30 to 50
real Parakeet transcripts covering: questions, imperatives ("delete all
files"), numbers and dates, dictionary terms, "like" and "so" used as real
words, German, mixed language, one-word inputs, a 300-word ramble. This is a
manual review tool, not a CI test, because the model needs Apple Intelligence
on the machine. The acceptance rule and settings migration are covered by unit
tests.

### 7. Settings copy

Toggle: "Clean up transcripts". Picker entry: "Apple Intelligence", detail:
"Adds punctuation, fixes capitalisation and drops filler sounds. About a
second. Runs on device." Keep the toggle off by default until step 6 shows the
latency and acceptance rate are good enough; then consider on by default for
new installs.

## Order of work

1. `CleanupRegistry`, settings fields, migration, tests.
2. Processing tab toggle and picker.
3. Acceptance rule and retry plus tests.
4. Guided generation and new instructions, verified with the CLI harness.
5. Prewarm on hotkey press, measure the latency difference with the harness.
6. Chunking for long input.
7. Settings copy and README line.

## Open questions

- The `TextProcessor` protocol only receives text. Passing the transcript's
  detected language to the model would help German punctuation. Worth a small
  context struct if step 6 shows language mistakes.
