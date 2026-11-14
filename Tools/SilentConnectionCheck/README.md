# Silent connection check

A request that times out can leave its connection in the session's pool, open
but silent. Over HTTP/2 the next request on that session goes out on the same
connection, so retries on the session time out the same way without reaching
the server. `UmbelHTTPSource` therefore moves later requests to a fresh
session after a timeout. This check shows both: what the system does, and that
the source reads on.

Run it from anywhere on a Mac with Xcode, Node.js and `openssl`:

```bash
Tools/SilentConnectionCheck/run.sh        # request timeout 2 s
Tools/SilentConnectionCheck/run.sh 6      # or another, in seconds
```

`relay.js` serves 64 MiB of byte ranges over HTTP/2 with a self-signed
certificate, behind a relay that goes silent on its first connection: past the
first 4 MiB it forwards nothing either way and keeps both sockets open. Later
connections are relayed in full. Each scenario gets a relay of its own.

The scenarios, all run by `run.sh` through the `umbel-silent-connection-check`
executable of the package:

- **URLSession alone** reads until the request times out, retries three times
  on the same session, then once on a fresh session, and says for each request
  whether it rode a connection already open. "reproduced" means the retries
  rode the silent connection and timed out while the fresh session read on —
  the behaviour the source works around. If a later system stops doing this,
  the scenario says "not reproduced"; that is news, not a failure.
- **UmbelHTTPSource with a session maker** reads 8 MiB, past the silence. It
  should read on after one timeout and one session renewal, every byte as
  served. This scenario decides the exit status.
- **UmbelHTTPSource without one** reads the same. The session trusts the
  relay's certificate through its delegate, which a session made by the
  source would not carry over, so without a maker the session is kept and the
  read fails once its retries run out — as plain URLSession does.

After each scenario the script counts, from the relay's log, the connections
made and the requests that reached the server: without renewal the retries
never arrive.

Exit status: 0 when the source with a maker reads on, 1 when it does not, 2
when the check cannot run. The certificate, the relay logs and the build log
are kept in `tmp/silent-connection-check/`.

The check needs Node.js and real network sockets, so CI builds the executable
but does not run it.
