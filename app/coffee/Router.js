/* eslint-disable
    camelcase,
    handle-callback-err,
    standard/no-callback-literal,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * DS103: Rewrite code to no longer use __guard__
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
let Router;
const metrics = require("metrics-sharelatex");
const logger = require("logger-sharelatex");
const settings = require("settings-sharelatex");
const WebsocketController = require("./WebsocketController");
const HttpController = require("./HttpController");
const HttpApiController = require("./HttpApiController");
const Utils = require("./Utils");
const bodyParser = require("body-parser");

const basicAuth = require('basic-auth-connect');
const httpAuth = basicAuth(function(user, pass){
	const isValid = (user === settings.internal.realTime.user) && (pass === settings.internal.realTime.pass);
	if (!isValid) {
		logger.err({user, pass}, "invalid login details");
	}
	return isValid;
});

module.exports = (Router = {
	_handleError(callback, error, client, method, extraAttrs) {
		if (callback == null) { callback = function(error) {}; }
		if (extraAttrs == null) { extraAttrs = {}; }
		return Utils.getClientAttributes(client, ["project_id", "doc_id", "user_id"], function(_, attrs) {
			for (const key in extraAttrs) {
				const value = extraAttrs[key];
				attrs[key] = value;
			}
			attrs.client_id = client.id;
			attrs.err = error;
			if (error.name === "CodedError") {
				logger.warn(attrs, error.message, {code: error.code});
				return callback({message: error.message, code: error.code});
			}
			if (["not authorized", "doc updater could not load requested ops", "no project_id found on client"].includes(error.message)) {
				logger.warn(attrs, error.message);
				return callback({message: error.message});
			} else {
				logger.error(attrs, `server side error in ${method}`);
				// Don't return raw error to prevent leaking server side info
				return callback({message: "Something went wrong in real-time service"});
			}
	});
	},

	configure(app, io, session) {
		app.set("io", io);
		app.get("/clients", HttpController.getConnectedClients);
		app.get("/clients/:client_id", HttpController.getConnectedClient);

		app.post("/project/:project_id/message/:message", httpAuth, bodyParser.json({limit: "5mb"}), HttpApiController.sendMessage);
		
		app.post("/drain", httpAuth, HttpApiController.startDrain);

		return session.on('connection', function(error, client, session) {
			let user;
			if (client != null) {
				client.on("error", function(err) {
				logger.err({ clientErr: err }, "socket.io client error");
				if (client.connected) {
					client.emit("reconnectGracefully");
					return client.disconnect();
				}
			});
			}

			if (settings.shutDownInProgress) {
				client.emit("connectionRejected", {message: "retry"});
				client.disconnect();
				return;
			}

			if ((client != null) && __guard__(error != null ? error.message : undefined, x => x.match(/could not look up session by key/))) {
				logger.warn({err: error, client: (client != null), session: (session != null)}, "invalid session");
				// tell the client to reauthenticate if it has an invalid session key
				client.emit("connectionRejected", {message: "invalid session"});
				client.disconnect();
				return;
			}

			if (error != null) {
				logger.err({err: error, client: (client != null), session: (session != null)}, "error when client connected");
				if (client != null) {
					client.emit("connectionRejected", {message: "error"});
				}
				if (client != null) {
					client.disconnect();
				}
				return;
			}

			// send positive confirmation that the client has a valid connection
			client.emit("connectionAccepted");

			metrics.inc('socket-io.connection');
			metrics.gauge('socket-io.clients', __guard__(io.sockets.clients(), x1 => x1.length));

			logger.log({session, client_id: client.id}, "client connected");

			if (__guard__(session != null ? session.passport : undefined, x2 => x2.user) != null) {
				({
                    user
                } = session.passport);
			} else if ((session != null ? session.user : undefined) != null) {
				({
                    user
                } = session);
			} else {
				user = {_id: "anonymous-user"};
			}

			client.on("joinProject", function(data, callback) {
				if (data == null) { data = {}; }
				if (data.anonymousAccessToken) {
					user.anonymousAccessToken = data.anonymousAccessToken;
				}
				return WebsocketController.joinProject(client, user, data.project_id, function(err, ...args) {
					if (err != null) {
						return Router._handleError(callback, err, client, "joinProject", {project_id: data.project_id, user_id: (user != null ? user.id : undefined)});
					} else {
						return callback(null, ...Array.from(args));
					}
				});
			});

			client.on("disconnect", function() {
				metrics.inc('socket-io.disconnect');
				metrics.gauge('socket-io.clients', __guard__(io.sockets.clients(), x3 => x3.length) - 1);
				return WebsocketController.leaveProject(io, client, function(err) {
					if (err != null) {
						return Router._handleError(null, err, client, "leaveProject");
					}
				});
			});

			// Variadic. The possible arguments:
			// doc_id, callback
			// doc_id, fromVersion, callback
			// doc_id, options, callback
			// doc_id, fromVersion, options, callback
			client.on("joinDoc", function(doc_id, fromVersion, options, callback) {
				if ((typeof fromVersion === "function") && !options) {
					callback = fromVersion;
					fromVersion = -1;
					options = {};
				} else if ((typeof fromVersion === "number") && (typeof options === "function")) {
					callback = options;
					options = {};
				} else if ((typeof fromVersion === "object") && (typeof options === "function")) {
					callback = options;
					options = fromVersion;
					fromVersion = -1;
				} else if ((typeof fromVersion === "number") && (typeof options === "object")) {
					// Called with 4 args, things are as expected
				} else {
					logger.error({ arguments }, "unexpected arguments");
					return (typeof callback === 'function' ? callback(new Error("unexpected arguments")) : undefined);
				}

				return WebsocketController.joinDoc(client, doc_id, fromVersion, options, function(err, ...args) {
					if (err != null) {
						return Router._handleError(callback, err, client, "joinDoc", {doc_id, fromVersion});
					} else {
						return callback(null, ...Array.from(args));
					}
				});
			});

			client.on("leaveDoc", (doc_id, callback) => WebsocketController.leaveDoc(client, doc_id, function(err, ...args) {
                if (err != null) {
                    return Router._handleError(callback, err, client, "leaveDoc");
                } else {
                    return callback(null, ...Array.from(args));
                }
            }));

			client.on("clientTracking.getConnectedUsers", function(callback) {
				if (callback == null) { callback = function(error, users) {}; }
				return WebsocketController.getConnectedUsers(client, function(err, users) {
					if (err != null) {
						return Router._handleError(callback, err, client, "clientTracking.getConnectedUsers");
					} else {
						return callback(null, users);
					}
				});
			});

			client.on("clientTracking.updatePosition", function(cursorData, callback) {
				if (callback == null) { callback = function(error) {}; }
				return WebsocketController.updateClientPosition(client, cursorData, function(err) {
					if (err != null) {
						return Router._handleError(callback, err, client, "clientTracking.updatePosition");
					} else {
						return callback();
					}
				});
			});

			return client.on("applyOtUpdate", function(doc_id, update, callback) {
				if (callback == null) { callback = function(error) {}; }
				return WebsocketController.applyOtUpdate(client, doc_id, update, function(err) {
					if (err != null) {
						return Router._handleError(callback, err, client, "applyOtUpdate", {doc_id, update});
					} else {
						return callback();
					}
				});
			});
		});
	}
});

function __guard__(value, transform) {
  return (typeof value !== 'undefined' && value !== null) ? transform(value) : undefined;
}