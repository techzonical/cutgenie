# Contributing to Cutgenie

Thanks for helping! A few simple rules keep the project easy to work on.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Keep changes focused: one fix or feature per pull request.

## Building and checking

```bash
zsh scripts/build_app.sh     # app + control tool
python3 tests/smoke.py       # must pass
python3 tests/check_all.py   # if you have test footage (see docs/13-reference/08-testing.mdx)
```

Please run the smoke test before every pull request, and the full suite when you change rendering, sound, export or
editing logic. If you fix a bug that only showed up on real footage, add a check for it to `tests/check_all.py`.

## Code style

- Swift, following the style already in the file you're editing. Short comments that explain *why*, written in plain
  language for people who aren't video engineers.
- Every edit goes through `Editor.handle` (see docs/13-reference/05-architecture.mdx), so it works the same from the mouse and from
  `cutgeniectl`. New features should get a control command too.
- Never write to the user's media files; projects are saved atomically and old versions are kept.
- No new dependencies without discussion; Cutgenie uses only Apple frameworks.

## Reporting bugs

Include your macOS version, Mac model, what you did, what you expected, and the relevant part of
`~/Library/Logs/Cutgenie/cutgenie.log`. A small project file that shows the problem helps a lot (remove anything private).
