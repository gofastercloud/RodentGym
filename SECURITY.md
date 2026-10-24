# Security

RodentGym watches mouse and trackpad input, so it's worth being clear about what it can see and how to report a problem.

## What RodentGym has access to

- **Touches and button reports** from Magic Mouse and trackpad devices, through Apple's MultitouchSupport framework and IOHIDManager.
- **Mouse click events** in your login session, through a listen-only event tap. It can't block, change or create events, and it never watches the keyboard.
- **Bluetooth signal strength**, only if you turn it on in Settings.
- **One preference it can write:** the Magic Mouse split, and only when you move it.

It makes no network connections. Its log is written to `~/Library/Logs/RodentGym.log`, readable only by your user account.

## Supported versions

Security fixes go into the latest release. Please check you're on the latest version before reporting.

## Reporting a vulnerability

Please **don't** open a public issue for a security problem. Report it privately through GitHub's [private vulnerability reporting](https://github.com/gofastercloud/RodentGym/security/advisories/new) instead.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get an acknowledgement within a few days. Once a fix is out, you're welcome to be credited in the release notes.
