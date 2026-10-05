#!/usr/bin/env python3
"""Offline checks for private GitHub downloads; never starts node installation."""
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
TOKEN = "github_pat_OFFLINE_TEST_MARKER"
MOCK_CURL = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
token = "github_pat_OFFLINE_TEST_MARKER"
args = sys.argv[1:]
assert token not in " ".join(args), "Token in curl arguments"
assert not any(token in value for value in os.environ.values()), "Token in child environment"
assert args[args.index("--header", args.index("--header") + 1) + 1] == "X-GitHub-Api-Version: 2026-03-10"
assert "Accept: application/vnd.github.raw+json" in args
assert "@/dev/fd/3" in args
assert pathlib.Path("/dev/fd/3").read_text() == "Authorization: Bearer " + token + "\n"
url = next(a for a in args if a.startswith("https://"))
assert url.startswith("https://api.github.com/repos/VBZZZR/xui-node-deploy/contents/")
assert url.endswith("?ref=main")
name = url.rsplit("/", 1)[1].split("?", 1)[0]
with open(os.environ["MOCK_CURL_LOG"], "a") as log:
    log.write(json.dumps({"file": name, "token_in_arguments": False, "token_in_environment": False}) + "\n")
if os.environ.get("MOCK_FAILURE_FILE") == name:
    sys.stderr.write("curl: (22) HTTP " + os.environ.get("MOCK_HTTP_CODE", "401") + "\n")
    sys.exit(22)
destination = pathlib.Path(args[args.index("--output") + 1])
if os.environ.get("MOCK_CORRUPT_FILE") == name:
    destination.write_bytes(b"corrupted download\n")
else:
    shutil.copyfile(pathlib.Path(os.environ["MOCK_SOURCE_DIR"]) / name, destination)
'''


def environment(directory, **overrides):
    mock_bin = directory / "bin"
    mock_bin.mkdir()
    curl = mock_bin / "curl"
    curl.write_text(MOCK_CURL)
    curl.chmod(0o700)
    env = os.environ.copy()
    env.update(
        PATH=str(mock_bin) + ":" + env["PATH"],
        XUI_INSTALL_DIR=str(directory / "downloads"),
        MOCK_SOURCE_DIR=str(ROOT),
        MOCK_CURL_LOG=str(directory / "requests.jsonl"),
        **overrides,
    )
    return env


def assert_no_secret(directory, result):
    assert TOKEN not in result.stdout + result.stderr, "Token in output"
    for path in directory.rglob("*"):
        if path.is_file() and path.name != "curl":
            assert TOKEN.encode() not in path.read_bytes(), "Token written to disk"
    downloads = directory / "downloads"
    if downloads.exists():
        assert not list(downloads.glob(".download.*")), "Temporary downloads not cleaned"


def invoke(directory, env, token=TOKEN):
    driver = 'IFS= read -r token; exec 3< <(printf "%s\\n" "$token"); unset token; exec bash -x "$1" VBZZZR/xui-node-deploy --download-only'
    result = subprocess.run(
        ["bash", "-c", driver, "test-driver", str(ROOT / "install.sh")],
        input=token + "\n", text=True, capture_output=True, env=env, timeout=10,
    )
    assert_no_secret(directory, result)
    return result


def run_case(name, *, error_file=None, status="401", corrupt=None, token=TOKEN, old_files=False):
    with tempfile.TemporaryDirectory(prefix="xui-private-test-") as temporary:
        directory = Path(temporary)
        env = environment(directory)
        if error_file:
            env.update(MOCK_FAILURE_FILE=error_file, MOCK_HTTP_CODE=status)
        if corrupt:
            env["MOCK_CORRUPT_FILE"] = corrupt
        downloads = directory / "downloads"
        if old_files:
            downloads.mkdir()
            (downloads / "xui-node-docker.sh").write_text("previous installer\n")
            (downloads / "xui-docker-image.lock.json").write_text("previous lock\n")
        result = invoke(directory, env, token)
        if error_file or corrupt or token != TOKEN:
            assert result.returncode != 0, name
            if old_files:
                assert (downloads / "xui-node-docker.sh").read_text() == "previous installer\n"
                assert (downloads / "xui-docker-image.lock.json").read_text() == "previous lock\n"
            else:
                assert not (downloads / "xui-node-docker.sh").exists()
        else:
            assert result.returncode == 0, result.stderr
            for file in ["xui-node-docker.sh", "xui-docker-image.lock.json"]:
                assert (downloads / file).read_bytes() == (ROOT / file).read_bytes()
            assert (downloads / "xui-node-docker.sh").stat().st_mode & 0o777 == 0o700
            assert (downloads / "xui-docker-image.lock.json").stat().st_mode & 0o777 == 0o600
            if old_files:
                assert len(list(downloads.glob("*.bak.*"))) == 2
        print("PASS", name)


def check_readme_bootstrap():
    blocks = re.findall(r"```bash\n(.*?)\n```", (ROOT / "README.md").read_text(), re.S)
    for index, block in enumerate(blocks):
        subprocess.run(["bash", "-n"], input=block, text=True, check=True)
    bootstrap = next(block for block in blocks if "GitHub-токен из шага 2" in block)
    expected = hashlib.sha256((ROOT / "install.sh").read_bytes()).hexdigest()
    assert expected in bootstrap
    command = 'bash "$bootstrap" VBZZZR/xui-node-deploy'
    assert bootstrap.count(command) == 1
    bootstrap = bootstrap.replace(command, command + " --download-only")
    with tempfile.TemporaryDirectory(prefix="xui-private-readme-") as temporary:
        directory = Path(temporary)
        env = environment(directory)
        master, slave = pty.openpty()
        process = subprocess.Popen(["bash", "-c", bootstrap], stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = bytearray()
        sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output.extend(data)
                    if not sent and "GitHub-токен из шага 2".encode() in output:
                        os.write(master, TOKEN.encode() + b"\n")
                        sent = True
                if process.poll() is not None and not ready:
                    break
            assert sent, "No hidden token prompt"
            assert process.wait(timeout=2) == 0, output.decode(errors="replace")
            result = subprocess.CompletedProcess([], 0, output.decode(errors="replace"), "")
            assert_no_secret(directory, result)
            requests = [json.loads(line)["file"] for line in (directory / "requests.jsonl").read_text().splitlines()]
            assert requests == ["install.sh", "xui-node-docker.sh", "xui-docker-image.lock.json"]
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    print("PASS README hidden prompt, token handoff and full download chain")
    print("PASS", len(blocks), "README Bash blocks")


if __name__ == "__main__":
    run_case("valid download")
    run_case("changed files are backed up", old_files=True)
    run_case("401 preserves existing files", error_file="xui-node-docker.sh", old_files=True)
    run_case("403 stops", error_file="xui-node-docker.sh", status="403")
    run_case("404 missing image-lock stops", error_file="xui-docker-image.lock.json", status="404", old_files=True)
    run_case("damaged installer stops", corrupt="xui-node-docker.sh", old_files=True)
    run_case("damaged image-lock stops", corrupt="xui-docker-image.lock.json", old_files=True)
    run_case("invalid token stops before requests", token="bad token")
    check_readme_bootstrap()
