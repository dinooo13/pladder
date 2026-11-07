# Design

How Pladder looks, reads and behaves on screen: the app, its menu, the pill and the
website. Every UI change follows this file; a change that breaks a rule here changes
the rule here first, in the same pull request, with the reason.

## What it should feel like

A part of macOS 26, not an app with a theme. Pladder is used dozens of times an hour
and looked at for a second each time, so it is quiet: system controls, system fonts,
system greys, one accent colour, few words. The reference for that quiet is T3 Code:
neutral greys, thin lines, restrained type, nothing that asks for attention it has not
earned.

Three rules decide most questions:

1. **Native first.** Use the control macOS has before drawing one. A custom look needs
   a reason a system control cannot meet.
2. **Fewer things.** No setting, window, section or element unless the feature cannot
   work without it (CLAUDE.md, "What the project optimises for"). Prefer removing.
3. **The system's switches, not ours.** Light and dark, Reduce Transparency, Increase
   Contrast, Reduce Motion and the language come from macOS. Pladder never repeats them
   as settings of its own.

## Colour and type

- **Type** is SF, the system font, everywhere: app, menu, pill and site. No webfont.
  The wordmark in the logo is the only other face, and it is an image.
- **Colour** is the system's greys and label colours. The one accent is coral,
  `#FF6A47`, the caret of the icon. It means "recording" or "the one action": the
  recording dot, the V key on the site and the Download button. Nothing else is coral.
- **Warnings** are a multicolour warning symbol beside text in the secondary label
  colour (`WarningLabel`). Never orange or red body text: on a grouped form it fails
  contrast.

## Settings

- **One window, three tabs:** General, Text, Dictionary. 540 pt wide. Each tab is as
  tall as what it shows, never taller than the screen; past that the form scrolls.
- **A grouped `Form`** of system controls: toggles, pickers, `LabeledContent`. No
  material, glass or tint on the window; Apple's own settings windows are plain.
- **Section headers in Title Case** ("Keyboard Shortcuts", "Recording Indicator");
  row labels in sentence case ("Mute other audio while recording").
- **A row that needs explaining gets one short subtitle** under its label, saying
  what it does or why, not how it works. A label that already says it gets none
  ("Check for updates automatically", "Mute other audio while recording"). The same sentence is the control's
  accessibility hint, so VoiceOver users moving control by control hear it too. On
  macOS `.help` and the accessibility hint are one attribute, so a control with help
  puts the hint first in it.
- **Permissions are asked from a button beside a sentence** saying what the grant is
  for ("Lets Pladder paste for you. …"), never by a system prompt at launch. In
  Clipboard mode by policy Accessibility is never asked for, and no sentence says
  "until you allow it".
- **A managed setting is disabled, never hidden:** the control shows the value the
  organisation's profile set, a picker offers only the allowed entries (disabled
  when there is one), and the group gets one footer line, "Managed by your
  organisation."; in a group the user still owns the rest of, that line is the
  control's own second subtitle instead. Without a profile nothing of it shows
  (docs/MANAGED.md).
- **Get Started** is the top of General only while setup is under way, and stays to
  the end of that session with "Pladder is ready" and a field to try the first
  dictation in. A routine model load at launch is not setup.
- **Shortcut fields:** an empty one is a "Record Shortcut" button; a recorded one is
  a well with the glyphs (⌥Space) and a clear button. All share one width per
  language. Focus rings only with Full Keyboard Access.
- **Choices with a picture** (the recording indicator styles) are a radio group of
  cards with a neutral thumbnail, focusable and announced as one group. Every pill is
  drawn at one scale and centred, so the cards compare sizes as the real pills do.
- **Work under way** is a sentence with an ellipsis. When it belongs to a row, a
  model switch say, it takes that row's subtitle; otherwise it is a row of its own
  with a small spinner at the trailing edge (`BusyRow`). A download shows its bar.
  Never the regular-size spinner: it outweighs the form, and the menu and its icon
  already say the model is loading.
- **Empty states** use `ContentUnavailableView` with the one action that fills them,
  and hide the controls that only make sense with content (the dictionary's table,
  its add and remove buttons, its test field).

## The menu

From top to bottom: the status line, then whatever needs the user (a missing grant,
a failed model, each with its own item), then "Copy Last Dictation" with the
transcript as its subtitle, then Suggested Corrections when there are any (Option
turns each into its own Dismiss), then About Pladder, Check for Updates… and
Settings…, and Quit Pladder alone below a divider. An update a scheduled check
found is one line at the top of the About group, "Pladder 0.3.0 is available —
Install…", there only until the user acts on it: it does not stop dictation, so it
does not go up with the grants, and it never opens a window or changes the icon by
itself. Menu text is short: a menu does not wrap, so a long sentence goes in a
subtitle.

## The menu bar icon

A template image, so it takes the menu bar's tint: the mark's four bars and caret,
drawn at whole and half points (`MenuBarIcon`). It changes only when it has something
to say:

- **Idle:** the mark. Also while transcribing, polishing and pasting, which last a
  fraction of a second and would otherwise blink the icon after every dictation.
- **Recording:** the bars follow the voice. Knocked out of a filled tile only with the
  Menu bar only style, where it is the sole sign of recording.
- **Starting or loading:** dimmed. Work, not failure.
- **Failed:** slashed.

## The pill

Liquid Glass in the system's appearance, with a hairline rim (a full separator under
Increase Contrast), resting above the Dock or just above the focused text field. Its
behaviour, from arrival to the release gather, is in docs/ARCHITECTURE.md, "The
overlay"; its look:

- **Four styles:** Compact (dot and wave), Minimal (a disc), Live (the words as they
  are spoken) and Menu bar only. One capsule shape for all, so every change is only a
  size.
- **Type:** SF 13, medium; the live words in regular, unsettled words in a lighter
  label colour until they settle.
- **Colour:** the coral dot while the microphone is on; the bars in the label colour
  (coral in Minimal while recording, grey once the microphone is off).
- **Width:** as wide as it needs. The Live row grows in steps with the words and never
  narrows within a take.
- **Errors** stay 4 s on two lines with a warning symbol; errors and "Copied. Press ⌘V
  to paste." are announced to VoiceOver.

## Words

- **Plain and short.** Say what happens, in the user's terms: "Hold to record, release
  to paste." Not how it works.
- **One name per thing,** used everywhere: Talk key, Hands-free key, Send key;
  recording indicator; speech model; dictionary; polish.
- **The ellipsis** marks work in progress ("Listening…", "Loading the speech model…")
  and a button that opens something more ("Settings…", "Allow…").
- **German** follows Apple's German: Sprechtaste, Freihandtaste, Sendetaste; Bereinigung;
  Groß/klein; Herunterladen for downloads and Laden for loading; a space before the
  ellipsis ("Hört zu …").
- **On the site,** curly quotes and apostrophes, and every number is a link to the
  benchmark it comes from.

Every sentence lives in `Sources/Pladder/StatusText.swift` or a view, keyed by its
exact English text; Core only emits enum cases (CLAUDE.md, "Pluggability rules").

## Accessibility

Part of every change, not a pass at the end:

- Every control's purpose reaches VoiceOver: the row's subtitle as its hint, a label on
  any control without visible text.
- Everything works by keyboard; focus rings follow Full Keyboard Access, as the
  system's do.
- Reduce Motion turns every flight and morph into a fade in place; Reduce Transparency
  and Increase Contrast are the system's to apply.
- What the user must know (an error, the clipboard fallback, a recording starting
  without sound) is announced.

## The website

`site/` keeps the app's restraint: SF, the system greys, coral for the Download
button only, one 1120 px container and one left edge, sections divided by a hairline,
one 16 px corner radius for its own boxes. No JavaScript and nothing from another server (CLAUDE.md,
"Website").

The hero is T3 Code's chat drawn in HTML and CSS, with the Live pill over it: text, so
it is sharp at any size and follows the visitor's light or dark mode. It fits its
column whole; nothing runs off the page. On one column (phones and narrow windows) the
hero reads headline, picture, the keys as its caption, then the words and the button:
the picture stays next to the claim it shows, and the keys next to the gesture. The README's hero picture is rendered from
the same markup, so the two never drift apart.

## Checking a change

Look at it before calling it done, light and dark, in English and German:

```sh
scripts/make-screenshots.sh <dir> --settings-scene                 # the real Settings window, each tab
scripts/make-screenshots.sh <dir> --settings-scene --get-started   # General at its tallest
scripts/make-screenshots.sh <dir> --settings-scene --accessibility # what VoiceOver is given
scripts/make-screenshots.sh <dir> --settings-scene --managed       # every managed control, disabled
scripts/make-screenshots.sh <dir> --menu                           # the real menu
scripts/overlay-demo.sh [dir] [--style …] [--reduce-motion]        # every pill path, as contact sheets
```

The site is plain files: open `site/index.html` from the branch, at phone and desktop
widths.

## Tried and dropped

So they are not tried again without a new reason:

- **A livelier recording wave** (a pulse from the centre, a scale that follows the
  voice, a held shape, randomness, flat in silence). Each variant was tuned on real
  dictation and the original meter was preferred: calmer, and it reads as Pladder.
- **A recorded film of the real pill as the site's hero.** The drawn T3 Code window
  says more about who Pladder is for, stays sharp and follows dark mode.
- **Settings for the pill's appearance, glass or animation speed.** They repeated
  system switches; removed, and their keys retired from the settings file.
- **A permission prompt at launch.** It appeared before the user had seen anything.
