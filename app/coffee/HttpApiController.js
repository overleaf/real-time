/* eslint-disable
    no-unused-vars,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
let HttpApiController;
const WebsocketLoadBalancer = require("./WebsocketLoadBalancer");
const DrainManager = require("./DrainManager");
const logger = require("logger-sharelatex");

module.exports = (HttpApiController = {
	sendMessage(req, res, next) {
		logger.log({message: req.params.message}, "sending message");
		if (Array.isArray(req.body)) {
			for (const payload of Array.from(req.body)) {
				WebsocketLoadBalancer.emitToRoom(req.params.project_id, req.params.message, payload);
			}
		} else {
			WebsocketLoadBalancer.emitToRoom(req.params.project_id, req.params.message, req.body);
		}
		return res.send(204);
	}, // No content
	
	startDrain(req, res, next) {
		const io = req.app.get("io");
		let rate = req.query.rate || "4";
		rate = parseFloat(rate) || 0;
		logger.log({rate}, "setting client drain rate");
		DrainManager.startDrain(io, rate);
		return res.send(204);
	}
});