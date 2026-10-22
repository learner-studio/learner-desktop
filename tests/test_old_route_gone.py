#!/usr/bin/env python3
"""Fast lane: the SSH-tunnel route into learner-server's databases stays retired.

The app used to write habit rows straight into Postgres (`habits`, via a :15432 forward
and a `habits_writer` password in .env) and conversations into Hindsight (:18925). Since
2026-10-22 everything goes to learner-server's HTTPS RPC API; the server also revoked
that database role. This fails if any of it creeps back outside vendor/.
"""

import os
import re
import subprocess
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FORBIDDEN = re.compile(r"15432|18925|HABITS_PG_URL|HINDSIGHT_URL|HINDSIGHT_BANK|postgres://|habits_writer|sync-habits|hindsight-client")
# Files that describe the retirement itself.
ALLOWED = {"tests/test_old_route_gone.py"}


class OldRouteGoneTest(unittest.TestCase):
    def test_no_tunnel_database_route_outside_vendor(self):
        files = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                               cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
        hits = []
        for f in files:
            if f.startswith("vendor/") or f in ALLOWED or not os.path.isfile(os.path.join(REPO, f)):
                continue
            try:
                with open(os.path.join(REPO, f), encoding="utf-8") as fh:
                    for n, line in enumerate(fh, 1):
                        if FORBIDDEN.search(line):
                            hits.append(f"{f}:{n}: {line.strip()[:100]}")
            except UnicodeDecodeError:
                continue
        self.assertEqual(hits, [], "old SSH-tunnel route referenced:\n" + "\n".join(hits))


if __name__ == "__main__":
    unittest.main()
