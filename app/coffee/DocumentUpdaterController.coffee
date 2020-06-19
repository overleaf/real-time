logger = require "logger-sharelatex"
settings = require 'settings-sharelatex'
RedisClientManager = require "./RedisClientManager"
SafeJsonParse = require "./SafeJsonParse"
EventLogger = require "./EventLogger"
HealthCheckManager = require "./HealthCheckManager"
RoomManager = require "./RoomManager"
ChannelManager = require "./ChannelManager"
metrics = require "metrics-sharelatex"
{clientMap} = require("./WebsocketServer")

MESSAGE_SIZE_LOG_LIMIT = 1024 * 1024 # 1Mb

module.exports = DocumentUpdaterController =
	# DocumentUpdaterController is responsible for updates that come via Redis
	# Pub/Sub from the document updater.
	rclientList: RedisClientManager.createClientList(settings.redis.pubsub)

	listenForUpdatesFromDocumentUpdater: () ->
		logger.log {rclients: @rclientList.length}, "listening for applied-ops events"
		for rclient, i in @rclientList
			rclient.subscribe "applied-ops"
			rclient.on "message", (channel, message) ->
				metrics.inc "rclient", 0.001 # global event rate metric
				EventLogger.debugEvent(channel, message) if settings.debugEvents > 0
				DocumentUpdaterController._processMessageFromDocumentUpdater(channel, message)
		# create metrics for each redis instance only when we have multiple redis clients
		if @rclientList.length > 1
			for rclient, i in @rclientList
				do (i) ->
					rclient.on "message", () ->
						metrics.inc "rclient-#{i}", 0.001 # per client event rate metric
		@handleRoomUpdates(@rclientList)

	handleRoomUpdates: (rclientSubList) ->
		roomEvents = RoomManager.eventSource()
		roomEvents.on 'doc-active', (doc_id) ->
			subscribePromises = for rclient in rclientSubList
				ChannelManager.subscribe rclient, "applied-ops", doc_id
			RoomManager.emitOnCompletion(subscribePromises, "doc-subscribed-#{doc_id}")
		roomEvents.on 'doc-empty', (doc_id) ->
			for rclient in rclientSubList
				ChannelManager.unsubscribe rclient, "applied-ops", doc_id

	_processMessageFromDocumentUpdater: (channel, message) ->
		SafeJsonParse.parse message, (error, message) ->
			if error?
				logger.error {err: error, channel}, "error parsing JSON"
				return
			if message.op?
				if message._id? && settings.checkEventOrder
					status = EventLogger.checkEventOrder("applied-ops", message._id, message)
					if status is 'duplicate'
						return # skip duplicate events
				DocumentUpdaterController._applyUpdateFromDocumentUpdater(message.doc_id, message.op)
			else if message.error?
				DocumentUpdaterController._processErrorFromDocumentUpdater(message.doc_id, message.error, message)
			else if message.health_check?
				logger.debug {message}, "got health check message in applied ops channel"
				HealthCheckManager.check channel, message.key

	_applyUpdateFromDocumentUpdater: (doc_id, update) ->
		clientList = RoomManager.getClientsInRoomSync doc_id
		# avoid unnecessary work if no clients are connected
		if clientList.length is 0
			return
		source = update.meta.source
		# send updates to clients
		for client in clientList
			if client.publicId == source
				logger.log doc_id, version: update.v, source, "distributing update to sender"
				client.emit "otUpdateApplied", v: update.v, doc: update.doc
			else if !update.dup # Duplicate ops should just be sent back to sending client for acknowledgement
				logger.log doc_id, version: update.v, source, client_id: client.id, "distributing update to collaborator"
				client.emit "otUpdateApplied", update

	_processErrorFromDocumentUpdater: (doc_id, error, message) ->
		RoomManager.getClientsInRoomPseudoAsync doc_id, (err, clients) ->
			if err?
				return logger.err {room: doc_id, err}, "failed to get room clients"

			for client in clients
				logger.warn err: error, doc_id: doc_id, client_id: client.id, "error from document updater, disconnecting client"
				client.emit "otUpdateError", error, message
				client.disconnect()


