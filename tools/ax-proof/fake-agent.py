#!/usr/bin/env python3
"""A throwaway stand-in for an agent chat (HM-1374 tests). Run it in a folder that
holds a `.needs-you-axtest` file. It registers with Needs You the way Claude Code
does (the `needs-you mcp` server plus hooks), shows a "reply" on screen, and writes
every line typed into it to out.txt. Nothing here talks to a real chat.

    cd <throwaway folder> && touch .needs-you-axtest && python3 fake-agent.py <name> [folder]
"""
import json, os, subprocess, sys, time

name = sys.argv[1] if len(sys.argv) > 1 else "axtest"
if len(sys.argv) > 2: os.chdir(sys.argv[2])
cwd = os.getcwd()
assert os.path.exists(".needs-you-axtest"), "not a test folder"
env = dict(os.environ, NEEDS_YOU_AGENT="axtest")
# A terminal opened from inside herdr or tmux inherits their pane ids: drop them
# unless this chat really runs in a throwaway multiplexer (AXTEST_MUX=1).
if os.environ.get("AXTEST_MUX") != "1":
    for k in ["HERDR_PANE_ID", "HERDR_SOCKET_PATH", "HERDR_ENV", "TMUX", "TMUX_PANE"]:
        env.pop(k, None)
cli = os.path.expanduser("~/.local/bin/needs-you")

mcp = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, env=env, text=True)
def rpc(i, method, params):
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
    mcp.stdin.flush()
rpc(1, "initialize", {"protocolVersion": "2025-06-18"})
rpc(2, "tools/call", {"name": "status", "arguments": {"text": f"axtest {name}: throwaway test chat"}})

def hook(event, **kw):
    subprocess.run([cli, "hook", event, "--agent", "axtest"], input=json.dumps({"cwd": cwd, **kw}),
                   env=env, text=True, capture_output=True, timeout=10)

last = [""]
def reply(text):
    last[0] = text
    print("\n" + text, flush=True)
    hook("Stop", last_assistant_message=text)

# The app forgets chat states when it restarts: say "idle" again every 15 s.
import threading
def keep_idle():
    while True:
        time.sleep(15)
        if last[0]: hook("Stop", last_assistant_message=last[0])
threading.Thread(target=keep_idle, daemon=True).start()

hook("SessionStart")
time.sleep(0.5)
reply(f"AXTEST {name} is ready in {os.path.basename(cwd)} and waits for a voice message")
n = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    with open("out.txt", "a") as f:
        f.write(line + "\n")
    if not line.strip() or line.startswith("(sent by voice"):
        continue
    n += 1
    hook("UserPromptSubmit", prompt=line)
    reply(f"AXTEST {name} got message {n}: {line[:50]}")
