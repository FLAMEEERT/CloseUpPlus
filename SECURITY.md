# Security Policy

## Supported versions

CloseUpPlus currently ships as a manual GitHub Release download. Security fixes
land in the **latest release only** — there are no back-ported patch branches.
If you are running an older build, download the latest release before reporting.

| Version            | Supported          |
| ------------------ | ------------------ |
| Latest release     | :white_check_mark: |
| Anything older     | :x:                |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.** Disclose
privately so a fix can ship before the details are public.

Two private channels, either is fine:

- **GitHub Security Advisories** — open a private report at
  <https://github.com/FLAMEEERT/CloseUpPlus/security/advisories/new>
  (preferred; keeps the discussion and fix linked to the repo).
- **Email** — <bh@bugs.cc>. Feel free to encrypt or request a key first if you
  want to send sensitive details.

When you report, please include as much as you can:

- The CloseUpPlus version (menu bar → **About**) and your macOS version and CPU
  (Apple silicon / Intel).
- A description of the issue and its impact.
- Steps to reproduce, a proof of concept, or a crash log if you have one.
- Any relevant configuration (which control buttons are enabled, custom
  shortcuts, the in-app language).

## What to expect

- **Acknowledgement** within 3 business days.
- An initial assessment and severity triage within 7 business days.
- Progress updates as we investigate, and credit in the release notes once a
  fix ships — unless you ask to stay anonymous.

We follow coordinated disclosure: please give us a reasonable window to release
a fix before disclosing publicly.

## Scope and notes

CloseUpPlus is a non-sandboxed macOS menu-bar app that overlays window controls onto
the native macOS Mission Control. Some behavior is by design and generally **out
of scope** unless you can show it crosses a real trust boundary:

- **Accessibility permission.** CloseUpPlus needs Accessibility to read window
  geometry and to drive each window's native controls (close / minimize / zoom /
  hide / quit) through the Accessibility API, and it installs a `CGEvent` tap to
  capture clicks and shortcuts **only while Mission Control is open**. It does
  does not log keystroke *content*. The Pin feature separately uses Screen
  Recording permission to mirror only the selected window locally; transmitting
  typed text or captured frames is in scope.
- **Private Mission Control APIs.** The overlay relies on undocumented system
  APIs (observed via the Dock and enumerated with `CGWindowList`). Reports that
  a crafted window, app, or event can use this path to escalate beyond acting on
  the windows the user already sees in Mission Control are in scope.
- **Updates.** Automatic updates are disabled in the current unsigned release.
  Reports that cause untrusted code to be installed or executed are high priority.
- **Local app preferences** (settings, login-item registration): issues that let
  untrusted input escalate privileges or persist code are in scope.

Thanks for helping keep CloseUpPlus and its users safe.
