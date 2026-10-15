// Interop check: a real Bedrock client implementation (PrismarineJS
// bedrock-protocol) joins the bridge and must receive a Transfer packet.
// Usage: node transfer_client.js <host> <port> <minecraft version>
// Needs bedrock-protocol on NODE_PATH (see BUILD.md).
const bedrock = require('bedrock-protocol')

const [host, port, version] = process.argv.slice(2)
const out = (o) => console.log(JSON.stringify(o))
const timer = setTimeout(() => { out({ error: 'timeout' }); process.exit(2) }, 15000)

const client = bedrock.createClient({
  host,
  port: Number(port),
  version,
  offline: true,
  username: 'BridgeTest',
  skipPing: true,
  raknetBackend: 'jsp-raknet'
})

client.on('network_settings', (p) => out({ network_settings: p }))
client.on('play_status', (p) => out({ play_status: p.status }))
client.on('transfer', (p) => {
  out({ transfer: p })
  clearTimeout(timer)
  client.close()
  setTimeout(() => process.exit(0), 100)
})
client.on('kick', (p) => { out({ kick: p }); process.exit(3) })
client.on('error', (e) => { out({ error: String(e && e.stack || e) }); process.exit(4) })
