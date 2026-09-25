# Desktop extras

SRC component: `playbooks/desktop-extras.yml` → role `desktop_extras`.

Fixes for the SRC Ubuntu desktop (Guacamole) flavour. On other flavours the Guacamole part does nothing.

- **File transfer through the browser.** SRC's Guacamole connection has no drive. This role adds one (`enable-drive`, one folder per user under `/var/lib/guacamole/drive`) and restarts tomcat10.
  - Uploads from the Guacamole menu (Ctrl+Alt+Shift) appear in `~/Transfer` inside the session.
  - The drive is not `$HOME` itself: guacd runs as `daemon`, so files would be owned by it.
  - The edit is anchored on SRC's `security=rdp` param. The deploy fails if that param is missing, and the XML is validated before it is written.
- **Archive tools:** zip, 7zip, Xarchiver and Thunar's "Create/Extract archive".
