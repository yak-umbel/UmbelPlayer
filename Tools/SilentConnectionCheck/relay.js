// An HTTP/2 server answering byte ranges, behind a relay that goes silent on
// its first connection: past the first 4 MiB towards the client it forwards
// nothing either way, and keeps both sockets open. Later connections are
// relayed in full. Node.js standard library only.
//
//   node relay.js <work directory>
//
// Reads key.pem and cert.pem from the work directory, writes the relay's
// port to "port" there, and logs one JSON line per event to stdout.
const http2 = require('http2');
const net = require('net');
const fs = require('fs');
const path = require('path');

const work = process.argv[2];
const LENGTH = 64 << 20;
const SILENT_AFTER = 4 << 20;
// The same bytes the check expects at each offset.
const byteAt = (i) => (i * 37 + 11) % 251;
const log = (event) => console.log(JSON.stringify({ t: Date.now(), ...event }));

let sessions = 0;
const server = http2.createSecureServer({
  key: fs.readFileSync(path.join(work, 'key.pem')),
  cert: fs.readFileSync(path.join(work, 'cert.pem')),
});
server.on('session', (session) => {
  session.checkID = ++sessions;
  log({ event: 'session', session: session.checkID });
});
server.on('stream', (stream, headers) => {
  const match = /^bytes=(\d+)-(\d*)$/.exec(headers['range'] || 'bytes=0-');
  if (!match) { stream.respond({ ':status': 416 }); stream.end(); return; }
  const start = parseInt(match[1], 10);
  const end = match[2] ? Math.min(parseInt(match[2], 10), LENGTH - 1) : LENGTH - 1;
  log({ event: 'request', session: stream.session.checkID, range: headers['range'] });
  stream.respond({
    ':status': 206, 'content-range': `bytes ${start}-${end}/${LENGTH}`,
    'content-length': String(end - start + 1), 'accept-ranges': 'bytes',
  });
  let position = start;
  const pump = () => {
    while (position <= end) {
      const count = Math.min(65536, end - position + 1);
      const chunk = Buffer.allocUnsafe(count);
      for (let k = 0; k < count; k++) chunk[k] = byteAt(position + k);
      position += count;
      if (!stream.write(chunk)) { stream.once('drain', pump); return; }
    }
    stream.end();
  };
  stream.on('error', () => {});
  pump();
});
server.on('sessionError', () => {});

server.listen(0, '127.0.0.1', () => {
  let connections = 0;
  const relay = net.createServer((client) => {
    const id = ++connections;
    const upstream = net.connect(server.address().port, '127.0.0.1');
    let forwarded = 0;
    let silent = false;
    log({ event: 'connection', connection: id });
    client.on('data', (data) => {
      if (silent) { log({ event: 'swallowed', connection: id, bytes: data.length }); return; }
      upstream.write(data);
    });
    upstream.on('data', (data) => {
      if (silent) return;
      if (id === 1 && forwarded + data.length > SILENT_AFTER) {
        silent = true;
        log({ event: 'silent', connection: id, forwarded });
        return;
      }
      forwarded += data.length;
      client.write(data);
    });
    const close = () => { client.destroy(); upstream.destroy(); };
    client.on('close', close);
    upstream.on('close', close);
    client.on('error', () => {});
    upstream.on('error', () => {});
  });
  relay.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(path.join(work, 'port'), String(relay.address().port));
    log({ event: 'ready', port: relay.address().port });
  });
});
