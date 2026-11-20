# Security

Cutgenie runs a small control server so scripts and AI assistants can edit with it. It listens on **127.0.0.1 only**
(your own Mac, port 7878 or `CUTGENIE_PORT`) and has no password: any program running on your Mac as your user can send
it commands, including opening and saving projects and exporting files. Don't run untrusted software alongside it, and
don't forward the port to other machines.

Please report security problems privately to the maintainers (see the repository's contact details) rather than in a public issue.
