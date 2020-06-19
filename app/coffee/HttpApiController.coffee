WebsocketLoadBalancer = require "./WebsocketLoadBalancer"
DrainManager = require "./DrainManager"
logger = require "logger-sharelatex"
{clientMap} = require("./WebsocketServer")

module.exports = HttpApiController =
	sendMessage: (req, res, next) ->
		logger.log {message: req.params.message}, "sending message"
		if Array.isArray(req.body)
			for payload in req.body
				WebsocketLoadBalancer.emitToRoom req.params.project_id, req.params.message, payload
		else
			WebsocketLoadBalancer.emitToRoom req.params.project_id, req.params.message, req.body
		res.send 204 # No content
	
	startDrain: (req, res, next) ->
		rate = req.query.rate or "4"
		rate = parseFloat(rate) || 0
		logger.log {rate}, "setting client drain rate"
		DrainManager.startDrain rate
		res.send 204

	disconnectClient: (req, res, next) ->
		client_id = req.params.client_id
		client = clientMap.get(client_id)

		if !client
			logger.info({client_id}, "api: client already disconnected")
			res.sendStatus(404)
			return
		logger.warn({client_id}, "api: requesting client disconnect")
		client.on "disconnect", () ->
			res.sendStatus(204)
		client.disconnect()
