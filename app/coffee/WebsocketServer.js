const base64id = require('base64id')
const bodyParser = require('body-parser')
const { EventEmitter } = require('events')
const metrics = require('metrics-sharelatex')
const redis = require('redis-sharelatex')
const Settings = require('settings-sharelatex')
const signature = require('cookie-signature')
const WebSocket = require('ws')

const sessionRedisClient = redis.createClient(Settings.redis.websessions)
const { bootstrapSecret, pollingAuthSecret } = Settings.security

const MISSING_BOOTSTRAP = new Error('missing bootstrap')
const RESTART_BOOTSTRAP = new Error('restart bootstrap')
const SESSION_LOOKUP_FAILED = new Error('could not look up session by key')
function getParams(req, callback) {
  const raw = req.url.slice(req.url.indexOf('bootstrap=') + 10)
  if (!raw) {
    metrics.inc('wss.bootstrap.failed', 1, { status: 'missing' })
    return callback(MISSING_BOOTSTRAP)
  }
  const bootstrap = signature.unsign(raw, bootstrapSecret)
  if (bootstrap === false) {
    metrics.inc('wss.bootstrap.failed', 1, { status: 'invalid' })
    return callback(RESTART_BOOTSTRAP)
  }
  const args = bootstrap.split(':')
  const version = args.shift()
  if (version !== 'v1') {
    metrics.inc('wss.bootstrap.failed', 1, { status: 'old-v' })
    return callback(RESTART_BOOTSTRAP)
  }
  const token = args.shift()
  sessionRedisClient.get(`token:${token}`, function(error, sid) {
    if (error) {
      metrics.inc('wss.bootstrap.failed', 1, { status: 'redis' })
      return callback(error)
    }
    if (!sid) {
      metrics.inc('wss.bootstrap.failed', 1, { status: 'expired' })
      return callback(RESTART_BOOTSTRAP)
    }
    sessionRedisClient.get(`sess:${sid}`, function(error, raw) {
      if (error) {
        metrics.inc('wss.bootstrap.failed', 1, { status: 'redis' })
        return callback(error)
      }
      if (!raw) {
        metrics.inc('wss.bootstrap.failed', 1, { status: 'logged-out' })
        return callback(SESSION_LOOKUP_FAILED)
      }
      metrics.inc('wss.bootstrap.success', 1)
      callback(null, JSON.parse(raw), ...args)
    })
  })
}
function sessionStart(req, client, callback) {
  getParams(req, function(error, ...args) {
    client.on('disconnect', () => clientMap.delete(client.id))
    clientMap.set(client.id, client)
    clientEmitter.emit('client', error, client, ...args)
    callback()
  })
}

const ACCESS_CONTROL_ALLOWED_ORIGINS = Settings.socketIoOrigins.split(',')
function addCORSHeaders(req, res, next) {
  if (ACCESS_CONTROL_ALLOWED_ORIGINS.includes(req.headers.origin)) {
    res.setHeader('Access-Control-Allow-Origin', req.headers.origin)
  }
  res.vary('Origin')
  next()
}

const clientMap = new Map()
const clientEmitter = new EventEmitter()
module.exports.clientMap = clientMap
module.exports.clientEmitter = clientEmitter
module.exports.attachRoutes = function(app) {
  app.get(`${Settings.socketIoPath}/socket.io.js`, function(req, res) {
    res.contentType('application/javascript')
    res.send('window.io="plain"')
  })

  const POLLING_PREFIX = `${Settings.socketIoPath}/deprecated-polling`
  app.use(`${POLLING_PREFIX}/`, addCORSHeaders)
  app.post(`${POLLING_PREFIX}/new`, function createNewSession(req, res) {
    const polling = new PollingWebSocketShim()
    const client = new Client(polling, clientMap)
    client.polling = polling
    const auth = signature.sign(client.id, pollingAuthSecret)
    sessionStart(req, client, () => res.json({ auth }))
  })

  app.options(`${POLLING_PREFIX}/`, function skipAuthForOPTIONS(req, res) {
    res.setHeader('Access-Control-Allow-Methods', 'DELETE,GET,POST')
    res.setHeader('Access-Control-Max-Age', 3600)
    res.sendStatus(204)
  })
  app.use(`${POLLING_PREFIX}/`, function authenticationCheck(req, res, next) {
    const raw = req.url.slice(req.url.indexOf('auth=') + 5)
    if (!raw) {
      metrics.inc('wss.polling-auth.failed', 1, { status: 'missing' })
      return res.sendStatus(401)
    }
    const clientId = signature.unsign(raw, pollingAuthSecret)
    if (clientId === false) {
      metrics.inc('wss.polling-auth.failed', 1, { status: 'invalid' })
      return res.sendStatus(403)
    }

    const client = clientMap.get(clientId)
    if (!client) {
      if (req.method === 'DELETE') {
        // it is OK for the clients to repeat the DELETE request
        // do not record this as a failure in the logs/metrics
        return res.sendStatus(204)
      }
      metrics.inc('wss.polling.client-missing')
      return res.sendStatus(404)
    }

    if (!client.polling) {
      // this should not happen, but let's keep it as a safe guard
      return res.status(400).json({ message: 'tried to switch transports' })
    }
    req.clientId = clientId
    next()
  })

  app.post(
    `${POLLING_PREFIX}/`,
    bodyParser.text({ type: '*/*', limit: 2 * Settings.maxUpdateSize })
  )
  app.use(`${POLLING_PREFIX}/`, function processRequest(req, res, next) {
    const client = clientMap.get(req.clientId)
    if (!client) {
      // POST requests are async and may allow the client to fade away as we
      //  process their payload. do not record this as an error in the logs.
      metrics.inc('wss.polling.client-missing', 1, { status: 'after-POST' })
      return res.sendStatus(204)
    }
    client.polling.processRequest(req, res, next)
  })
}

module.exports.attachServer = function(server) {
  const wss = new WebSocket.Server({
    server,
    clientTracking: false,
    handleProtocols() {
      return 'v3.real-time.overleaf.com'
    }
  })

  wss.on('connection', function(ws, req) {
    const client = new Client(ws, clientMap)
    new HealthCheckerForPlainWebSocket(ws, client).start()
    sessionStart(req, client, () => {})
  })

  return wss
}

class HealthCheckerForPlainWebSocket {
  constructor(ws, client) {
    this._ws = ws
    this._client = client

    client.on('disconnecting', this._cleanup.bind(this))

    // Per Websocket spec [1]: clients must respond to PING messages w/ PONG.
    // [1] rfc 6455: https://tools.ietf.org/html/rfc6455#section-5.5.2
    ws.on('pong', this._confirmHealthCheck.bind(this))

    // Browsers in 2020 do not expose the ping/pong API to JavaScript.
    // The frontend has to use a user-land 'ping' event instead.
    client.on('ping', this._onPing.bind(this))
  }

  start() {
    this._schedulePing()
  }

  _cleanup() {
    clearTimeout(this._healthCheckTimeout)
    clearTimeout(this._healthCheckEmitter)
  }

  _confirmHealthCheck() {
    this._cleanup()
    if (this._ws.readyState !== WebSocket.OPEN) return
    this._schedulePing()
  }

  _doPing() {
    this._ws.ping()
    this._healthCheckTimeout = setTimeout(
      this._onHealthCheckFailure.bind(this),
      Settings.wsHealthCheckTimeout
    )
  }

  _onHealthCheckFailure() {
    if (this._ws.readyState !== WebSocket.OPEN) {
      // ignore failures on a closing or already closed ws
      return
    }
    metrics.inc('wss.health-check.failed')
    const forceClose = setTimeout(() => this._ws.terminate(), 1000)
    this._client.on('disconnect', () => clearTimeout(forceClose))
    this._client.disconnect('server health check timeout')
  }

  _onPing(cb) {
    if (typeof cb === 'function') {
      // The first argument is effectively user controlled.
      // It and may not be callable and requires validation.
      cb()
    }
    this._confirmHealthCheck()
  }

  _schedulePing() {
    this._healthCheckEmitter = setTimeout(
      this._doPing.bind(this),
      Settings.wsHealthCheckInterval
    )
  }
}

class Client {
  constructor(ws) {
    this._events = new Map()
    this._internalEvents = new EventEmitter()
    this._ws = ws

    this.id = base64id.generateId()
    this.rooms = []

    this._internalEvents.on('closing', () => {
      this._internalEvents.emit('disconnecting')
      this._internalEvents.removeAllListeners('disconnecting')
    })
    ws.addEventListener('close', () => {
      this._internalEvents.emit('closing')
      this._internalEvents.emit('disconnect')
    })
    ws.addEventListener('error', errorEvent =>
      this._internalEvents.emit('error', errorEvent.error)
    )
    ws.addEventListener('message', messageEvent => {
      this._onMessage(messageEvent.data)
    })
  }

  get connected() {
    return this._ws.readyState === WebSocket.OPEN
  }

  disconnect(reason) {
    this._ws.close(4100, reason)
    this._internalEvents.emit('closing')
  }

  emit(event, ...args) {
    if (!this.connected) {
      // closing is a one-way op, drop packet early
      return
    }
    const payload = { event, args }
    this._ws.send(JSON.stringify(payload))
  }

  on(event, fn) {
    switch (event) {
      case 'disconnect':
      case 'disconnecting':
      case 'error':
        this._internalEvents.on(event, fn)
        break
      default:
        this._events.set(event, fn)
    }
  }

  _onMessage(blob) {
    let args, cbId, event
    try {
      ;({ event, args, cbId } = JSON.parse(blob))
    } catch (e) {
      metrics.inc('wss.invalid-payload', 1, { status: 'parse' })
      return
    }

    if (typeof event !== 'string' || !this._events.has(event)) {
      metrics.inc('wss.invalid-payload', 1, { status: 'unknown-event' })
      return
    }
    if (!(args instanceof Array)) {
      metrics.inc('wss.invalid-payload', 1, { status: 'invalid-args' })
      return
    }

    if (cbId !== undefined) {
      args.push((...args) => this._ws.send(JSON.stringify({ cbId, args })))
    }
    this._events.get(event).apply(null, args)
  }
}

function parseCodeAndReason(req) {
  const code = parseInt(req.query.code, 10) || 4099
  let { reason } = req.query
  if (typeof reason === 'string' && reason.length) {
    reason = reason.replace(/_/g, ' ')
  } else {
    reason = 'client requested disconnect with unknown reason'
  }
  return { code, reason }
}

class PollingWebSocketShim extends EventEmitter {
  constructor() {
    super()
    this._queue = []
    this.readyState = WebSocket.OPEN
  }

  addEventListener(event, fn) {
    if (event === 'error') {
      // there are no errors for long-polling
      return
    }
    this.on(event, fn)
  }

  close(code, reason) {
    if (this.readyState !== WebSocket.OPEN) {
      return
    }
    this.readyState = WebSocket.CLOSING
    this.send(JSON.stringify({ event: 'close', args: [code, reason] }))
  }

  processRequest(req, res, next) {
    switch (req.method) {
      case 'DELETE':
        this._onDELETE(req, res)
        break
      case 'GET':
        this._onGET(req, res)
        break
      case 'POST':
        this._onPOST(req, res)
        break
      default:
        next()
    }
  }

  send(blob) {
    this._queue.push(blob)
    setTimeout(() => {
      if (this._currentListener && this._queue.length) {
        this._flushCurrentListener()
      }
    })
  }

  terminate() {
    if (this.readyState === WebSocket.CLOSED) {
      return
    }
    this.readyState = WebSocket.CLOSED
    clearTimeout(this._cleanUpHandler)
    this._queue.length = 0
    if (this._currentListener) {
      // empty flush on terminate
      this._flushCurrentListener()
    }
    this.emit('close')
  }

  _flushCurrentListener() {
    const res = this._currentListener
    delete this._currentListener
    const data = Buffer.from('[' + this._queue.splice(0).join(',') + ']')
    res.writeHead(200, {
      'Cache-Control': 'no-store',
      'Content-Type': 'application/json',
      'Content-Length': data.length
    })
    res.end(data)

    if (this.readyState === WebSocket.CLOSING) {
      // the client picked up the closing event -- good bye
      this.terminate()
    } else {
      // implicit health check on frequent flush
      clearTimeout(this._cleanUpHandler)
      this._cleanUpHandler = setTimeout(
        this.terminate.bind(this),
        Settings.longPollingCleanupDelay
      )
    }
  }

  _onDELETE(req, res) {
    const { code, reason } = parseCodeAndReason(req)
    this.close(code, reason)
    this.terminate()
    res.sendStatus(204)
  }

  _onGET(req, res) {
    this._currentListener = res
    if (this._queue.length) {
      this._flushCurrentListener()
    } else {
      clearTimeout(this._cleanUpHandler)
      res.setTimeout(
        Settings.longPollingTimeout,
        this._flushCurrentListener.bind(this)
      )
    }
  }

  _onPOST(req, res) {
    if (this.readyState === WebSocket.OPEN) {
      this.emit('message', { data: req.body })
    }
    res.sendStatus(204)
  }
}
