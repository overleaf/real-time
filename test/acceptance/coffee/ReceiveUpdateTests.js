/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
const chai = require("chai");
const {
    expect
} = chai;
chai.should();

const RealTimeClient = require("./helpers/RealTimeClient");
const MockWebServer = require("./helpers/MockWebServer");
const FixturesManager = require("./helpers/FixturesManager");

const async = require("async");

const settings = require("settings-sharelatex");
const redis = require("redis-sharelatex");
const rclient = redis.createClient(settings.redis.websessions);

describe("receiveUpdate", function() {
	before(function(done) {
		this.lines = ["test", "doc", "lines"];
		this.version = 42;
		this.ops = ["mock", "doc", "ops"];
		
		return async.series([
			cb => {
				return FixturesManager.setUpProject({
					privilegeLevel: "owner",
					project: { name: "Test Project"	}
				}, (error, {user_id, project_id}) => { this.user_id = user_id; this.project_id = project_id; return cb(); });
			},
			
			cb => {
				return FixturesManager.setUpDoc(this.project_id, {lines: this.lines, version: this.version, ops: this.ops}, (e, {doc_id}) => {
					this.doc_id = doc_id;
					return cb(e);
				});
			},
			
			cb => {
				this.clientA = RealTimeClient.connect();
				return this.clientA.on("connectionAccepted", cb);
			},
				
			cb => {
				this.clientB = RealTimeClient.connect();
				return this.clientB.on("connectionAccepted", cb);
			},
				
			cb => {
				return this.clientA.emit("joinProject", {
					project_id: this.project_id
				}, cb);
			},
			
			cb => {
				return this.clientA.emit("joinDoc", this.doc_id, cb);
			},
				
			cb => {
				return this.clientB.emit("joinProject", {
					project_id: this.project_id
				}, cb);
			},
			
			cb => {
				return this.clientB.emit("joinDoc", this.doc_id, cb);
			}
		], done);
	});
		
	describe("with an update from clientA", function() {
		before(function(done) {
			this.clientAUpdates = [];
			this.clientA.on("otUpdateApplied", update => this.clientAUpdates.push(update));
			this.clientBUpdates = [];
			this.clientB.on("otUpdateApplied", update => this.clientBUpdates.push(update));
			
			this.update = {
				doc_id: this.doc_id,
				op: {
					meta: {
						source: this.clientA.socket.sessionid
					},
					v: this.version,
					doc: this.doc_id,
					op: [{i: "foo", p: 50}]
				}				
			};
			rclient.publish("applied-ops", JSON.stringify(this.update));
			return setTimeout(done, 200);
		}); // Give clients time to get message
			
		it("should send the full op to clientB", function() {
			return this.clientBUpdates.should.deep.equal([this.update.op]);
	});
			
		return it("should send an ack to clientA", function() {
			return this.clientAUpdates.should.deep.equal([{
				v: this.version, doc: this.doc_id
			}]);
	});
});
			
	return describe("with an error", function() {
		before(function(done) {
			this.clientAErrors = [];
			this.clientA.on("otUpdateError", error => this.clientAErrors.push(error));
			this.clientBErrors = [];
			this.clientB.on("otUpdateError", error => this.clientBErrors.push(error));
			
			rclient.publish("applied-ops", JSON.stringify({doc_id: this.doc_id, error: (this.error = "something went wrong")}));
			return setTimeout(done, 200);
		}); // Give clients time to get message
			
		it("should send the error to both clients", function() {
			this.clientAErrors.should.deep.equal([this.error]);
			return this.clientBErrors.should.deep.equal([this.error]);
	});
			
		return it("should disconnect the clients", function() {
			this.clientA.socket.connected.should.equal(false);
			return this.clientB.socket.connected.should.equal(false);
		});
	});
});