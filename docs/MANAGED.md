# Managing Pladder

For an organisation's IT: how to fix, on the Macs you manage, which speech model
Pladder runs, whether it polishes dictations with a language model, whether it
watches text fields to learn corrections, whether it uses Accessibility at all,
and whether it checks for updates. A user cannot undo any of it without admin
rights.

Everything here is optional. A Mac without a profile behaves exactly as before.

## How it works

Pladder reads a **configuration profile** with a Custom Settings payload
(`com.apple.ManagedClient.preferences`) for the preference domain
**`de.dinooo13.pladder`**. Deploy it with any MDM (Jamf, Kandji, Intune, Mosyle,
…) or, on a Mac with no MDM, install it by hand in System Settings → General →
Device Management, which needs an admin, as removing it does.

- Only values a profile forces count. `defaults write de.dinooo13.pladder …` by
  the user, or a file in `/Library/Preferences`, is ignored.
- Pladder never writes the managed domain, and never writes a managed value into
  its own settings file. Removing the profile gives every user their own choices
  back.
- A profile installed or removed while Pladder runs takes effect within about two
  seconds, without a relaunch. A dictation already on its way out finishes under
  the values it started with.
- A managed control stays visible in Settings, disabled on its managed value, with
  "Managed by your organisation." under its group.
- Nothing is reported anywhere: no telemetry, as ever.

## Keys

Two kinds of key, one rule each: **a toggle key forces that toggle** on or off;
**a picker key is a list of what the picker may offer**, and a list of one pins
it. A key that is missing leaves that choice to the user.

| Key | Type | Effect |
|---|---|---|
| `AllowedEngines` | Array of strings | The speech models the picker offers, by ID: `parakeet-ultra-incremental` (Parakeet Ultra, the default) and `parakeet-tdt-v3-incremental` (Parakeet TDT v3). One ID pins it. A user's stored choice outside the list runs the first allowed model |
| `PolishDictations` | Boolean | Forces the Polish toggle. `false`: no polish model is downloaded or loaded. `true`: every dictation is polished; where the model cannot run (Apple Intelligence off, say) the text is pasted as dictated |
| `AllowedPolishModels` | Array of strings | The polish models the picker offers: `appleIntelligence`, `s1Mini`, `s1Mini8Bit`. `appleIntelligence` alone means nothing is ever downloaded for polish. One pins it |
| `LearnCorrections` | Boolean | Forces "Suggest entries from my corrections" in the Dictionary tab. `false`: no text field is ever read after a paste and no correction is reviewed. `true`: on, where Accessibility and Apple Intelligence allow it |
| `ClipboardMode` | Boolean | `true`: Clipboard mode, below. `false` is the same as leaving the key out |
| `UpdateChecks` | Boolean | Forces "Check for updates automatically". `false` also removes Check for Updates… from the menu, so Pladder makes no update request at all; use it when you deploy updates yourself. `true`: once a day |

A value of the wrong type, an ID Pladder does not know, or a list with no ID it
knows is ignored and logged, so a typo never leaves Pladder without a speech
model. A forced `s1Mini` or `s1Mini8Bit` with polish on downloads its file (805 MB
or 1.5 GB, from Hugging Face, checked against its SHA-256) at the next dictation,
as a user's choice would.

### Clipboard mode

Without Accessibility Pladder still works: it hears its talk key through the
system's hotkey registration, which needs no permission, and leaves the
transcript on the clipboard for the user to paste with ⌘V. `ClipboardMode = true`
keeps it that way even when Accessibility is granted:

- It never asks for Accessibility: no button in Settings, no menu item.
- It installs no event tap and posts no keystrokes: no ⌘V, no send key.
- It reads no other app's text field: not to place the recording indicator, not to
  learn corrections.
- A talk key of modifiers alone, such as Right Command, cannot be registered;
  Option+Space stands in for it.

## Example profile

Pins Parakeet TDT v3, turns polish and the correction learner off, and stops
update checks. Change the two `PayloadUUID`s (`uuidgen`) and the identifiers to
your own before deploying it.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>com.example.pladder</string>
    <key>PayloadUUID</key>
    <string>6B1F5E2A-3C4D-4E8F-9A0B-1C2D3E4F5A6B</string>
    <key>PayloadDisplayName</key>
    <string>Pladder</string>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.example.pladder.preferences</string>
            <key>PayloadUUID</key>
            <string>7C2A6F3B-4D5E-4F90-8B1C-2D3E4F5A6B7C</string>
            <key>PayloadDisplayName</key>
            <string>Pladder settings</string>
            <key>PayloadContent</key>
            <dict>
                <key>de.dinooo13.pladder</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>AllowedEngines</key>
                                <array>
                                    <string>parakeet-tdt-v3-incremental</string>
                                </array>
                                <key>PolishDictations</key>
                                <false/>
                                <key>LearnCorrections</key>
                                <false/>
                                <key>UpdateChecks</key>
                                <false/>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

To see what Pladder made of a profile:

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "de.dinooo13.pladder" && category == "settings"'
```

It logs `managed policy: <the keys in effect>` at launch and whenever the profile
changes, and one line for each value it ignored.

## Permissions

- **Microphone** cannot be granted by a profile: a Privacy Preferences Policy
  Control (PPPC) payload can only deny it. Each user answers the macOS prompt once.
- **Accessibility** can be pre-granted with a PPPC payload for the bundle ID
  `de.dinooo13.pladder` and its Developer ID code requirement (`codesign -dr -
  /Applications/Pladder.app`), so the user is never asked. Leave it out, or set
  `ClipboardMode`, to keep Pladder off Accessibility.

## Not covered

- **Offline model provisioning.** A pinned speech model still downloads about
  700 MB from Hugging Face at first launch. A Mac that cannot reach
  `huggingface.co` cannot dictate yet.
- The dictionary, the cleanup steps, the keys, the recording indicator and the
  sounds stay the user's.
- The policy binds Pladder as distributed. Someone who builds it from source can
  run a copy without it; stopping that is app allow-listing's job (Gatekeeper,
  your MDM).
- `pladder-cli`, a developer tool, reads no policy.
