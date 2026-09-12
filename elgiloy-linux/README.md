# elgiloy-linux

in progress.

the macOS daemon (see [../elgiloy-mac-arm](../elgiloy-mac-arm)) is built on
apple-only machinery: CGEventTap for key interception, apple events for
tab queries, NSPanel for the overlay. none of that exists on linux — this
will be a separate program sharing only the design (mirror chrome's
switching, never commit, overlay is a view), not a port of the code.

candidates when this happens: X11 global hotkeys + EWMH `_NET_ACTIVE_WINDOW`
desktops, or a wayland compositor protocol layer.
