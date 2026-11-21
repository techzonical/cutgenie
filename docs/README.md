# Cutgenie user guide

Welcome! This guide teaches you Cutgenie, a free video editor for the Mac, one small step at a time.
You don't need to know anything about video editing to start. Every page does one job and takes a few minutes.

> New here? Start with [What is Cutgenie?](01-getting-started/01-what-is-cutgenie.mdx) and read the
> Getting started chapter in order.

## Contents

### 1. Getting started
1. [What is Cutgenie?](01-getting-started/01-what-is-cutgenie.mdx)
2. [What you need](01-getting-started/02-requirements.mdx)
3. [Install Cutgenie](01-getting-started/03-install.mdx)
4. [Open it for the first time](01-getting-started/04-first-launch.mdx)
5. [Update to a new version](01-getting-started/05-updating.mdx)
6. [Remove Cutgenie](01-getting-started/06-uninstalling.mdx)

### Coming soon
2. The interface · 3. Projects · 4. Importing · 5. Editing basics · 6. Picture · 7. Colour · 8. Graphics ·
9. Sound · 10. Exporting · 11. Shortcuts · 12. Editing with Claude · 13. Reference

---

## For people writing these docs

- **One folder per chapter**, numbered: `docs/01-getting-started/`, `docs/02-interface/`, ...
- **One page per task**, numbered inside the folder: `01-what-is-cutgenie.mdx`, ...
- Pages are `.mdx` but use **plain GitHub Markdown only** (no JSX components), so they read well on GitHub and can be
  dropped into the website later.
- Every page starts with this frontmatter:

  ```yaml
  ---
  title: Install Cutgenie            # page heading and menu label
  description: One sentence for search results and link previews.
  section: Getting started           # chapter name, the same on every page in the folder
  order: 3                           # position inside the chapter
  ---
  ```
- **All screenshots** live in `docs/images/<chapter folder>/`, linked with relative paths such as
  `../images/01-getting-started/first-launch.png`.
- Screenshots are made automatically by `zsh scripts/make_screenshots.sh` from a separate test copy of Cutgenie
  (port 7879) with generated test clips. Never take them from your real projects. To use nicer footage, see the top of
  that script.
- Writing style: short sentences, plain words, explain each new term the first time it appears.
