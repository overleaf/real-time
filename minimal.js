const Metrics = require('metrics-sharelatex')
const Settings = require('settings-sharelatex')
Metrics.initialize('real-time-minimal')

const logger = require('logger-sharelatex')
logger.initialize('real-time-minimal')
Metrics.event_loop.monitor(logger)

const express = require('express')
const session = require('express-session')
const redis = require('redis-sharelatex')
if (Settings.sentry && Settings.sentry.dsn) {
  logger.initializeErrorReporting(Settings.sentry.dsn)
}

const sessionRedisClient = redis.createClient(Settings.redis.websessions)

const RedisStore = require('connect-redis')(session)
const SessionSockets = require('./app/js/SessionSockets')
const CookieParser = require('cookie-parser')

// Set up socket.io server
const app = express()

const server = require('http').createServer(app)
const io = require('socket.io').listen(server)

// Bind to sessions
const sessionStore = new RedisStore({ client: sessionRedisClient })
const cookieParser = CookieParser(Settings.security.sessionSecret)

const sessionSockets = new SessionSockets(
  io,
  sessionStore,
  cookieParser,
  Settings.cookieName
)

Metrics.injectMetricsRoute(app)
app.use(Metrics.http.monitor(logger))

io.configure(function () {
  io.enable('browser client minification')
  io.enable('browser client etag')

  // Fix for Safari 5 error of "Error during WebSocket handshake: location mismatch"
  // See http://answers.dotcloud.com/question/578/problem-with-websocket-over-ssl-in-safari-with
  io.set('match origin protocol', true)

  // gzip uses a Node 0.8.x method of calling the gzip program which
  // doesn't work with 0.6.x
  // io.enable('browser client gzip')
  io.set('transports', [
    'websocket',
    'flashsocket',
    'htmlfile',
    'xhr-polling',
    'jsonp-polling'
  ])
  io.set('log level', 1)
})

Settings.minimalRealTimeTimeout =
  Settings.minimalRealTimeTimeout ||
  parseInt(process.env.MINIMAL_REAL_TIME_TIMEOUT, 10) ||
  30000

sessionSockets.on('connection', function (error, client) {
  if (error && error.message.match(/could not look up session by key/)) {
    Metrics.inc('real-time-minimal.error', 1, { status: 'session' })
    client.emit('connectionRejected', { message: 'invalid session' })
    client.disconnect()
    return
  }
  if (Settings.shutDownInProgress) {
    client.emit('connectionRejected', { message: 'retry' })
    client.disconnect()
    return
  }
  const testDeadline = setTimeout(() => {
    Metrics.inc('real-time-minimal.error', 1, { status: 'timeout' })
    client.disconnect()
  }, Settings.minimalRealTimeTimeout)

  client.on('error', function (err) {
    logger.warn({ err }, 'client error')
    Metrics.inc('real-time-minimal.error', 1, { status: 'generic' })
  })
  client.emit('connectionAccepted')

  Metrics.inc('real-time-minimal.connection')
  Metrics.gauge('real-time-minimal.clients', io.sockets.clients().length)
  client.on('disconnect', function () {
    clearTimeout(testDeadline)
    Metrics.inc('real-time-minimal.disconnect')
    Metrics.gauge('real-time-minimal.clients', io.sockets.clients().length)
  })

  client.on('clientTracking.getConnectedUsers', (cb) => {
    if (typeof cb !== 'function') {
      client.disconnect()
      return
    }
    Metrics.inc('real-time-minimal.rpc')
    cb(null, [])
  })
})

app.get('/', (req, res) => res.send('real-time-minimal is alive'))

app.get('/status', function (req, res) {
  if (Settings.shutDownInProgress) {
    res.send(503) // Service unavailable
  } else {
    res.send('real-time-minimal is alive')
  }
})

const rclient = require('redis-sharelatex').createClient(
  Settings.redis.realtime
)

function healthCheck(req, res) {
  rclient.healthCheck(function (error) {
    if (error) {
      logger.err({ err: error }, 'failed redis health check')
      res.sendStatus(500)
    } else {
      res.sendStatus(200)
    }
  })
}
app.get('/health_check', healthCheck)

app.get('/health_check/redis', healthCheck)

const FAVICON_DATA = require('fs').readFileSync('./favicon.ico')
app.get('/favicon.ico', function (req, res) {
  res.setHeader('Content-Type', 'image/x-icon')
  res.send(FAVICON_DATA)
})

Settings.minimalRealTimePort =
  Settings.minimalRealTimePort ||
  parseInt(process.env.MINIMAL_REAL_TIME_PORT) ||
  9311
server.listen(Settings.minimalRealTimePort, function (error) {
  if (error) {
    throw error
  }
  logger.info(`real-time-minimal starting up, listening on ${server.address()}`)
})

function shutdownCleanly(signal) {
  const connectedClients = io.sockets.clients().length
  if (connectedClients === 0) {
    logger.warn('no clients connected, exiting')
    process.exit()
  } else {
    logger.warn(
      { connectedClients },
      'clients still connected, not shutting down yet'
    )
    setTimeout(() => shutdownCleanly(signal), 30 * 1000)
  }
}

function drainAndShutdown(signal) {
  if (Settings.shutDownInProgress) {
    logger.warn({ signal }, 'shutdown already in progress, ignoring signal')
  } else {
    Settings.shutDownInProgress = true
    const { statusCheckInterval } = Settings
    if (statusCheckInterval) {
      logger.warn(
        { signal },
        `received interrupt, delay drain by ${statusCheckInterval}ms`
      )
    }
    setTimeout(function () {
      logger.warn(
        { signal },
        `received interrupt, starting drain over ${shutdownDrainTimeWindow} mins`
      )
      io.sockets.clients().forEach((client) => {
        client.emit('reconnectGracefully')
      })
      shutdownCleanly(signal)
    }, statusCheckInterval)
  }
}

Settings.shutDownInProgress = false
const shutdownDrainTimeWindow = parseInt(Settings.shutdownDrainTimeWindow, 10)
if (Settings.shutdownDrainTimeWindow) {
  logger.log({ shutdownDrainTimeWindow }, 'shutdownDrainTimeWindow enabled')
  for (const signal of [
    'SIGINT',
    'SIGHUP',
    'SIGQUIT',
    'SIGUSR1',
    'SIGUSR2',
    'SIGTERM',
    'SIGABRT'
  ]) {
    process.on(signal, drainAndShutdown)
  } // signal is passed as argument to event handler

  // global exception handler
  if (Settings.errors && Settings.errors.catchUncaughtErrors) {
    process.removeAllListeners('uncaughtException')
    process.on('uncaughtException', function (error) {
      if (['EPIPE', 'ECONNRESET'].includes(error.code)) {
        Metrics.inc('disconnected_write', 1, { status: error.code })
        return logger.warn(
          { err: error },
          'attempted to write to disconnected client'
        )
      }
      logger.error({ err: error }, 'uncaught exception')
      if (Settings.errors && Settings.errors.shutdownOnUncaughtError) {
        drainAndShutdown('SIGABRT')
      }
    })
  }
}
