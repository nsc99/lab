#!/bin/bash
# Binds qBittorrent to gluetun's WireGuard interface, so torrent traffic can
# only leave through the tunnel even if gluetun's firewall is open: gluetun
# resets it to ACCEPT when enabling it fails, and qBittorrent keeps running
# while gluetun restarts. Without tun0 qBittorrent stays offline (it passes the
# name on to libtorrent instead of falling back to all interfaces).
# Runs as root from linuxserver's /custom-cont-init.d before qBittorrent starts.
set -euo pipefail

python3 - /config/qBittorrent/qBittorrent.conf <<'PY'
import configparser, sys

conf = sys.argv[1]
cp = configparser.RawConfigParser(delimiters=("=",), strict=False)
cp.optionxform = str
cp.read(conf)
if not cp.has_section("BitTorrent"):
    cp.add_section("BitTorrent")
session = cp["BitTorrent"]

# An interface address would bind to that IP instead of the device.
want = {"Session\\Interface": "tun0", "Session\\InterfaceName": "tun0"}
if all(session.get(k) == v for k, v in want.items()) and "Session\\InterfaceAddress" not in session:
    sys.exit(0)

session.update(want)
session.pop("Session\\InterfaceAddress", None)
with open(conf, "w") as f:
    cp.write(f, space_around_delimiters=False)
print("qbittorrent-interface: bound to tun0")
PY
