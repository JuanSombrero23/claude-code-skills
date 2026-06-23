# Contributing

This is a personal marketplace of Claude Code skills; contributions and forks are welcome under the MIT license.

## Adding a skill

Each skill ships as a plugin under `plugins/<name>/`:

```
plugins/<name>/
├── .claude-plugin/plugin.json   # name, version, description, author, license, keywords
├── README.md                    # what it does, why it exists
└── skills/<name>/
    ├── SKILL.md                 # frontmatter (name + third-person description) + instructions
    ├── references/              # progressive-disclosure detail (optional)
    └── scripts/                 # helper scripts (optional)
```

Then add one entry to [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json).

### The SKILL.md bar
- `description` is written in the **third person** and states **when** the skill should trigger and **what** it covers — this is the text Claude matches against.
- Keep `SKILL.md` lean; push detail into `references/` and link to it (progressive disclosure).
- **No personal or client-confidential data.** Paths use `$HOME`, never a hardcoded user folder. Generated caches stay out of git (see [`.gitignore`](.gitignore)).

## Cross-platform help wanted

`session-curator`'s `launch` and `monitor` modes are currently Windows + Windows Terminal first. Native macOS (iTerm/Terminal) and Linux (tmux/gnome-terminal) launchers are very welcome. A zero-dependency Node.js port of the scripts (Node ships with Claude Code) is also on the table — open an issue to discuss before a large rewrite.

## Pull requests

Branch off `main`, keep the change focused, and open a PR. For anything touching a skill's scripts, note which OS you tested on.
