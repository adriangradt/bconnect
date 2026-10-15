// Generates the packets a Bedrock client needs to "spawn" before it accepts
// a Transfer, for each protocol version, using the PrismarineJS
// bedrock-protocol serializers. Fields not set below get neutral defaults
// derived from the protocol schema.
// Usage: node gen_templates.js <out.json.gz> [version ...]
// Without versions, every version bedrock-protocol knows from 1.19.30 on.
// The output is gzipped JSON: { "<protocol>": { version, resource_packs_info,
// resource_pack_stack, play_status_spawn, spawn: [hex, ...] } }.
const fs = require('fs')
const mcData = require('minecraft-data')
const { createSerializer } = require('bedrock-protocol/src/transforms/serializer')

const ZERO_UUID = '00000000-0000-0000-0000-000000000000'

function makeDefault (types, type, path = []) {
  if (path.length > 40) throw new Error('too deep: ' + path.join('.'))
  if (typeof type === 'string') {
    switch (type) {
      case 'bool': return false
      case 'i8': case 'u8': case 'i16': case 'u16': case 'li16': case 'lu16': case 'i32': case 'u32':
      case 'li32': case 'lu32': case 'varint': case 'zigzag32': case 'f32': case 'lf32': case 'f64': case 'lf64':
      case 'varint32':
        return 0
      case 'i64': case 'u64': case 'li64': case 'lu64': case 'varint64': case 'zigzag64':
        return 0n
      case 'string': case 'pstring': case 'cstring': case 'LittleString': case 'ShortString': case 'LatinString':
        return ''
      case 'uuid': return ZERO_UUID
      case 'void': return undefined
      case 'restBuffer': case 'ByteArray': case 'buffer': return Buffer.alloc(0)
      case 'nbt': case 'lnbt': case 'nbtLoop':
        return { type: 'compound', name: '', value: {} }
    }
    if (types[type] === undefined) throw new Error('unknown type ' + type + ' at ' + path.join('.'))
    if (types[type] === 'native') throw new Error('native type without default: ' + type + ' at ' + path.join('.'))
    return makeDefault(types, types[type], path.concat(type))
  }
  const [kind, opts] = type
  switch (kind) {
    case 'container': {
      const o = {}
      for (const f of opts) {
        const v = makeDefault(types, f.type, path.concat(f.name || '(anon)'))
        if (f.anon && v && typeof v === 'object') Object.assign(o, v)
        else if (f.name) o[f.name] = v
      }
      return o
    }
    case 'array': return []
    case 'option': return undefined
    case 'mapper': return Object.values(opts.mappings)[0]
    case 'bitflags': return {}
    case 'bitfield': { const o = {}; for (const f of opts) o[f.name] = 0; return o }
    case 'switch': {
      const fields = opts.fields || {}
      const pick = fields['0'] ?? fields.false ?? fields.default ?? opts.default ?? 'void'
      return makeDefault(types, pick, path.concat('switch'))
    }
    case 'buffer': return Buffer.alloc(0)
    case 'pstring': return ''
    case 'encapsulated': return makeDefault(types, opts.type, path)
    case 'enum_size_based_on_values_len': return Object.values(opts.values || {})[0]
    default:
      if (types[kind] !== undefined && types[kind] !== 'native') return makeDefault(types, types[kind], path)
      throw new Error('unsupported type ' + kind + ' at ' + path.join('.'))
  }
}

function packetsFor (version) {
  const data = mcData('bedrock_' + version)
  const types = data.protocol.types
  const ser = createSerializer(version)
  const def = (name) => makeDefault(types, 'packet_' + name, [name])
  const enc = (name, params) => ser.createPacketBuffer({ name, params }).toString('hex')
  const out = {}

  out.resource_packs_info = enc('resource_packs_info', def('resource_packs_info'))

  const stack = def('resource_pack_stack')
  stack.game_version = '*'
  out.resource_pack_stack = enc('resource_pack_stack', stack)

  const sg = def('start_game')
  Object.assign(sg, {
    entity_id: 1n,
    runtime_entity_id: 1n,
    player_gamemode: 'survival',
    player_position: { x: 0, y: 100, z: 0 },
    seed: 0n,
    dimension: 'overworld',
    generator: 1,
    world_gamemode: 'survival',
    difficulty: 1,
    spawn_position: { x: 0, y: 100, z: 0 },
    permission_level: 'member',
    level_id: 'bedrockbridge',
    world_name: 'BedrockBridge',
    premium_world_template_id: ZERO_UUID,
    game_version: '*',
    engine: 'BedrockBridge',
    world_template_id: ZERO_UUID,
    chunk_radius: 1,
    is_multiplayer: true,
    broadcast_to_lan: true,
    server_authoritative_inventory: true,
    server_authoritative_block_breaking: true,
    rewind_history_size: 0
  })
  if ('server_controlled_sound' in sg) sg.server_controlled_sound = false
  out.start_game = enc('start_game', sg)

  out.play_status_spawn = enc('play_status', { status: 'player_spawn' })

  // Everything the client needs to be "in a world", in the order
  // BedrockConnect sends it: structure data, shapes, StartGame, item and
  // creative registries, 6x6 empty chunks, spawn status, movement speed.
  const has = (name) => types['packet_' + name] !== undefined
  const emptyList = { type: 'list', value: { type: 'end', value: [] } }
  const spawn = []
  if (has('jigsaw_structure_data')) {
    spawn.push(enc('jigsaw_structure_data', {
      structure_data: {
        type: 'compound',
        name: '',
        value: { processors: emptyList, template_pools: emptyList, jigsaws: emptyList, structure_sets: emptyList }
      }
    }))
  }
  if (has('voxel_shapes')) spawn.push(enc('voxel_shapes', def('voxel_shapes')))
  spawn.push(out.start_game)
  if (has('item_registry')) spawn.push(enc('item_registry', def('item_registry')))
  else if (has('item_component')) spawn.push(enc('item_component', def('item_component')))
  if (has('creative_content')) spawn.push(enc('creative_content', def('creative_content')))
  // 256 bytes biomes + border + extra data, then an empty network NBT compound.
  const chunkPayload = Buffer.concat([Buffer.alloc(258), Buffer.from([0x0a, 0x00, 0x00])])
  for (let x = -3; x < 3; x++) {
    for (let z = -3; z < 3; z++) {
      const c = def('level_chunk')
      Object.assign(c, { x, z, dimension: 0, sub_chunk_count: 0, cache_enabled: false, blobs: [], payload: chunkPayload })
      spawn.push(enc('level_chunk', c))
    }
  }
  spawn.push(out.play_status_spawn)
  const attrs = def('update_attributes')
  attrs.runtime_entity_id = 1n
  attrs.attributes = [{
    min: 0, max: 1024, current: 0.1, default_min: 0, default_max: 1024, default: 0.1, name: 'minecraft:movement', modifiers: []
  }]
  spawn.push(enc('update_attributes', attrs))
  out.spawn = spawn
  // StartGame is part of the spawn sequence; no need to ship it twice.
  delete out.start_game
  return out
}

const zlib = require('zlib')
const { Versions } = require('bedrock-protocol/src/options')
let [outFile, ...versions] = process.argv.slice(2)
if (versions.length === 0) versions = Object.keys(Versions).filter((v) => Versions[v] >= 554)
const result = {}
for (const v of versions) {
  try {
    const proto = mcData('bedrock_' + v).version.version
    result[proto] = { version: v, ...packetsFor(v) }
    console.error('ok', v, proto)
  } catch (e) {
    console.error('FAIL', v, e.message)
  }
}
const json = JSON.stringify(result)
fs.writeFileSync(outFile, outFile.endsWith('.gz') ? zlib.gzipSync(json, { level: 9 }) : json)
console.error('wrote', outFile, Object.keys(result).length, 'protocols')
