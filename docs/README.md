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

### 2. The interface
1. [A tour of the window](02-interface/01-window-tour.mdx)
2. [The media panel](02-interface/02-media-panel.mdx)
3. [The viewer](02-interface/03-viewer.mdx)
4. [Inspector: Effects](02-interface/04-inspector-effects.mdx)
5. [Inspector: Color](02-interface/05-inspector-colour.mdx)
6. [Inspector: Audio](02-interface/06-inspector-audio.mdx)
7. [The timeline and tracks](02-interface/07-timeline.mdx)
8. [The tools](02-interface/08-tools.mdx)
9. [Change the layout](02-interface/09-layout.mdx)

### 3. Projects
1. [Make a new project](03-projects/01-new-project.mdx)
2. [Choose a format](03-projects/02-formats.mdx)
3. [Open, switch and close projects](03-projects/03-open-switch-close.mdx)
4. [The project browser](03-projects/04-project-browser.mdx)
5. [Rename, move or duplicate a project](03-projects/05-rename-move-duplicate.mdx)
6. [Go back to an earlier version](03-projects/06-versions.mdx)
7. [Autosave and crash recovery](03-projects/07-autosave-recovery.mdx)
8. [Relink missing media](03-projects/08-relink-media.mdx)
9. [Collect media in one folder](03-projects/09-collect-media.mdx)

### 4. Importing
1. [Import clips](04-importing/01-import-clips.mdx)
2. [Which files work](04-importing/02-formats.mdx)
3. [Organise your media](04-importing/03-organise-media.mdx)
4. [Sync a separate microphone](04-importing/04-sync-by-sound.mdx)
5. [Bring in a Final Cut Pro project](04-importing/05-fcpxml-import.mdx)

### 5. Editing basics
1. [Add clips to the timeline](05-editing-basics/01-append-insert.mdx)
2. [The magnetic main track](05-editing-basics/02-magnetic-timeline.mdx)
3. [Play and move around](05-editing-basics/03-playback-navigation.mdx)
4. [Cut a clip in two](05-editing-basics/04-blade.mdx)
5. [Trim the start or end of a clip](05-editing-basics/05-trim.mdx)
6. [Move clips and snapping](05-editing-basics/06-move-snap.mdx)
7. [Delete: close the gap or leave it](05-editing-basics/07-delete.mdx)
8. [Undo and redo](05-editing-basics/08-undo.mdx)
9. [Markers](05-editing-basics/09-markers.mdx)
10. [Groups and linked sound](05-editing-basics/10-groups-linking.mdx)
11. [Speed and slow motion](05-editing-basics/11-speed.mdx)

### Coming soon
6. Picture · 7. Colour · 8. Graphics ·
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
