/* eslint-disable
    no-return-assign,
    no-unused-vars,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
const chai = require('chai');
const should = chai.should();
const sinon = require("sinon");
const modulePath = "../../../app/js/ChannelManager.js";
const SandboxedModule = require('sandboxed-module');

describe('ChannelManager', function() {
	beforeEach(function() {
		this.rclient = {};
		this.other_rclient = {};
		return this.ChannelManager = SandboxedModule.require(modulePath, { requires: {
			"settings-sharelatex": (this.settings = {}),
			"metrics-sharelatex": (this.metrics = {inc: sinon.stub()}),
			"logger-sharelatex": (this.logger = { log: sinon.stub(), warn: sinon.stub(), error: sinon.stub() })
		}
	});});
	
	describe("subscribe", function() {

		describe("when there is no existing subscription for this redis client", function() {
			beforeEach(function() {
				this.rclient.subscribe = sinon.stub();
				return this.ChannelManager.subscribe(this.rclient, "applied-ops", "1234567890abcdef");
			});

			return it("should subscribe to the redis channel", function() {
				return this.rclient.subscribe.calledWithExactly("applied-ops:1234567890abcdef").should.equal(true);
			});
		});

		describe("when there is an existing subscription for this redis client", function() {
			beforeEach(function() {
				this.rclient.subscribe = sinon.stub();
				this.ChannelManager.subscribe(this.rclient, "applied-ops", "1234567890abcdef");
				this.rclient.subscribe = sinon.stub();  // discard the original stub
				return this.ChannelManager.subscribe(this.rclient, "applied-ops", "1234567890abcdef");
			});

			return it("should not subscribe to the redis channel", function() {
				return this.rclient.subscribe.called.should.equal(false);
			});
		});

		return describe("when there is an existing subscription for another redis client but not this one", function() {
			beforeEach(function() {
				this.other_rclient.subscribe = sinon.stub();
				this.ChannelManager.subscribe(this.other_rclient, "applied-ops", "1234567890abcdef");
				this.rclient.subscribe = sinon.stub();  // discard the original stub
				return this.ChannelManager.subscribe(this.rclient, "applied-ops", "1234567890abcdef");
			});

			return it("should subscribe to the redis channel on this redis client", function() {
				return this.rclient.subscribe.calledWithExactly("applied-ops:1234567890abcdef").should.equal(true);
			});
		});
	});

	describe("unsubscribe", function() {

		describe("when there is no existing subscription for this redis client", function() {
			beforeEach(function() {
				this.rclient.unsubscribe = sinon.stub();
				return this.ChannelManager.unsubscribe(this.rclient, "applied-ops", "1234567890abcdef");
			});

			return it("should not unsubscribe from the redis channel", function() {
				return this.rclient.unsubscribe.called.should.equal(false);
			});
		});


		describe("when there is an existing subscription for this another redis client but not this one", function() {
			beforeEach(function() {
				this.other_rclient.subscribe = sinon.stub();
				this.rclient.unsubscribe = sinon.stub();  
				this.ChannelManager.subscribe(this.other_rclient, "applied-ops", "1234567890abcdef");
				return this.ChannelManager.unsubscribe(this.rclient, "applied-ops", "1234567890abcdef");
			});

			return it("should not unsubscribe from the redis channel on this client", function() {
				return this.rclient.unsubscribe.called.should.equal(false);
			});
		});

		return describe("when there is an existing subscription for this redis client", function() {
			beforeEach(function() {
				this.rclient.subscribe = sinon.stub();
				this.rclient.unsubscribe = sinon.stub();  
				this.ChannelManager.subscribe(this.rclient, "applied-ops", "1234567890abcdef");
				return this.ChannelManager.unsubscribe(this.rclient, "applied-ops", "1234567890abcdef");
			});

			return it("should unsubscribe from the redis channel", function() {
				return this.rclient.unsubscribe.calledWithExactly("applied-ops:1234567890abcdef").should.equal(true);
			});
		});
	});

	return describe("publish", function() {

		describe("when the channel is 'all'", function() {
			beforeEach(function() {
				this.rclient.publish = sinon.stub();
				return this.ChannelManager.publish(this.rclient, "applied-ops", "all", "random-message");
			});

			return it("should publish on the base channel", function() {
				return this.rclient.publish.calledWithExactly("applied-ops", "random-message").should.equal(true);
			});
		});

		return describe("when the channel has an specific id", function() {

			describe("when the individual channel setting is false", function() {
				beforeEach(function() {
					this.rclient.publish = sinon.stub();
					this.settings.publishOnIndividualChannels = false;
					return this.ChannelManager.publish(this.rclient, "applied-ops", "1234567890abcdef", "random-message");
				});

				return it("should publish on the per-id channel", function() {
					this.rclient.publish.calledWithExactly("applied-ops", "random-message").should.equal(true);
					return this.rclient.publish.calledOnce.should.equal(true);
				});
			});

			return describe("when the individual channel setting is true", function() {
				beforeEach(function() {
					this.rclient.publish = sinon.stub();
					this.settings.publishOnIndividualChannels = true;
					return this.ChannelManager.publish(this.rclient, "applied-ops", "1234567890abcdef", "random-message");
				});

				return it("should publish on the per-id channel", function() {
					this.rclient.publish.calledWithExactly("applied-ops:1234567890abcdef", "random-message").should.equal(true);
					return this.rclient.publish.calledOnce.should.equal(true);
				});
			});
		});
	});
});

