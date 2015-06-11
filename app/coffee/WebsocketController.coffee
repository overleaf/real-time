logger = require "logger-sharelatex"
metrics = require "metrics-sharelatex"
WebApiManager = require "./WebApiManager"
AuthorizationManager = require "./AuthorizationManager"
DocumentUpdaterManager = require "./DocumentUpdaterManager"
ConnectedUsersManager = require "./ConnectedUsersManager"
TrackChangesManager = require "./TrackChangesManager"
WebsocketLoadBalancer = require "./WebsocketLoadBalancer"
Utils = require "./Utils"

module.exports = WebsocketController =
	# If the protocol version changes when the client reconnects,
	# it will force a full refresh of the page. Useful for non-backwards
	# compatible protocol changes. Use only in extreme need.
	PROTOCOL_VERSION: 2
	
	joinProject: (client, user, project_id, callback = (error, project, privilegeLevel, protocolVersion) ->) ->
		user_id = user?._id
		logger.log {user_id, project_id, client_id: client.id}, "user joining project"
		metrics.inc "editor.join-project"
		WebApiManager.joinProject project_id, user_id, (error, project, privilegeLevel) ->
			return callback(error) if error?

			if !privilegeLevel or privilegeLevel == ""
				err = new Error("not authorized")
				logger.error {err, project_id, user_id, client_id: client.id}, "user is not authorized to join project"
				return callback(err)
				
			client.join project_id

			client.set("privilege_level", privilegeLevel)
			client.set("user_id", user_id)
			client.set("project_id", project_id)
			client.set("owner_id", project?.owner?._id)
			client.set("first_name", user?.first_name)
			client.set("last_name", user?.last_name)
			client.set("email", user?.email)
			client.set("connected_time", new Date())
			client.set("signup_date", user?.signUpDate)
			client.set("login_count", user?.loginCount)
			
			callback null, project, privilegeLevel, WebsocketController.PROTOCOL_VERSION
			logger.log {user_id, project_id, client_id: client.id}, "user joined project"
			
			# No need to block for setting the user as connected in the cursor tracking
			ConnectedUsersManager.updateUserPosition project_id, client.id, user, null, () ->
		
	# We want to flush a project if there are no more (local) connected clients
	# but we need to wait for the triggering client to disconnect. How long we wait
	# is determined by FLUSH_IF_EMPTY_DELAY.
	FLUSH_IF_EMPTY_DELAY: 500 #ms		
	leaveProject: (io, client, callback = (error) ->) ->
		metrics.inc "editor.leave-project"
		Utils.getClientAttributes client, ["project_id", "user_id"], (error, {project_id, user_id}) ->
			return callback(error) if error?
			logger.log {project_id, user_id, client_id: client.id}, "client leaving project"
			WebsocketLoadBalancer.emitToRoom project_id, "clientTracking.clientDisconnected", client.id
		
			# We can do this in the background
			ConnectedUsersManager.markUserAsDisconnected project_id, client.id, (err) ->
				if err?
					logger.error {err, project_id, user_id, client_id: client.id}, "error marking client as disconnected"
					
			setTimeout () ->
				remainingClients = io.sockets.clients(project_id)
				if remainingClients.length == 0
					# Flush project in the background
					DocumentUpdaterManager.flushProjectToMongoAndDelete project_id, (err) ->
						if err?
							logger.error {err, project_id, user_id, client_id: client.id}, "error flushing to doc updater after leaving project"
					TrackChangesManager.flushProject project_id, (err) ->
						if err?
							logger.error {err, project_id, user_id, client_id: client.id}, "error flushing to track changes after leaving project"
				callback()
			, WebsocketController.FLUSH_IF_EMPTY_DELAY
			
	joinDoc: (client, doc_id, fromVersion = -1, callback = (error, doclines, version, ops) ->) ->
		metrics.inc "editor.join-doc"
		Utils.getClientAttributes client, ["project_id", "user_id"], (error, {project_id, user_id}) ->
			return callback(error) if error?
			return callback(new Error("no project_id found on client")) if !project_id?
			logger.log {user_id, project_id, doc_id, fromVersion, client_id: client.id}, "client joining doc"
					
			AuthorizationManager.assertClientCanViewProject client, (error) ->
				return callback(error) if error?
				DocumentUpdaterManager.getDocument project_id, doc_id, fromVersion, (error, lines, version, ops) ->
					return callback(error) if error?
					# Encode any binary bits of data so it can go via WebSockets
					# See http://ecmanaut.blogspot.co.uk/2006/07/encoding-decoding-utf8-in-javascript.html
					escapedLines = []
					for line in lines
						try
							line = unescape(encodeURIComponent(line))
						catch err
							logger.err {err, project_id, doc_id, fromVersion, line, client_id: client.id}, "error encoding line uri component"
							return callback(err)
						escapedLines.push line
					client.join(doc_id)
					callback null, escapedLines, version, ops
					logger.log {user_id, project_id, doc_id, fromVersion, client_id: client.id}, "client joined doc"
					
	leaveDoc: (client, doc_id, callback = (error) ->) ->
		metrics.inc "editor.leave-doc"
		Utils.getClientAttributes client, ["project_id", "user_id"], (error, {project_id, user_id}) ->
			logger.log {user_id, project_id, doc_id, client_id: client.id}, "client leaving doc"
		client.leave doc_id
		callback()
		
	updateClientPosition: (client, cursorData, callback = (error) ->) ->
		metrics.inc "editor.update-client-position", 0.1
		Utils.getClientAttributes client, [
			"project_id", "first_name", "last_name", "email", "user_id"
		], (error, {project_id, first_name, last_name, email, user_id}) ->
			return callback(error) if error?
			logger.log {user_id, project_id, client_id: client.id, cursorData: cursorData}, "updating client position"
					
			AuthorizationManager.assertClientCanViewProject client, (error) ->
				if error?
					logger.warn {client_id: client.id, project_id, user_id}, "silently ignoring unauthorized updateClientPosition. Client likely hasn't called joinProject yet."
					callback()
				cursorData.id      = client.id
				cursorData.user_id = user_id if user_id?
				cursorData.email   = email   if email?
				if first_name? and last_name?
					cursorData.name = first_name + " " + last_name
					ConnectedUsersManager.updateUserPosition(project_id, client.id, {
						first_name: first_name,
						last_name:  last_name,
						email:      email,
						_id:        user_id
					}, {
						row:    cursorData.row,
						column: cursorData.column,
						doc_id: cursorData.doc_id
					}, callback)
				else
					cursorData.name = "Anonymous"
					callback()
				WebsocketLoadBalancer.emitToRoom(project_id, "clientTracking.clientUpdated", cursorData)
		
	getConnectedUsers: (client, callback = (error, users) ->) ->
		metrics.inc "editor.get-connected-users"
		Utils.getClientAttributes client, ["project_id", "user_id"], (error, {project_id, user_id}) ->
			return callback(error) if error?
			return callback(new Error("no project_id found on client")) if !project_id?
			logger.log {user_id, project_id, client_id: client.id}, "getting connected users"
			AuthorizationManager.assertClientCanViewProject client, (error) ->
				return callback(error) if error?
				ConnectedUsersManager.getConnectedUsers project_id, (error, users) ->
					return callback(error) if error?
					callback null, users
					logger.log {user_id, project_id, client_id: client.id}, "got connected users"
					

	applyOtUpdate: (client, doc_id, update, callback = (error) ->) ->
		Utils.getClientAttributes client, ["user_id", "project_id"], (error, {user_id, project_id}) ->
			return callback(error) if error?
			return callback(new Error("no project_id found on client")) if !project_id?
			# Omit this logging for now since it's likely too noisey
			#logger.log {user_id, project_id, doc_id, client_id: client.id, update: update}, "applying update"
			AuthorizationManager.assertClientCanEditProject client, (error) ->
				if error?
					logger.error {err: error, doc_id, client_id: client.id, version: update.v}, "client is not authorized to make update"
					setTimeout () ->
						# Disconnect, but give the client the chance to receive the error
						client.disconnect()
					, 100
					return callback(error)
				update.meta ||= {}
				update.meta.source = client.id
				update.meta.user_id = user_id
				metrics.inc "editor.doc-update", 0.3
				metrics.set "editor.active-projects", project_id, 0.3
				metrics.set "editor.active-users", user_id, 0.3

				logger.log {user_id, doc_id, project_id, client_id: client.id, version: update.v}, "sending update to doc updater"

				update = WebsocketController._sanitizeUpdate(update)

				DocumentUpdaterManager.queueChange project_id, doc_id, update, (error) ->
					if error?
						logger.error {err: error, project_id, doc_id, client_id: client.id, version: update.v}, "document was not available for update"
						client.disconnect()
					callback(error)
					#logger.log {user_id, project_id, doc_id, client_id: client.id}, "applied update"

	_sanitizeUpdate: (update) ->
		# In Javascript, characters are 16-bits wide. It does not understand surrogates as characters.
		# 
		# From Wikipedia (http://en.wikipedia.org/wiki/Plane_(Unicode)#Basic_Multilingual_Plane):
		# "The High Surrogates (U+D800–U+DBFF) and Low Surrogate (U+DC00–U+DFFF) codes are reserved
		# for encoding non-BMP characters in UTF-16 by using a pair of 16-bit codes: one High Surrogate
		# and one Low Surrogate. A single surrogate code point will never be assigned a character.""
		# 
		# The main offender seems to be \uD835 as a stand alone character, which would be the first
		# 16-bit character of a blackboard bold character (http://www.fileformat.info/info/unicode/char/1d400/index.htm).
		# Something must be going on client side that is screwing up the encoding and splitting the
		# two 16-bit characters so that \uD835 is standalone.
		for op in update.op or []
			if op.i?
				# Replace high and low surrogate characters with 'replacement character' (\uFFFD)
				op.i = op.i.replace(/[\uD800-\uDFFF]/g, "\uFFFD")
		return update