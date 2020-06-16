const IS_NODE = typeof process !== 'undefined' && process.env
let CTX
if (IS_NODE) {
  CTX = process.env
} else {
  CTX = Object.assign(
    {
      DEBUG: true,
      IO_ENDPOINT: window.location.origin,
      IO_PATH: '/socket.io',
      CLIENT_NUM: 1000
    },
    JSON.parse(decodeURIComponent(window.location.hash.slice(1)) || '{}')
  )
}
const IO_ENDPOINT = CTX.IO_ENDPOINT
const IO_PATH = CTX.IO_PATH || '/socket.io'
const CLIENT_NUM = parseInt(CTX.CLIENT_NUM || '1', 10)
const BATCH_SIZE = parseInt(CTX.BATCH_SIZE || 200, 10) || 1
const BATCH_DELAY = parseInt(CTX.BATCH_DELAY || '10000', 10)
const COLOR = CTX.COLOR || 'blue'

const PARAMETER = {
  IO_ENDPOINT,
  IO_PATH,
  COLOR,
  CLIENT_NUM,
  BATCH_SIZE,
  BATCH_DELAY
}
CTX = Object.assign(CTX, PARAMETER)
console.error(PARAMETER)

let logger, io, exit
if (IS_NODE) {
  io = require('socket.io-client')
  exit = process.exit

  // allow self-signed SSL certificates
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = 0

  logger = require('logger-sharelatex')

  if (process.env.START_IO) {
    const SOCKET_IO_CLIENT_DEV = process.env.SOCKET_IO_CLIENT_DEV
    if (SOCKET_IO_CLIENT_DEV) {
      console.error('using dev client blob')
    }
    const server = require('http').createServer((req, res) => {
      if (req.url === '/index.html' || req.url === '/') {
        return res.end(`
<html>
    <head>
        <script src="${
          SOCKET_IO_CLIENT_DEV ? 'dev.js' : '/socket.io/socket.io.js'
        }"></script>
        <script src="load.js"></script>
    </head>
</html>
        `)
      }
      if (req.url === '/load.js') {
        return res.end(require('fs').readFileSync(__dirname + '/load.js'))
      }
      if (req.url === '/dev.js') {
        return res.end(require('fs').readFileSync(SOCKET_IO_CLIENT_DEV))
      }
      res.end()
    })
    const ioBackend = require('socket.io')(server, {
      path: IO_PATH,
      cookie: false,
      pingTimeout: 60 * 1000
    })
    ioBackend.on('connection', socket => {
      const { id, color } = socket.handshake.query
      let echos = 0
      socket.on('echo', (blob, cb) => {
        cb(blob)
        if (++echos === 3) {
          setTimeout(() => {
            disconnectedClean.set(id, true)
            socket.disconnect()
          }, 10000)
        }
      })
      socket.emit('broadcast', socket.id, id, color)
    })
    const IO_SERVER_PORT = parseInt(process.env.IO_SERVER_PORT || '8080', 10)
    server.listen(IO_SERVER_PORT, err => {
      if (err) {
        logger.error({ err }, 'server start failed')
        process.exit(85)
      } else {
        if (process.env.START_BENCH !== 'false') {
          ready()
        }
      }
    })
  } else {
    ready()
  }
} else {
  window.location.hash = JSON.stringify(CTX)

  io = window.io
  exit = alert

  const DEBUG = CTX.DEBUG

  function debugFn(...args) {
    if (DEBUG) {
      console.debug(JSON.stringify(args))
    }
  }

  function infoFn(...args) {
    if (DEBUG) {
      console.info(JSON.stringify(args))
    }
  }

  function warnFn(...args) {
    if (DEBUG) {
      console.warn(JSON.stringify(args))
    }
  }

  function errorFn(...args) {
    if (DEBUG) {
      console.error(JSON.stringify(args))
    }
  }

  logger = {
    debug: debugFn,
    info: infoFn,
    warn: warnFn,
    error: errorFn
  }

  setTimeout(ready)
}

const sids = new Map()
const responses = new Map()
const broadcast = new Map()
const finished = new Map()
const disconnectedClean = new Map()
let COUNTER = 0

function createClients() {
  let i = BATCH_SIZE
  while (COUNTER < CLIENT_NUM) {
    if (!i--) {
      return setTimeout(createClients, BATCH_DELAY)
    }
    const id = COUNTER++
    const socket = io.connect(
      IO_ENDPOINT,
      {
        path: IO_PATH,
        reconnection: false,
        query: { id, color: COLOR },
        transports: ['polling', 'websocket']
      }
    )
    const engine = socket.io.engine
    const transport = engine.transport
    transport.on('open', () => {
      logger.debug({ id, stage: 'transport', sid: transport.query.sid })
    })
    engine.on('open', () => {
      logger.debug({ id, stage: 'engine', sid: transport.query.sid })
    })
    socket.on('connect', () => {
      logger.debug({ id, stage: 'socket', sid: transport.query.sid })
    })
    socket.on('broadcast', () => {
      logger.debug({ id, stage: 'app', sid: transport.query.sid })
    })
    socket.on('disconnect', disconnectReason => {
      logger.debug({ id, disconnectReason, sid: transport.query.sid })
    })
    Object.entries({
      transport,
      engine,
      socket
    }).forEach(([label, emitter]) => {
      emitter.on('error', err => {
        logger.warn({ id, label, err }, 'error')
      })
    })

    const blobs = []
    responses.set(id, blobs)
    socket.on('connect', () => {
      sids.set(id, socket.id)
      socket.emit('echo', [id, COLOR], blob1 => {
        blobs.push(blob1)
        socket.emit('echo', [id, COLOR], blob2 => {
          blobs.push(blob2)
          socket.emit('echo', [id, COLOR], blob3 => {
            blobs.push(blob3)
          })
        })
      })
    })
    socket.on('broadcast', (...blob) => {
      broadcast.set(id, blob)
    })
    socket.on('disconnect', reason => {
      finished.set(id, reason)
    })
  }
}

function waitForFinished(done) {
  const checker = setInterval(function() {
    if (finished.size === CLIENT_NUM) {
      clearInterval(checker)
      done()
    }
  }, 10)
}

function checkState(done) {
  let ok = true
  finished.forEach((reason, id) => {
    const sid = sids.get(id)
    const cleanDisconnect = disconnectedClean.get(id) || false
    const ctx = { id, sid, cleanDisconnect, reason }
    if (typeof sid !== 'string' || sid.length !== 20) {
      logger.error(ctx, 'id missing')
      ok = false
    }
    const echoResponses = responses.get(id)
    if (
      !echoResponses ||
      echoResponses.flat().join() !==
        [[id, COLOR], [id, COLOR], [id, COLOR]].flat().join()
    ) {
      ctx.echoResponses = echoResponses
      logger.error(ctx, 'echo mismatch')
      ok = false
    }
    const broadcastMessage = broadcast.get(id)
    if (
      !broadcastMessage ||
      broadcastMessage.join() !== [sid, id, COLOR].join()
    ) {
      ctx.broadcastMessage = broadcastMessage
      logger.error(ctx, 'broadcast mismatch')
      ok = false
    }
  })
  done(ok)
}

function ready() {
  createClients()
  waitForFinished(() => {
    checkState(ok => {
      console.error({ ok })
      exit(ok ? 0 : 99)
    })
  })
}
