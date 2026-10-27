#!/usr/bin/env python3
"""Does this provider actually serve catch-up? Ask it, rather than trusting the flag.

    IPTV_SERVER=http://host:port IPTV_USER=... IPTV_PASS=... \
        python3 Tools/timeshift-probe.py [path/to/guide.xml]

Why this exists: `tv_archive` in the channel list can be wrong in both directions. Some
panels carry catch-up without advertising it, and some advertise it and return 404. This
tests the URL shapes panels use, against a channel the guide says has a finished
programme, with live playback as the control — if live is a 404 too, the base or the
channel is wrong, not catch-up.

Prints status codes only. The username and password are stripped from anything printed.
"""
import json, os, re, sys, time, urllib.parse, urllib.request

server = os.environ.get("IPTV_SERVER", "").rstrip("/")
user = os.environ.get("IPTV_USER", "")
password = os.environ.get("IPTV_PASS", "")
if not (server and user and password):
    sys.exit("set IPTV_SERVER, IPTV_USER and IPTV_PASS in the environment")


def redact(text):
    return text.replace(user, "USER").replace(password, "PASS")


def api(action):
    url = (f"{server}/player_api.php?username={urllib.parse.quote(user)}"
           f"&password={urllib.parse.quote(password)}&action={action}")
    request = urllib.request.Request(url, headers={"User-Agent": "IPTVMac/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def as_int(value, default=0):
    """The panel returns numbers as strings as often as not."""
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def status(url, want_playlist=False):
    request = urllib.request.Request(url, headers={"User-Agent": "IPTVMac/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read(160)
            playlist = body.lstrip().startswith(b"#EXTM3U")
            return f"HTTP {response.status}" + (" playlist" if playlist else "")
    except Exception as error:
        return str(error)[:70]


streams = api("get_live_streams")
archive = [s for s in streams if as_int(s.get("tv_archive")) == 1]
print(f"live streams: {len(streams)}")
print(f"advertising an archive: {len(archive)} "
      f"(with a duration: {sum(1 for s in archive if as_int(s.get('tv_archive_duration')) > 0)})")

guide = sys.argv[1] if len(sys.argv) > 1 else None
if not guide:
    print("\nNo guide path given; passing one lets the probe pick a channel with a "
          "finished programme to test against.")
    sys.exit(0)

with_epg = {s.get("epg_channel_id"): s for s in streams if s.get("epg_channel_id")}
now = time.time()
fmt = "%Y%m%d%H%M%S"
finished = {}
tag_pattern = re.compile(rb"<programme\s[^>]*>")
with open(guide, "rb") as handle:
    while True:
        chunk = handle.read(1 << 23)
        if not chunk:
            break
        # Attribute order varies between exporters, so read each attribute on its own.
        for tag in tag_pattern.findall(chunk):
            def attribute(name):
                found = re.search(rb'%s="([^"]*)"' % name, tag)
                return found.group(1).decode() if found else ""
            start, stop, channel = attribute(b"start"), attribute(b"stop"), attribute(b"channel")
            if channel not in with_epg or len(start) < 14:
                continue
            try:
                s = time.mktime(time.strptime(start[:14], fmt)) - time.timezone
                e = time.mktime(time.strptime(stop[:14], fmt)) - time.timezone
            except ValueError:
                continue
            if e < now and s > finished.get(channel, (0, 0))[0]:
                finished[channel] = (s, e)
        if len(finished) >= 3:
            break

print(f"channels with a finished programme in the guide: {len(finished)}\n")
for channel, (start, stop) in list(finished.items())[:3]:
    stream = with_epg[channel]
    sid = stream["stream_id"]
    duration = max(1, int((stop - start) // 60))
    utc = time.strftime("%Y-%m-%d:%H-%M", time.gmtime(start))
    local = time.strftime("%Y-%m-%d:%H-%M", time.localtime(start))
    print(f"channel {channel} (stream {sid}), programme "
          f"{time.strftime('%H:%M', time.localtime(start))}-{time.strftime('%H:%M', time.localtime(stop))}")
    for label, url in {
        "timeshift .m3u8 (UTC)": f"{server}/timeshift/{user}/{password}/{duration}/{utc}/{sid}.m3u8",
        "timeshift .m3u8 (local)": f"{server}/timeshift/{user}/{password}/{duration}/{local}/{sid}.m3u8",
        "timeshift .ts": f"{server}/timeshift/{user}/{password}/{duration}/{utc}/{sid}.ts",
        "timeshift.php": (f"{server}/streaming/timeshift.php?username={urllib.parse.quote(user)}"
                          f"&password={urllib.parse.quote(password)}&stream={sid}"
                          f"&start={local}&duration={duration}"),
        "live (control)": f"{server}/live/{user}/{password}/{sid}.m3u8",
    }.items():
        print(f"   {label:24} {redact(status(url))}")
    print()
