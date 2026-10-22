#!/usr/bin/env python3
"""Stands in for github.com (the refs git advertises) and raw.githubusercontent.com (files) in the GitHub-install checks.

    /web/<owner>/<name>.git/info/refs?service=git-upload-pack   pkt-line refs; 401 for unknown repositories, like GitHub
    /raw/<owner>/<name>/<commit>/<path>                         files, ONLY at a full commit id: a branch or tag name gets
                                                                404, so any download that wasn't pinned fails the checks
    POST /__move?repo=<owner/name>&ref=<refs/heads/x>&to=<commit>   moves a branch (someone pushed)
    GET  /__log                                                 every raw path requested so far, one per line

Usage: fake-github.py <port-file>  (binds a free port and writes it there)
"""
import http.server
import json
import sys
import urllib.parse


def commit(n):
    return format(n, "040x")


S1, S2, S3, C1, TAG = commit(0x51), commit(0x52), commit(0x53), commit(0xC1), commit(0x7A9)


def manifest(name, version, **extra):
    data = {"name": name, "version": version, "author": "Acme", "description": f"{name} for the checks",
            "matches": ["https://orgcs.lightning.force.com/*"], "js": ["content.js"], "permissions": ["storage"]}
    data.update(extra)
    return json.dumps(data, indent=2)


LIBRARY = json.dumps({"name": "Shared Lib", "version": "1.1.0", "author": "Acme", "description": "Shared code",
                      "type": "library", "js": ["index.js"]})

REPOS = {
    "acme/single": {
        "refs": {"HEAD": S1, "refs/heads/main": S1, "refs/heads/feature/login": S3,
                 "refs/tags/v1.0.0": TAG, "refs/tags/v1.0.0^{}": S1},
        "commits": {
            S1: {"manifest.json": manifest("Single", "1.0.0"), "content.js": "console.log('single v1')",
                 "docs/readme.md": "not an extension",
                 "extras/remote/manifest.json": manifest("Remote Thing", "0.9.0"), "extras/remote/content.js": "1",
                 "extras/other/manifest.json": manifest("Other Default", "0.1.0"), "extras/other/content.js": "2"},
            S2: {"manifest.json": manifest("Single", "2.0.0"), "content.js": "console.log('single v2')"},
            S3: {"manifest.json": manifest("Single", "1.0.0"), "content.js": "console.log('single v1')",
                 "sub/ext/manifest.json": manifest("Sub Ext", "0.3.0", id="sub-ext"), "sub/ext/content.js": "sub"},
        },
    },
    "acme/collection": {
        "refs": {"HEAD": C1, "refs/heads/main": C1},
        "commits": {
            C1: {
                "extensions.json": json.dumps({"version": 1, "extensions": [
                    {"id": "greeter"}, {"id": "shared-lib"}, {"id": "broken"},
                    {"id": "remote-thing", "repository": "acme/single", "ref": "main", "path": "extras/remote"},
                    {"id": "other-default", "repository": "acme/single", "path": "extras/other"}]}),
                "greeter/manifest.json": manifest("Greeter", "1.2.0", dependencies={"shared-lib": "^1.0.0"}),
                "greeter/content.js": "console.log('greeter')",
                "shared-lib/manifest.json": LIBRARY,
                "shared-lib/index.js": "module.exports = {}",
            },
        },
    },
    # Sibling folders and no extensions.json: app needs the util library beside it.
    "acme/plain": {
        "refs": {"HEAD": S1, "refs/heads/main": S1},
        "commits": {S1: {
            "app/manifest.json": manifest("App", "1.0.0", dependencies={"util": "^2.0.0"}), "app/content.js": "app",
            "util/manifest.json": json.dumps({"name": "Util", "version": "2.1.0", "author": "Acme", "description": "u",
                                              "type": "library", "js": ["util.js"]}),
            "util/util.js": "module.exports = 1",
        }},
    },
    # No "id" in the manifest: the id comes from the repository name, lowercased.
    "Acme/Mixed_Case": {
        "refs": {"HEAD": S1, "refs/heads/main": S1},
        "commits": {S1: {"manifest.json": manifest("Mixed", "1.0.0"), "content.js": "x"}},
    },
    # ...and here that name can't be an id (it starts with "_"), so the manifest must say.
    "acme/_underscore": {
        "refs": {"HEAD": S1, "refs/heads/main": S1},
        "commits": {S1: {"manifest.json": manifest("Underscore", "1.0.0"), "content.js": "x"}},
    },
}

LOG = []


def pkt(line):
    data = line.encode()
    return b"%04x" % (len(data) + 4) + data


def advertisement(refs):
    out = pkt("# service=git-upload-pack\n") + b"0000"
    first = True
    for name in ["HEAD"] + sorted(k for k in refs if k != "HEAD"):
        if name not in refs:
            continue
        line = f"{refs[name]} {name}"
        if first:
            line += "\0multi_ack thin-pack side-band symref=HEAD:refs/heads/main agent=git/fake"
            first = False
        out += pkt(line + "\n")
    return out + b"0000"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body=b"", kind="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        parts = [urllib.parse.unquote(p) for p in url.path.split("/") if p]
        if parts == ["__log"]:
            return self.send(200, "\n".join(LOG).encode())
        if len(parts) == 5 and parts[0] == "web" and parts[2].endswith(".git") and parts[3:] == ["info", "refs"]:
            repo = REPOS.get(parts[1] + "/" + parts[2][:-4])
            if not repo or urllib.parse.parse_qs(url.query).get("service") != ["git-upload-pack"]:
                return self.send(401, b"Authentication required")
            return self.send(200, advertisement(repo["refs"]), "application/x-git-upload-pack-advertisement")
        if len(parts) >= 5 and parts[0] == "raw":
            ref, path = parts[3], "/".join(parts[4:])
            LOG.append(f"{parts[1]}/{parts[2]}@{ref}:{path}")
            repo = REPOS.get(parts[1] + "/" + parts[2])
            files = repo and repo["commits"].get(ref)   # commits only: a branch or tag name is never served
            if not files or path not in files:
                return self.send(404, b"404: Not Found")
            return self.send(200, files[path].encode())
        self.send(404, b"no such endpoint")

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/__move":
            q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
            REPOS[q["repo"]]["refs"][q["ref"]] = q["to"]
            if q["ref"] == "refs/heads/main":
                REPOS[q["repo"]]["refs"]["HEAD"] = q["to"]
            return self.send(200, b"moved")
        self.send(404)


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()
