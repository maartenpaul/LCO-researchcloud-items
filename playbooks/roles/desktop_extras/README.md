# Desktop extras

SRC component: `playbooks/desktop-extras.yml` → role `desktop_extras`.

Small additions to the SRC Ubuntu desktop (Guacamole) flavour:

- archive tools: zip, 7zip, Xarchiver and Thunar's "Create/Extract archive";
- a drive on the Guacamole connection, linked as `~/Transfer`.

Implementation notes for the Guacamole edit:
- The edit is anchored on SRC's `security=rdp` param, and the XML is validated before it is written.
- The drive lives in `/var/lib/guacamole/drive/<user>` rather than `$HOME`, because guacd runs as `daemon`.
- On workspaces without Guacamole the edit does nothing.
