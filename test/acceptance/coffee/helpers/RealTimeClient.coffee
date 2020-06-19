io = require("../../coffee/helpers/socketShimV3")
async = require("async")

request = require "request"
Settings = require "settings-sharelatex"
redis = require "redis-sharelatex"
logger = require('logger-sharelatex')
rclient = redis.createClient(Settings.redis.websessions)

uid = require('uid-safe').sync
signature = require("cookie-signature")

USE_POLLING = process.env.TRANSPORT == 'polling'
logger.fatal({USE_POLLING}, 'acceptance test client configuration')

module.exports = Client =
	sessionId: null
	project_id: null
	bootstrap: null
	regenerateBootstrap: () ->
		project_id = Client.project_id
		secret = Settings.security.bootstrapSecret
		blob = "v1:#{Client.token}:#{project_id}"
		Client.bootstrap = signature.sign(blob, secret)

	setSession: (session, callback = (error) ->) ->
		sessionId = uid(24)
		session.cookie = {}
		rclient.set "sess:" + sessionId, JSON.stringify(session), (error) ->
			return callback(error) if error?
			Client.sessionId = sessionId
			token = uid(48)
			rclient.set "token:" + token, sessionId, (error) ->
				return callback(error) if error
				Client.token = token
				Client.regenerateBootstrap()
				callback()
		return null
	
	deleteSession: (sessionId, callback) ->
		rclient.del "sess:" + sessionId, callback
		return null

	unsetSession: (callback = (error) ->) ->
		Client.token = null
		Client.bootstrap = null
		callback()
			
	connect: () ->
		client = io.connect("http://localhost:3026", {
				"connect timeout": 10 * 1000,
				resource: 'socket.io',
				ctx: {
					csrfToken: 'dummy',
					projectId: Client.project_id,
					usePolling: USE_POLLING,
					wsBootstrap: {
						bootstrap: Client.bootstrap,
						expiry: 60 * 1000, # dummy
					},
				},
			}
		)
		client.on 'connectionAccepted', (_, publicId) ->
			client.publicId = publicId
		return client
		
	getConnectedClients: (callback = (error, clients) ->) ->
		request.get {
			url: "http://localhost:3026/clients"
			json: true
		}, (error, response, data) ->
			callback error, data
		return null

	getConnectedClient: (client_id, callback = (error, clients) ->) ->
		request.get {
			url: "http://localhost:3026/clients/#{client_id}"
			json: true
		}, (error, response, data) ->
			callback error, data
		return null

	disconnectClient: (client_id, callback) ->
		request.post {
			url: "http://localhost:3026/client/#{client_id}/disconnect"
			auth: {
				user: Settings.internal.realTime.user,
				pass: Settings.internal.realTime.pass
			}
		}, (error, response, data) ->
			callback error, data
		return null

	disconnectAllClients: (callback) ->
		Client.getConnectedClients (error, clients) ->
			async.each clients, (clientView, cb) ->
				Client.disconnectClient clientView.client_id, cb
			, callback
