#!/usr/bin/env python3
"""Pin the existing prod_query.sh entry point to a verified isolated console.

Usage: python3 script/configure-production-console.py INSTANCE_IP production-REVISION

Provision web_server_generic first. This writes ~/.config/gumroad-prod-console.env;
use --replace to atomically repin after an allocation/image replacement.
An expired allocation pin fails closed instead of falling back to a shopper host.
Existing query auditing, database selection and freshness checks are unchanged.
"""

import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

BASTION = "bastion-production.gumroad.net"
IMAGE_REPOSITORY = "526234316351.dkr.ecr.us-east-1.amazonaws.com/gumroad/web"
MEMORY_LIMIT_BYTES = 3000 * 1024 * 1024
REMOTE = r'''
import json, subprocess, sys

def docker(*args):
    return subprocess.check_output(["sudo", "docker", *args], text=True)

expected = json.loads(docker("image", "inspect", sys.argv[1]))[0]["Id"]
ids = docker("ps", "-q", "--no-trunc", "--filter", "name=puma-", "--filter", "status=running").split()
candidates = []
for container in (json.loads(docker("inspect", *ids)) if ids else []):
    env = dict(entry.split("=", 1) for entry in container["Config"]["Env"] if "=" in entry)
    if env.get("NOMAD_JOB_NAME") == "web_server_generic" and env.get("NOMAD_TASK_NAME") == "puma":
        candidates.append({"name": container["Name"], "image": container["Image"],
                           "running": container["State"]["Running"],
                           "memory": container["HostConfig"]["Memory"]})
print("ISOLATED_CONSOLE=" + json.dumps({"expected_image": expected, "candidates": candidates}))
'''


def verify_target(output):
    records = [line.removeprefix("ISOLATED_CONSOLE=") for line in output.splitlines()
               if line.startswith("ISOLATED_CONSOLE=")]
    if len(records) != 1:
        raise ValueError("Missing or ambiguous isolated-console verification")
    result = json.loads(records[0])
    candidates = result["candidates"]
    if len(candidates) != 1:
        raise ValueError("Expected exactly one web_server_generic Puma task")
    target = candidates[0]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", result["expected_image"]):
        raise ValueError("Invalid expected image ID")
    if target["image"] != result["expected_image"] or target["running"] is not True:
        raise ValueError("Console image mismatch or container stopped")
    if type(target["memory"]) is not int or not 0 < target["memory"] <= MEMORY_LIMIT_BYTES:
        raise ValueError("Console memory limit must be nonzero and at most 3000 MiB")
    if not re.fullmatch(r"/puma-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", target["name"]):
        raise ValueError("Unexpected console container name")
    return target["name"]


def configure(ip, tag, config, replace=False):
    ipaddress.IPv4Address(ip)
    if not re.fullmatch(r"production-[0-9a-f]+", tag):
        raise ValueError("Expected production-<revision> image tag")
    config.parent.mkdir(parents=True, exist_ok=True)
    # Keep the lock inode: unlinking it would let concurrent installers lock
    # different files. Reject a competing installer before any SSH or changes.
    lock = os.open(str(config) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _configure_locked(ip, tag, config, replace)
    finally:
        os.close(lock)


def _configure_locked(ip, tag, config, replace):
    if config.is_symlink() or (config.exists() and not replace):
        raise ValueError(f"Refusing to replace existing config: {config}")
    original = config.read_bytes() if config.exists() else None
    command = shlex.join(["python3", "-c", REMOTE, f"{IMAGE_REPOSITORY}:{tag}"])
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "SendEnv=LC_PAPER", f"admin@{BASTION}", command],
        env={**os.environ, "LC_PAPER": ip}, capture_output=True, text=True,
        timeout=30, check=True,
    )
    name = verify_target(result.stdout)
    config.parent.mkdir(parents=True, exist_ok=True)
    # Publish the complete pin atomically without overwriting another installer.
    fd, temporary = tempfile.mkstemp(dir=config.parent, prefix=".console-pin-")
    try:
        with os.fdopen(fd, "w") as file:
            file.write(f"# Verified isolated console image: {tag}\n")
            file.write(f"export PROD_BASTION={shlex.quote(BASTION)}\n")
            file.write("export PROD_SECURITY_GROUP=production-generic_cluster\n")
            file.write(f"export PROD_INSTANCE_IP={shlex.quote(ip)}\n")
            file.write(f"export PROD_CONTAINER_FILTER={shlex.quote('^' + name + '$')}\n")
        if original is None:
            os.link(temporary, config)
        else:
            if config.is_symlink() or config.read_bytes() != original:
                raise ValueError("Console config changed during verification")
            os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("instance_ip")
    parser.add_argument("deploy_tag")
    parser.add_argument("--replace", action="store_true", help="Replace the existing pin only after verification succeeds")
    args = parser.parse_args()
    try:
        config = configure(args.instance_ip, args.deploy_tag, Path.home() / ".config/gumroad-prod-console.env", replace=args.replace)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Console isolation not installed: {error}\n")
    print(f"Installed {config}; next prod_query.sh calls use the isolated allocation.")


if __name__ == "__main__":
    main()
