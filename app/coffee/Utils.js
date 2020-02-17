/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
let Utils;
const async = require("async");

module.exports = (Utils = {
	getClientAttributes(client, keys, callback) {
		if (callback == null) { callback = function(error, attributes) {}; }
		const attributes = {};
		const jobs = keys.map(key => callback => client.get(key, function(error, value) {
            if (error != null) { return callback(error); }
            attributes[key] = value;
            return callback();
        }));
		return async.series(jobs, function(error) {
			if (error != null) { return callback(error); }
			return callback(null, attributes);
		});
	}
});