# WinBrowse

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

Do not add comments to the code. If a comment excuses a weak design, remove the comment and improve the code. Check your work before you say it is done.

Keep implicit state machines to a minimum.
Do not low value and low signal tests that waste time in CI.

## Git workflow

Do not create branches. Work, commit and push directly on `main`. The `origin` remote is the maintainer's private CI server. CI and releases run there, see `docs/ci.md`.

## Mobile development builds

Run Xcode/iOS and simulator builds on the Mac build machine over SSH, not on the laptop. Clean up afterwards: stop simulators and background build processes, and delete temporary checkouts and DerivedData you created on that Mac.

CI iOS jobs run on the Mac build machine: a host-mode runner with the `ios` label. Manual builds also go over SSH to that Mac. Linux iOS builds (xtool) were evaluated and are not viable; do not plan around them.

Private values (host names, addresses, tailnet names, account IDs, key file names and logins) are in the maintainer's private notes. Run `infra show` on the maintainer's own machine to read them. Never write them into tracked files, commit messages, pull requests or CI output. Never skip the git hooks with `--no-verify`.

## Finishing work

Please avoid stopping while you still owe work the user asked for. Be persistent and do not stop unless needed.

While status notes are welcome, as is clarifying with the user on open decisions, carry on with work that does not depend on the user's answer without unnecessary stops.

If you notice yourself inviting the user to redirect you or offering to wait, instead proceed on the next part of the task. You may meet ordinary obstacles like errors, timeouts, locked files, empty results or failing tools. Diagnose them first, and when they are not real blockers, work through them with the access you have (wait and retry, fix the request, use another tool or source) rather than stopping unnecessarily.

If someone clearly decided something is a hard blocker, such as a file marked not to be touched, access that was intentionally withheld, or a safety guardrail, leave it alone, say plainly what you found, and look for another safe way to finish the task. Stopping before the task is complete is very rarely merited, as in when the task can't move forward without user input, or where the blocker is deliberate and should not be worked past. This does not override the need for confirmation on risky or destructive actions.

## Communicating clearly

Write for an intelligent but low-context reader. The person reading has not seen your tool calls, your reasoning or the files you opened, and may be switching in from other work. Messages should generally be self-contained: the reader should understand what you mean without having to dig for other context. Put the key points in the first few sentences. Practice progressive disclosure in your sentence order, and do not use undefined references and ideas in line 1 that won't make sense until the reader reaches line 12.

Use plain words, and write in clear, understandable full sentences. Do not use a term or abbreviation that you made up during the work. Say what the thing is in a way any reader would understand. Write mostly in the style of ASD-STE100 Simplified Technical English: short sentences, one idea per sentence, active voice, and consistently using the same word for the same thing. Use a paragraph of flowing prose where ideas connect, and keep bullets for lists of separate items. Leave out unnecessary details unless the reader asks and practice concision, but do ensure that your messages have the key context. Aim to make your user-facing text as human-readable and clear as possible.
