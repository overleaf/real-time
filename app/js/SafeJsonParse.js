/* eslint-disable
    handle-callback-err,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
const Settings = require("settings-sharelatex");
const logger = require("logger-sharelatex");

module.exports = {
	parse(data, callback) {
		let parsed;
		if (callback == null) { callback = function(error, parsed) {}; }
		if (data.length > (Settings.max_doc_length || (2 * 1024 * 1024))) {
			logger.error({head: data.slice(0,1024)}, "data too large to parse");
			return callback(new Error("data too large to parse"));
		}
		try {
			parsed = JSON.parse(data);
		} catch (e) {
			return callback(e);
		}
		return callback(null, parsed);
	}
};