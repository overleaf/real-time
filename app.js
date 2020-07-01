const Metrics = require('metrics-sharelatex')
const Settings = require('settings-sharelatex')
Metrics.initialize(Settings.appName || 'real-time')
const async = require('async')

const logger = require('logger-sharelatex')
logger.initialize('real-time')
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

const DrainManager = require('./app/js/DrainManager')
const HealthCheckManager = require('./app/js/HealthCheckManager')

// work around frame handler bug in socket.io v0.9.16
require('./socket.io.patch.js')
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

app.get('/', (req, res) => res.send('real-time-sharelatex is alive'))

app.get('/status', function (req, res) {
  if (Settings.shutDownInProgress) {
    res.send(503) // Service unavailable
  } else {
    res.send('real-time-sharelatex is alive')
  }
})

app.get('/debug/events', function (req, res) {
  Settings.debugEvents = parseInt(req.query.count, 10) || 20
  logger.log({ count: Settings.debugEvents }, 'starting debug mode')
  res.send(`debug mode will log next ${Settings.debugEvents} events`)
})

const rclient = require('redis-sharelatex').createClient(
  Settings.redis.realtime
)

function healthCheck(req, res) {
  rclient.healthCheck(function (error) {
    if (error) {
      logger.err({ err: error }, 'failed redis health check')
      res.sendStatus(500)
    } else if (HealthCheckManager.isFailing()) {
      const status = HealthCheckManager.status()
      logger.err({ pubSubErrors: status }, 'failed pubsub health check')
      res.sendStatus(500)
    } else {
      res.sendStatus(200)
    }
  })
}
app.get('/health_check', healthCheck)

app.get('/health_check/redis', healthCheck)

const Router = require('./app/js/Router')
Router.configure(app, io, sessionSockets)

const WebsocketLoadBalancer = require('./app/js/WebsocketLoadBalancer')
WebsocketLoadBalancer.listenForEditorEvents(io)

const DocumentUpdaterController = require('./app/js/DocumentUpdaterController')
DocumentUpdaterController.listenForUpdatesFromDocumentUpdater(io)

const { port } = Settings.internal.realTime
const { host } = Settings.internal.realTime

server.listen(port, host, function (error) {
  if (error) {
    throw error
  }
  logger.info(`realtime starting up, listening on ${host}:${port}`)
})

// Stop huge stack traces in logs from all the socket.io parsing steps.
Error.stackTraceLimit = 10

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
      DrainManager.startDrainTimeWindow(io, shutdownDrainTimeWindow)
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

if (Settings.continualPubsubTraffic) {
  logger.warn('continualPubsubTraffic enabled')

  const pubsubClient = redis.createClient(Settings.redis.pubsub)
  const clusterClient = redis.createClient(Settings.redis.websessions)

  const publishJob = function (channel, callback) {
    const checker = new HealthCheckManager(channel)
    logger.debug({ channel }, 'sending pub to keep connection alive')
    const json = JSON.stringify({
      health_check: true,
      key: checker.id,
      date: new Date().toString()
    })
    Metrics.summary(`redis.publish.${channel}`, json.length)
    pubsubClient.publish(channel, json, function (err) {
      if (err) {
        logger.err({ err, channel }, 'error publishing pubsub traffic to redis')
      }
      const blob = JSON.stringify({ keep: 'alive' })
      Metrics.summary('redis.publish.cluster-continual-traffic', blob.length)
      clusterClient.publish('cluster-continual-traffic', blob, callback)
    })
  }

  const runPubSubTraffic = () =>
    async.map(['applied-ops', 'editor-events'], publishJob, () =>
      setTimeout(runPubSubTraffic, 1000 * 20)
    )

  runPubSubTraffic()
}
