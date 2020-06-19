Metrics = require("metrics-sharelatex")
Settings = require "settings-sharelatex"
Metrics.initialize(Settings.appName or "real-time")
async = require("async")

logger = require "logger-sharelatex"
logger.initialize("real-time")
Metrics.event_loop.monitor(logger)

express = require("express")
redis = require("redis-sharelatex")
if Settings.sentry?.dsn?
	logger.initializeErrorReporting(Settings.sentry.dsn)

DrainManager = require("./app/js/DrainManager")
HealthCheckManager = require("./app/js/HealthCheckManager")
WebsocketServer = require("./app/js/WebsocketServer")
{clientMap} = WebsocketServer

# Set up socket.io server
app = express()

server = require('http').createServer(app)
WebsocketServer.attachRoutes(app)
WebsocketServer.attachServer(server)

Metrics.injectMetricsRoute(app)
app.use(Metrics.http.monitor(logger))

app.get "/", (req, res, next) ->
	res.send "real-time-sharelatex is alive"

app.get "/status", (req, res, next) ->
	if Settings.shutDownInProgress
		res.send 503 # Service unavailable
	else
		res.send "real-time-sharelatex is alive"

app.get "/debug/events", (req, res, next) ->
	Settings.debugEvents = parseInt(req.query?.count,10) || 20
	logger.log {count: Settings.debugEvents}, "starting debug mode"
	res.send "debug mode will log next #{Settings.debugEvents} events"

rclient = require("redis-sharelatex").createClient(Settings.redis.realtime)

healthCheck = (req, res, next)->
	rclient.healthCheck (error) ->
		if error?
			logger.err {err: error}, "failed redis health check"
			res.sendStatus 500
		else if HealthCheckManager.isFailing()
			status = HealthCheckManager.status()
			logger.err {pubSubErrors: status}, "failed pubsub health check"
			res.sendStatus 500
		else
			res.sendStatus 200

app.get "/health_check", healthCheck

app.get "/health_check/redis", healthCheck



Router = require "./app/js/Router"
Router.configure(app)

WebsocketLoadBalancer = require "./app/js/WebsocketLoadBalancer"
WebsocketLoadBalancer.listenForEditorEvents()

DocumentUpdaterController = require "./app/js/DocumentUpdaterController"
DocumentUpdaterController.listenForUpdatesFromDocumentUpdater()

port = Settings.internal.realTime.port
host = Settings.internal.realTime.host

server.listen port, host, (error) ->
	throw error if error?
	logger.info "realtime starting up, listening on #{host}:#{port}"

# Stop huge stack traces in logs from all the socket.io parsing steps.
Error.stackTraceLimit = 10


shutdownCleanly = (signal) ->
		if clientMap.size == 0
			logger.warn("no clients connected, exiting")
			process.exit()
		else
			logger.warn {connectedClients: Array.from(clientMap.keys())}, "clients still connected, not shutting down yet"
			setTimeout () ->
				shutdownCleanly(signal)
			, 30 * 1000

drainAndShutdown = (signal) ->
	if Settings.shutDownInProgress
		logger.warn signal: signal, "shutdown already in progress, ignoring signal"
		return
	else
		Settings.shutDownInProgress = true
		statusCheckInterval = Settings.statusCheckInterval
		if statusCheckInterval
			logger.warn signal: signal, "received interrupt, delay drain by #{statusCheckInterval}ms"
		setTimeout () ->
			logger.warn signal: signal, "received interrupt, starting drain over #{shutdownDrainTimeWindow} mins"
			DrainManager.startDrainTimeWindow(shutdownDrainTimeWindow)
			shutdownCleanly(signal)
		, statusCheckInterval


Settings.shutDownInProgress = false
if Settings.shutdownDrainTimeWindow?
	shutdownDrainTimeWindow = parseInt(Settings.shutdownDrainTimeWindow, 10)
	logger.log shutdownDrainTimeWindow: shutdownDrainTimeWindow,"shutdownDrainTimeWindow enabled"
	for signal in ['SIGINT', 'SIGHUP', 'SIGQUIT', 'SIGUSR1', 'SIGUSR2', 'SIGTERM', 'SIGABRT']
		process.on signal, drainAndShutdown  # signal is passed as argument to event handler

	# global exception handler
	if Settings.errors?.catchUncaughtErrors
		process.removeAllListeners('uncaughtException')
		process.on 'uncaughtException', (error) ->
			if ['EPIPE', 'ECONNRESET'].includes(error.code)
				Metrics.inc('disconnected_write', 1, {status: error.code})
				return logger.warn err: error, 'attempted to write to disconnected client'
			logger.error err: error, 'uncaught exception'
			if Settings.errors?.shutdownOnUncaughtError
				drainAndShutdown('SIGABRT')

if Settings.continualPubsubTraffic
	console.log "continualPubsubTraffic enabled"

	pubsubClient = redis.createClient(Settings.redis.pubsub)
	clusterClient = redis.createClient(Settings.redis.websessions)

	publishJob = (channel, callback)->
		checker = new HealthCheckManager(channel)
		logger.debug {channel:channel}, "sending pub to keep connection alive"
		json = JSON.stringify({health_check:true, key: checker.id, date: new Date().toString()})
		Metrics.summary "redis.publish.#{channel}", json.length
		pubsubClient.publish channel, json, (err)->
			if err?
				logger.err {err, channel}, "error publishing pubsub traffic to redis"
			blob = JSON.stringify({keep: "alive"})
			Metrics.summary "redis.publish.cluster-continual-traffic", blob.length
			clusterClient.publish "cluster-continual-traffic", blob, callback


	runPubSubTraffic = ->
		async.map ["applied-ops", "editor-events"], publishJob, (err)->
			setTimeout(runPubSubTraffic, 1000 * 20)

	runPubSubTraffic()



