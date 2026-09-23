<p align="center">
  <img src="Assets/icon_1024.png" width="128" alt="Pladder icon">
</p>

<h1 align="center">Pladder</h1>

<p align="center">
  <strong>Talk to your agents.</strong><br>
  Push-to-talk dictation for macOS. Hold a key, say the prompt, let go.<br>
  It's already in Claude Code, Codex, Cursor or OpenCode before you can reach for the Enter key.<br>
  <br>
  Insanely fast · 100% private · No data leaves your Mac
</p>

<p align="center">
  <a href="INSTALL.md"><img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or later"></a>
  <a href="INSTALL.md"><img src="https://img.shields.io/badge/Apple%20Silicon-M1%20and%20up-000000?logo=apple&logoColor=white" alt="Apple Silicon"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <a href="https://github.com/dinooo13/pladder/actions/workflows/ci.yml"><img src="https://github.com/dinooo13/pladder/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center">
  <a href="INSTALL.md">Install</a> ·
  <a href="#why-pladder">Why</a> ·
  <a href="#built-for-agents">Agents</a> ·
  <a href="#speed">Speed</a> ·
  <a href="#private-by-construction">Privacy</a> ·
  <a href="#choose-your-style">Styles</a> ·
  <a href="#faq">FAQ</a>
</p>

<!--
  Hero GIF goes here: six to eight seconds of holding Option+Space, saying a
  prompt into Claude Code, letting go, the text landing, the agent starting.
  Record with QuickTime or `screencapture -v`, convert with ffmpeg + gifski.
  Replace the picture below with:
  <p align="center"><img src="docs/images/hero.gif" width="800" alt="Dictating a prompt into Claude Code with Pladder"></p>
-->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/styles-dark.png">
    <img src="docs/images/styles-light.png" width="900" alt="The Pladder pill while dictating, in its four styles: Compact with a level meter, Minimal disc, Live transcript, Menu Bar glyph">
  </picture>
</p>

<p align="center"><em>Hold. Release. Pasted.</em></p>

---

## The name

*Pladder* is Low German (*Plattdeutsch*) for "to babble". You just pladder into the microphone and the text gets pasted.

## Why Pladder

You type long prompts all day. Speech is three to four times faster than typing, and the thing that has always made dictation annoying is waiting for it. Pladder is built around one number: the time between letting go of the key and the text appearing. On the slowest supported Mac, a ten-second sentence is pasted in under 300 milliseconds. That is the entire path — capture, transcription, output — measured end to end.

- **One key, everywhere.** Hold Option+Space, or any key or chord you record. Speak. Release. The words land at the cursor in any app that takes text. No window to open, no button to click, no mode to leave.
- **Two keys, and it is sent.** Tap Right Option while you speak and the dictation goes out with Return the moment you let go. A prompt to an agent, a chat message, a shell command, without touching the keyboard again.
- **Nothing leaves your Mac.** The speech model runs on the Neural Engine. There is no account, no server, no telemetry, and the app makes no network requests after the one-time model download.
- **It knows your words.** A dictionary turns what the model hears into what you meant. "clode code" becomes "Claude Code", "get hub" becomes "GitHub", every time, at zero cost in latency. List a word on its own and near misses of it are repaired too, so "Chat G P T" comes out as "ChatGPT" without you predicting every way the model might mangle it. Correct a word by hand after a dictation and Pladder offers to remember it — checked on device, added only when you say so.
- **It skips over the ums.** Hesitation sounds — "uh", "um", German "äh"/"ähm", Spanish "eh" — are dropped before the text is pasted. Still no cost in latency. Only English, German and Spanish fillers are covered for now; other languages pass through unchanged.
- **Polish it when you want to.** Hold a second key instead and Apple's on-device model cleans the transcript before it is pasted: "wait, no, Friday" becomes "Friday", spoken numbers become digits, "first… second…" becomes a list. A second or two, still on your Mac, and only when you ask.
- **It behaves like part of macOS.** A menu bar app with a Liquid Glass status pill, a standard settings window, and nothing in the Dock.
- **Twenty-five languages, detected automatically.** English, German, Spanish, French and the rest of Europe in the same session, with no setting to flip.
- **Free and MIT.** The source is here. Read it, build it, change it.

## Built for agents

Pladder pastes into whatever has focus, so it works with every editor and terminal. It was made for the loop where you talk to an agent, it works, and you talk again:

- **Claude Code**, **Codex** and **OpenCode** in the terminal. Hold the key, describe the change, release. The prompt is in the input line. Tap the send key while you talk and it is already running when you let go.
- **Cursor** and any other editor. Dictate into chat, into a comment, into a commit message.
- **Anything else with a text field.** Slack, Mail, a browser, a form.

Two things make dictation into a terminal work where general dictation apps stumble. The latency is short enough that you stay in the conversation instead of waiting for it. And the dictionary fixes the names that speech models get wrong: product names, libraries, commands, your own project's jargon.

## Speed

The whole product is one number: the time between letting go of the key and the text appearing.

**~300 ms. Faster than a blink. Flat with length. On any Mac Pladder runs on.**

That is on an M1, the slowest supported chip. Newer Macs are quicker still. It does not matter whether you spoke for five seconds or five minutes: the wait is the same, because the transcription happens while you are still speaking. By the time you release the key, there is almost nothing left to do.

The engine is NVIDIA's Parakeet TDT v3, running on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). It loads at launch and stays loaded, so the first dictation after launch is as quick as the hundredth.

Why it is fast is written up in [docs/PERFORMANCE.md](docs/PERFORMANCE.md). The measurement procedure and the full baseline are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Private by construction

Privacy here is not a policy, it is how the thing is built.

- **Audio never leaves the Mac.** The microphone is open only while the key is held, and macOS shows the orange indicator only then. Audio goes from the microphone to the Neural Engine and is discarded.
- **Text never leaves the Mac.** The transcript exists long enough to be pasted. Your previous clipboard is put back afterwards. After a paste, Pladder watches the field it pasted into for up to a minute through Accessibility, to notice when you fix a word; it reads only the pasted words and a little context, keeps nothing, and asks before adding anything to the dictionary.
- **No network.** The only request Pladder ever makes is the one-time download of the speech model from Hugging Face, about 700 MB, on first launch. After that it works with Wi-Fi off. There is no update check, no crash reporter, no analytics.
- **No account.** Nothing to sign up for, nothing to log in to, nothing to cancel.
- **Auditable.** The app is about five thousand lines of Swift under the MIT license, and none of them open a network connection. The model download is FluidAudio's, and it runs once.

## Choose your style

A small pill at the bottom of the screen shows a red dot and a live level meter while you speak, and is gone the moment you let go; the pasted text is the confirmation. Only when transcription takes longer than usual — the first dictation after launch, say — does a spinner say so. It never takes focus from the app you are typing into. Show as much or as little of it as you like.

- **Compact.** The full pill with the level meter. You always know it is listening.
- **Minimal.** A small disc with a pulse. Enough to see it is on, not enough to look at.
- **Live.** The words as they are recognised, while you are still speaking. The wider pill costs a little more of the chip than the others; the text it shows is only a preview, and what gets pasted is always the full recording.
- **Menu Bar.** Nothing on the desktop at all. The wave in the menu bar is the only sign.

Each comes in Liquid Glass or a flat fill, in light, dark or whatever the system is doing. Pick a different push-to-talk key or send key by pressing it. Teach it your words in the dictionary, and share the rules with your team as a JSON file.

## Install

macOS 26 or later on Apple Silicon. Build from source in about a minute:

```sh
git clone https://github.com/dinooo13/pladder.git
cd pladder
./scripts/bundle.sh --install --run
```

Grant Microphone and Accessibility when asked, wait for the model to download once, then hold **Option+Space** in any text field and speak. It is the same key with or without Accessibility. The full walkthrough, signing, troubleshooting and the command-line tool are in [INSTALL.md](INSTALL.md).

## FAQ

**Does Pladder work with Claude Code?**
Yes. Hold the key while the terminal has focus, speak, release. The text is pasted into the prompt. The same goes for Codex, OpenCode, Cursor and any other terminal or editor.

**Does my audio leave my Mac?**
No. Transcription runs on the Neural Engine. Pladder makes no network requests after the one-time model download and has no account or telemetry.

**Is Pladder free?**
Yes. MIT license, no tiers, no trial.

**How is it different from Wispr Flow, Superwhisper or macOS dictation?**
Pladder does one thing: push-to-talk, on-device, into any app, as fast as the hardware allows. There is no cloud path, no subscription and no account. It is open source, and the speed is benchmarked in the repository rather than claimed.

**Which languages?**
The 25 European languages Parakeet TDT v3 supports, including English, German, French, Spanish, Italian, Portuguese, Dutch, Polish and Ukrainian. It detects the language as you speak.

**Which Macs?**
Any Apple Silicon Mac on macOS 26 or later. Benchmarks are taken on an M1, so every newer chip is faster.

**Can I change the key?**
Yes. Any key or combination, recorded by pressing it in Settings, and either Option works for the default. Option+Space is the default because no macOS shortcut owns it and it works without Accessibility.

**Option+Space is my Alfred or Raycast hotkey, or I type non-breaking spaces with it.**
Option+Space is Alfred's default hotkey and a common Raycast choice, and it types a non-breaking space in most layouts. Both are lost while Pladder runs. Record another combination in Settings if you need them.

**Can it press Return for me?**
Yes. Press the send key, Right Option by default, at any point while you hold the push-to-talk key, and Return is pressed after the text is pasted. That sends a chat message or runs a terminal command without touching the keyboard again. The send key can be changed in Settings, like the push-to-talk key.

**Can it clean up what I said?**
Record a key for Dictate and polish in Settings and hold that instead. The dictation goes through Apple Intelligence on your Mac before it is pasted, which takes a second or two. It needs Apple Intelligence turned on in System Settings; without it that key pastes the text as dictated.

**Can I toggle instead of holding?**
Yes. Record a toggle key in Settings: one tap starts a recording, the next tap inserts it. Give it the same combination as the push-to-talk key and that key does both: tap to start and tap again to insert, or hold and release as before. Escape discards a recording either way.

**What about long dictations?**
Recordings stop at 120 seconds, so a lost key-up never leaves the microphone on. Audio longer than 15 seconds is transcribed in overlapping windows.

## Contributing

Issues and pull requests are welcome. The [CLAUDE.md](CLAUDE.md) file states what the project optimises for and the rule that every change on the release-to-paste path ships with a benchmark. [docs/BENCHMARKS.md](docs/BENCHMARKS.md) has the procedure.

## License

MIT. See [LICENSE](LICENSE).

Parakeet TDT is by NVIDIA (CC-BY-4.0). FluidAudio is by FluidInference (Apache-2.0).
