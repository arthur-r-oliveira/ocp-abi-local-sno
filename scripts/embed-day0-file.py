#!/usr/bin/env python3
"""Merge a plain file into an agent-based-installer ISO's REAL embedded
Ignition config - the one that actually governs first boot - via
`coreos-installer iso ignition show`/`embed`.

Why this exists: openshift-install agent's "Day-0 extra manifests"
(<install_dir>/openshift/*.yaml) do NOT land on the live boot
filesystem. They get staged at /etc/assisted/extra-manifests/ for the
Machine Config Operator to apply once the cluster exists - a Day-1
mechanism, not a pre-boot one, confirmed the hard way while working
around the HSR/PRP gen_conf bug (see docs/prp-test-case.md and
docs/spec-test-case-3-prp-primary.md). If a file needs to exist on the
node BEFORE it has any network - which is exactly the situation for a
topology where a broken interface leaves zero connectivity - it has to
go through this route instead: the ISO's own top-level Ignition config,
which ignition applies before any topology-specific bootstrapping.

Usage: embed-day0-file.py <iso> <dest-path-in-root-fs> <local-content-file> [mode-octal]
"""
import base64
import json
import subprocess
import sys


def main():
    if len(sys.argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    iso, dest_path, content_file = sys.argv[1:4]
    mode = int(sys.argv[4], 8) if len(sys.argv) == 5 else 0o644

    show = subprocess.run(
        ["coreos-installer", "iso", "ignition", "show", iso],
        check=True, capture_output=True, text=True,
    )
    cfg = json.loads(show.stdout)

    with open(content_file, "rb") as f:
        content = f.read()
    b64 = base64.b64encode(content).decode()

    files = cfg.setdefault("storage", {}).setdefault("files", [])
    # Idempotent: replace any prior entry for this exact path instead of
    # accumulating duplicates across repeated playbook runs.
    files[:] = [f for f in files if f.get("path") != dest_path]
    files.append({
        "path": dest_path,
        "contents": {"source": f"data:;base64,{b64}"},
        "mode": mode,
        "overwrite": True,
    })

    # No -i flag: coreos-installer reads the Ignition config from stdin by
    # default. Passing "-i -" is NOT equivalent - it tries to open a file
    # literally named "-" and fails.
    subprocess.run(
        ["coreos-installer", "iso", "ignition", "embed", "--force", iso],
        input=json.dumps(cfg), text=True, check=True,
    )
    print(f"Embedded {content_file} -> {dest_path} into {iso}")


if __name__ == "__main__":
    main()
