/* eslint-disable
    camelcase,
    handle-callback-err,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
let AuthorizationManager;
module.exports = (AuthorizationManager = {
	assertClientCanViewProject(client, callback) {
		if (callback == null) { callback = function(error) {}; }
		return AuthorizationManager._assertClientHasPrivilegeLevel(client, ["readOnly", "readAndWrite", "owner"], callback);
	},

	assertClientCanEditProject(client, callback) {
		if (callback == null) { callback = function(error) {}; }
		return AuthorizationManager._assertClientHasPrivilegeLevel(client, ["readAndWrite", "owner"], callback);
	},
				
	_assertClientHasPrivilegeLevel(client, allowedLevels, callback) {
		if (callback == null) { callback = function(error) {}; }
		return client.get("privilege_level", function(error, privilegeLevel) {
			if (error != null) { return callback(error); }
			const allowed = (Array.from(allowedLevels).includes(privilegeLevel));
			if (allowed) {
				return callback(null);
			} else {
				return callback(new Error("not authorized"));
			}
		});
	},

	assertClientCanViewProjectAndDoc(client, doc_id, callback) {
		if (callback == null) { callback = function(error) {}; }
		return AuthorizationManager.assertClientCanViewProject(client, function(error) {
			if (error != null) { return callback(error); }
			return AuthorizationManager._assertClientCanAccessDoc(client, doc_id, callback);
		});
	},

	assertClientCanEditProjectAndDoc(client, doc_id, callback) {
		if (callback == null) { callback = function(error) {}; }
		return AuthorizationManager.assertClientCanEditProject(client, function(error) {
			if (error != null) { return callback(error); }
			return AuthorizationManager._assertClientCanAccessDoc(client, doc_id, callback);
		});
	},

	_assertClientCanAccessDoc(client, doc_id, callback) {
		if (callback == null) { callback = function(error) {}; }
		return client.get(`doc:${doc_id}`, function(error, status) {
			if (error != null) { return callback(error); }
			if ((status != null) && (status === "allowed")) {
				return callback(null);
			} else {
				return callback(new Error("not authorized"));
			}
		});
	},

	addAccessToDoc(client, doc_id, callback) {
		if (callback == null) { callback = function(error) {}; }
		return client.set(`doc:${doc_id}`, "allowed", callback);
	},

	removeAccessToDoc(client, doc_id, callback) {
		if (callback == null) { callback = function(error) {}; }
		return client.del(`doc:${doc_id}`, callback);
	}
});
