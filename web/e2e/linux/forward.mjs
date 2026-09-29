// Forwards localhost:<port> inside the container to host.docker.internal:<port>.
import net from 'node:net'

for (const port of process.argv.slice(2).map(Number)) {
  net.createServer((client) => {
    const upstream = net.connect(port, 'host.docker.internal')
    client.pipe(upstream).pipe(client)
    const close = () => { client.destroy(); upstream.destroy() }
    client.on('error', close)
    upstream.on('error', close)
  }).listen(port, '127.0.0.1', () => console.log(`forwarding localhost:${port} → host`))
}
