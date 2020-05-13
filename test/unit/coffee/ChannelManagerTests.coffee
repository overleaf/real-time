chai = require('chai')
should = chai.should()
expect = chai.expect
sinon = require("sinon")
modulePath = "../../../app/js/ChannelManager.js"
SandboxedModule = require('sandboxed-module')

describe 'ChannelManager', ->
	beforeEach ->
		@rclient = {}
		@other_rclient = {}
		@ChannelManager = SandboxedModule.require modulePath, requires:
			"settings-sharelatex": @settings = {}
			"metrics-sharelatex": @metrics = {inc: sinon.stub(), summary: sinon.stub()}
			"logger-sharelatex": @logger = { log: sinon.stub(), warn: sinon.stub(), error: sinon.stub() }

	describe "subscribe", ->

		describe "when there is no existing subscription for this redis client", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub().resolves()
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done

			it "should subscribe to the redis channel", ->
				@rclient.subscribe.calledWithExactly("applied-ops:1234567890abcdef").should.equal true

		describe "when there is an existing subscription for this redis client", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub().resolves()
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done

			it "should not subscribe to the redis channel", ->
				@rclient.subscribe.callCount.should.equal 1

		describe "when subscribe errors", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub()
					.onFirstCall().rejects(new Error("some redis error"))
					.onSecondCall().resolves()
				p = @ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				p.then () ->
					done(new Error('should not subscribe but fail'))
				.catch (err) =>
					err.message.should.equal "some redis error"
					@ChannelManager.getClientMapEntry(@rclient).has("applied-ops:1234567890abcdef").should.equal false
					@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
					# subscribe is wrapped in Promise, delay other assertions
					setTimeout done
				return null

			it "should subscribe again", ->
				@rclient.subscribe.callCount.should.equal 2
				@ChannelManager.getClientMapEntry(@rclient).has("applied-ops:1234567890abcdef").should.equal true

		describe "when subscribe errors and the clientChannelMap entry was replaced", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub()
					.onFirstCall().rejects(new Error("some redis error"))
					.onSecondCall().resolves()
				@first = @ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				# ignore error
				@first.catch((()->))
				expect(@ChannelManager.getClientMapEntry(@rclient).get("applied-ops:1234567890abcdef")).to.equal @first

				@rclient.unsubscribe = sinon.stub().resolves()
				@ChannelManager.unsubscribe @rclient, "applied-ops", "1234567890abcdef"
				@second = @ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				# should get replaced immediately
				expect(@ChannelManager.getClientMapEntry(@rclient).get("applied-ops:1234567890abcdef")).to.equal @second

				# let the first subscribe error -> unsubscribe -> subscribe
				setTimeout done

			it "should not cleanup the second subscribePromise", ->
				expect(@ChannelManager.getClientMapEntry(@rclient).get("applied-ops:1234567890abcdef")).to.equal @second

		describe "when there is an existing subscription for another redis client but not this one", ->
			beforeEach (done) ->
				@other_rclient.subscribe = sinon.stub().resolves()
				@ChannelManager.subscribe @other_rclient, "applied-ops", "1234567890abcdef"
				@rclient.subscribe = sinon.stub().resolves()  # discard the original stub
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done

			it "should subscribe to the redis channel on this redis client", ->
				@rclient.subscribe.calledWithExactly("applied-ops:1234567890abcdef").should.equal true

	describe "unsubscribe", ->

		describe "when there is no existing subscription for this redis client", ->
			beforeEach (done) ->
				@rclient.unsubscribe = sinon.stub()
				@ChannelManager.unsubscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done

			it "should not unsubscribe from the redis channel", ->
				@rclient.unsubscribe.called.should.equal false


		describe "when there is an existing subscription for this another redis client but not this one", ->
			beforeEach (done) ->
				@other_rclient.subscribe = sinon.stub().resolves()
				@rclient.unsubscribe = sinon.stub()
				@ChannelManager.subscribe @other_rclient, "applied-ops", "1234567890abcdef"
				@ChannelManager.unsubscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done

			it "should not unsubscribe from the redis channel on this client", ->
				@rclient.unsubscribe.called.should.equal false

		describe "when unsubscribe errors and completes", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub().resolves()
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				@rclient.unsubscribe = sinon.stub().rejects(new Error("some redis error"))
				@ChannelManager.unsubscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done
				return null

			it "should have cleaned up", ->
				@ChannelManager.getClientMapEntry(@rclient).has("applied-ops:1234567890abcdef").should.equal false

			it "should not error out when subscribing again", (done) ->
				p = @ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				p.then () ->
					done()
				.catch done
				return null

		describe "when unsubscribe errors and another client subscribes at the same time", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub().resolves()
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				rejectSubscribe = undefined
				@rclient.unsubscribe = () ->
					return new Promise (resolve, reject) ->
						rejectSubscribe = reject
				@ChannelManager.unsubscribe @rclient, "applied-ops", "1234567890abcdef"

				setTimeout () =>
					# delay, actualUnsubscribe should not see the new subscribe request
					# (otherwise it will skip the unsubscribe call as an optimization)
					@ChannelManager.subscribe(@rclient, "applied-ops", "1234567890abcdef")
					.then () ->
						setTimeout done
					.catch done
					setTimeout ->
						# delay, rejectSubscribe is not defined immediately
						rejectSubscribe(new Error("redis error"))
				return null

			it "should have errored", ->
				expect(@metrics.inc.calledWithExactly("unsubscribe.failed.applied-ops")).to.equal(true)

			it "should have subscribed and stored the success", ->
				@rclient.subscribe.called.should.equal true
				@ChannelManager.getClientMapEntry(@rclient).has("applied-ops:1234567890abcdef").should.equal true

		describe "when there is an existing subscription for this redis client", ->
			beforeEach (done) ->
				@rclient.subscribe = sinon.stub().resolves()
				@rclient.unsubscribe = sinon.stub().resolves()
				@ChannelManager.subscribe @rclient, "applied-ops", "1234567890abcdef"
				@ChannelManager.unsubscribe @rclient, "applied-ops", "1234567890abcdef"
				setTimeout done

			it "should unsubscribe from the redis channel", ->
				@rclient.unsubscribe.calledWithExactly("applied-ops:1234567890abcdef").should.equal true

	describe "publish", ->

		describe "when the channel is 'all'", ->
			beforeEach ->
				@rclient.publish = sinon.stub()
				@ChannelManager.publish @rclient, "applied-ops", "all", "random-message"

			it "should publish on the base channel", ->
				@rclient.publish.calledWithExactly("applied-ops", "random-message").should.equal true

		describe "when the channel has an specific id", ->

			describe "when the individual channel setting is false", ->
				beforeEach ->
					@rclient.publish = sinon.stub()
					@settings.publishOnIndividualChannels = false
					@ChannelManager.publish @rclient, "applied-ops", "1234567890abcdef", "random-message"

				it "should publish on the per-id channel", ->
					@rclient.publish.calledWithExactly("applied-ops", "random-message").should.equal true
					@rclient.publish.calledOnce.should.equal true

			describe "when the individual channel setting is true", ->
				beforeEach ->
					@rclient.publish = sinon.stub()
					@settings.publishOnIndividualChannels = true
					@ChannelManager.publish @rclient, "applied-ops", "1234567890abcdef", "random-message"

				it "should publish on the per-id channel", ->
					@rclient.publish.calledWithExactly("applied-ops:1234567890abcdef", "random-message").should.equal true
					@rclient.publish.calledOnce.should.equal true

		describe "metrics", ->
			beforeEach ->
				@rclient.publish = sinon.stub()
				@ChannelManager.publish @rclient, "applied-ops", "all", "random-message"

			it "should track the payload size", ->
				@metrics.summary.calledWithExactly(
					"redis.publish.applied-ops",
					"random-message".length
				).should.equal true

	describe "strictSequence", ->
		entity = "applied-ops"
		getChannel = (id) ->
			return "#{entity}:#{id}"

		getPromiseThatResolvesASentinelSoon = () ->
			sentinel = Math.random()
			p = new Promise (resolve) ->
				setTimeout () ->
					resolve(sentinel)
				, 1
			return {sentinel, p}

		getFloatingPromise = () ->
			resolve = reject = undefined
			p = new Promise (_resolve, _reject) ->
				resolve = _resolve
				reject = _reject
			return {p, resolve, reject}

		beforeEach ->
			@id1 = Math.random().toString()
			@channel1 = getChannel(@id1)
			@id2 = Math.random().toString()
			@channel2 = getChannel(@id1)

			@ChannelManager.getClientMapEntry(@rclient).clear()
			@ChannelManager.getClientMapTearDownEntry(@rclient).clear()
			@clientChannelMapTearDown = @ChannelManager.getClientMapTearDownEntry(@rclient)

			@redisSubscribePromises = []
			@redisUnsubscribePromises = []
			@rclient.subscribe = () =>
				{p, resolve, reject} = getFloatingPromise()
				@redisSubscribePromises.push({p, resolve, reject})
				return p

			@rclient.unsubscribe = () =>
				{p, resolve, reject} = getFloatingPromise()
				@redisUnsubscribePromises.push({p, resolve, reject})
				return p

		describe "subscribe", ->
			beforeEach ->
				@subscribePromise1 = @ChannelManager.subscribe(@rclient, entity, @id1)
				return null # ... no implicit return

			it "should return a pending Promise", (done) ->
				{sentinel, p} = getPromiseThatResolvesASentinelSoon()
				Promise.race([@subscribePromise1, p])
					.then (result) ->
						expect(result).to.equal(sentinel)
						done()
				return null # ... no implicit return

			describe "when there is another inflight subscribe", ->
				beforeEach ->
					@subscribePromise2 = @ChannelManager.subscribe(@rclient, entity, @id1)
					return null # ... no implicit return

				it "should return another pending Promise", (done) ->
					{sentinel, p} = getPromiseThatResolvesASentinelSoon()
					Promise.race([@subscribePromise2, p])
						.then (result) ->
							expect(result).to.equal(sentinel)
							done()
					return null # ... no implicit return

				describe "when the redis subscribe completes", ->
					beforeEach (done) ->
						setTimeout () =>
							@redisSubscribePromises[0].resolve()
							setTimeout done
						, 3
						return null # ... no implicit return

					it "should finish subscribePromise1", (done) ->
						{sentinel, p} = getPromiseThatResolvesASentinelSoon()
						Promise.race([@subscribePromise1, p])
							.then (result) ->
								expect(result).to.not.equal(sentinel)
								done()
						return null # ... no implicit return

					it "should finish subscribePromise2", (done) ->
						{sentinel, p} = getPromiseThatResolvesASentinelSoon()
						Promise.race([@subscribePromise2, p])
							.then (result) ->
								expect(result).to.not.equal(sentinel)
								done()
						return null # ... no implicit return

				describe "when there is a second doc subscribing", ->
					beforeEach ->
						@subscribePromise3 = @ChannelManager.subscribe(@rclient, entity, @id2)
						return null # ... no implicit return

					describe "when the redis subscribe for doc1 completes", ->
						beforeEach (done) ->
							setTimeout () =>
								@redisSubscribePromises[0].resolve()
								setTimeout done
							, 3
							return null # ... no implicit return

						it "should not finish subscribePromise for doc2", (done) ->
							{sentinel, p} = getPromiseThatResolvesASentinelSoon()
							Promise.race([@subscribePromise3, p])
								.then (result) ->
									expect(result).to.equal(sentinel)
									done()
							return null # ... no implicit return

						describe "when the redis subscribe for doc2 completes", ->
							beforeEach (done) ->
								setTimeout () =>
									@redisSubscribePromises[1].resolve()
									setTimeout done
								return null # ... no implicit return

							it "should finish subscribePromise for doc2", (done) ->
								{sentinel, p} = getPromiseThatResolvesASentinelSoon()
								Promise.race([@subscribePromise3, p])
									.then (result) ->
										expect(result).to.not.equal(sentinel)
										done()
								return null # ... no implicit return

			describe "when there is an unsubscribe in between", ->
				beforeEach ->
					@ChannelManager.unsubscribe(@rclient, entity, @id1)
					@subscribePromise2 = @ChannelManager.subscribe(@rclient, entity, @id1)
					return null # ... no implicit return

				it "should return a pending Promise", (done) ->
					{sentinel, p} = getPromiseThatResolvesASentinelSoon()
					Promise.race([@subscribePromise2, p])
						.then (result) ->
							expect(result).to.equal(sentinel)
							done()
					return null # ... no implicit return

				describe "when the subscribe completes", ->
					beforeEach (done) ->
						setTimeout () =>
							@redisSubscribePromises[0].resolve()
							setTimeout done
						, 3
						return null # ... no implicit return

					it "should finish subscribePromise1", (done) ->
						{sentinel, p} = getPromiseThatResolvesASentinelSoon()
						Promise.race([@subscribePromise1, p])
							.then (result) ->
								expect(result).to.not.equal(sentinel)
								done()
						return null # ... no implicit return

					it "should not finish subscribePromise2 yet", (done) ->
						{sentinel, p} = getPromiseThatResolvesASentinelSoon()
						Promise.race([@subscribePromise2, p])
							.then (result) ->
								expect(result).to.equal(sentinel)
								done()
						return null # ... no implicit return

					it "should skip the unsubscribe call", () ->
						expect(@redisUnsubscribePromises).to.deep.equal([])

					describe "when the 2nd redis subscribe complete", ->
						beforeEach (done) ->
							setTimeout () =>
								@redisSubscribePromises[1].resolve()
								setTimeout done
							, 5
							return null # ... no implicit return

						it "should finish subscribePromise2", (done) ->
							{sentinel, p} = getPromiseThatResolvesASentinelSoon()
							Promise.race([@subscribePromise2, p])
								.then (result) ->
									expect(result).to.not.equal(sentinel)
									done()
							return null # ... no implicit return

		describe "unsubscribe", ->
			beforeEach ->
				@subscribePromise1 = @ChannelManager.subscribe(@rclient, entity, @id1)
				@returnValue = @ChannelManager.unsubscribe(@rclient, entity, @id1)
				@tearDownPromise1 = @clientChannelMapTearDown.get(@channel1)
				return null # ... no implicit return

			it "should return immediately", () ->
				expect(@returnValue).to.be.undefined

			it "should wait for the subscribe to complete", () ->
				expect(@redisUnsubscribePromises).to.deep.equal([])

			it "should schedule the unsubscribe", () ->
				expect(@clientChannelMapTearDown.has(@channel1)).to.equal.true

			describe "when the redis subscribe completes", ->
				beforeEach (done) ->
					setTimeout () =>
						@redisSubscribePromises[0].resolve()
						setTimeout done
					, 3
					return null # ... no implicit return

				it "should start unsubscribing", () ->
					expect(@redisUnsubscribePromises.length).to.equal(1)

				it "should not complete the unsubscribe yet", (done) ->
					{sentinel, p} = getPromiseThatResolvesASentinelSoon()
					Promise.race([@tearDownPromise1, p])
						.then (result) ->
							expect(result).to.equal(sentinel)
							done()
					return null # ... no implicit return

				describe "when the redis unsubscribe completes", ->
					beforeEach (done) ->
						setTimeout () =>
							@redisUnsubscribePromises[0].resolve()
							setTimeout done
						, 3
						return null # ... no implicit return

					it "should have finished unsubscribing", (done) ->
						{sentinel, p} = getPromiseThatResolvesASentinelSoon()
						Promise.race([@tearDownPromise1, p])
							.then (result) ->
								expect(result).to.not.equal(sentinel)
								done()
						return null # ... no implicit return

					it "should have cleared the tear down state", () ->
						expect(@clientChannelMapTearDown.has(@channel1)).to.equal false

		verifyConsistentBehaviour = ->
			it "should not finish any subscribePromise", (done) ->
				{sentinel, p} = getPromiseThatResolvesASentinelSoon()
				Promise.race([@subscribePromise1, @subscribePromise2, @subscribePromise3, @subscribePromise4, p])
					.then (result) ->
						expect(result).to.equal(sentinel)
						done()
				return null # ... no implicit return

			it "should wait for the first subscribe to complete before subscribing again", () ->
				expect(@redisSubscribePromises.length).to.equal(1)

			it "should wait for the first subscribe to complete before unsubscribing", () ->
				expect(@redisUnsubscribePromises).to.deep.equal([])

			describe "when the first redis subscribe completes", ->
				beforeEach (done) ->
					setTimeout () =>
						@redisSubscribePromises[0].resolve()
						setTimeout done
					, 3
					return null # ... no implicit return

				it "should finish subscribePromise1", (done) ->
					{sentinel, p} = getPromiseThatResolvesASentinelSoon()
					Promise.race([@subscribePromise1, p])
						.then (result) ->
							expect(result).to.not.equal(sentinel)
							done()
					return null # ... no implicit return

				it "should not finish any other subscribePromise", (done) ->
					{sentinel, p} = getPromiseThatResolvesASentinelSoon()
					Promise.race([@subscribePromise2, @subscribePromise3, @subscribePromise4, p])
						.then (result) ->
							expect(result).to.equal(sentinel)
							done()
					return null # ... no implicit return

				it "should skip unsubscribing", () ->
					expect(@redisUnsubscribePromises).to.deep.equal([])

				it "should complete the unsubscribe immediately", (done) ->
					{sentinel, p} = getPromiseThatResolvesASentinelSoon()
					Promise.race([@tearDownPromise1, p])
						.then (result) ->
							expect(result).to.not.equal(sentinel)
							done()
					return null # ... no implicit return

				it "should not have cleared the tear down state", () ->
					expect(@clientChannelMapTearDown.has(@channel1)).to.equal true

				describe "when the second and third redis subscribe completes", ->
					beforeEach (done) ->
						setTimeout () =>
							@redisSubscribePromises[1].resolve()
							setTimeout () =>
								@redisSubscribePromises[2].resolve()
								setTimeout done
							, 3
						, 3
						return null # ... no implicit return

					it "should still skip unsubscribing", () ->
						expect(@redisUnsubscribePromises).to.deep.equal([])

					it "should complete the 2nd and 3rd unsubscribes immediately", (done) ->
						{sentinel, p} = getPromiseThatResolvesASentinelSoon()
						Promise.race([@tearDownPromise2, @tearDownPromise3, p])
							.then (result) ->
								expect(result).to.not.equal(sentinel)
								done()
						return null # ... no implicit return

					it "should not have cleared the tear down state", () ->
						expect(@clientChannelMapTearDown.has(@channel1)).to.equal true

					describe "when the last redis subscribe completed", ->
						beforeEach (done) ->
							setTimeout () =>
								@redisSubscribePromises[3].resolve()
								setTimeout done
							, 3
							return null # ... no implicit return

						it "should have finished all subscribePromises", (done) ->
							Promise.all([@subscribePromise1, @subscribePromise2, @subscribePromise3, @subscribePromise4])
								.then () ->
									# will timeout when the promises are not ready yet
									done()
							return null # ... no implicit return

						it "should start unsubscribing", () ->
							expect(@redisUnsubscribePromises.length).to.equal(1)

						it "should not complete the unsubscribe yet", (done) ->
							{sentinel, p} = getPromiseThatResolvesASentinelSoon()
							Promise.race([@tearDownPromise4, p])
								.then (result) ->
									expect(result).to.equal(sentinel)
									done()
							return null # ... no implicit return

						it "should not have cleared the tear down state yet", () ->
							expect(@clientChannelMapTearDown.has(@channel1)).to.equal true

						describe "when the last redis unsubscribe completes", ->
							beforeEach (done) ->
								setTimeout () =>
									# actually there is just one redis unsubscribe call
									@redisUnsubscribePromises[0].resolve()
									setTimeout done
								return null # ... no implicit return

							it "should have finished unsubscribing", (done) ->
								{sentinel, p} = getPromiseThatResolvesASentinelSoon()
								Promise.race([@tearDownPromise4, p])
									.then (result) ->
										expect(result).to.not.equal(sentinel)
										done()
								return null # ... no implicit return

							it "should have cleared the tear down state", () ->
								expect(@clientChannelMapTearDown.has(@channel1)).to.equal false

		describe "when lots of requests race in a single event loop cycle (synchronous)", ->
			beforeEach (done) ->
				@subscribePromise1 = @ChannelManager.subscribe(@rclient, entity, @id1)
				@ChannelManager.unsubscribe(@rclient, entity, @id1)
				@tearDownPromise1 = @clientChannelMapTearDown.get(@channel1)

				@subscribePromise2 = @ChannelManager.subscribe(@rclient, entity, @id1)
				@ChannelManager.unsubscribe(@rclient, entity, @id1)
				@tearDownPromise2 = @clientChannelMapTearDown.get(@channel1)

				@subscribePromise3 = @ChannelManager.subscribe(@rclient, entity, @id1)
				@ChannelManager.unsubscribe(@rclient, entity, @id1)
				@tearDownPromise3 = @clientChannelMapTearDown.get(@channel1)

				@subscribePromise4 = @ChannelManager.subscribe(@rclient, entity, @id1)
				@ChannelManager.unsubscribe(@rclient, entity, @id1)
				@tearDownPromise4 = @clientChannelMapTearDown.get(@channel1)
				setTimeout done
				return null # ... no implicit return

			verifyConsistentBehaviour()

		describe "when lots of requests race with process.nextTick in between", ->
			beforeEach (done) ->
				@subscribePromise1 = @ChannelManager.subscribe(@rclient, entity, @id1)
				process.nextTick =>
					@ChannelManager.unsubscribe(@rclient, entity, @id1)
					@tearDownPromise1 = @clientChannelMapTearDown.get(@channel1)

					process.nextTick =>
						@subscribePromise2 = @ChannelManager.subscribe(@rclient, entity, @id1)
						process.nextTick =>
							@ChannelManager.unsubscribe(@rclient, entity, @id1)
							@tearDownPromise2 = @clientChannelMapTearDown.get(@channel1)

							process.nextTick =>
								@subscribePromise3 = @ChannelManager.subscribe(@rclient, entity, @id1)
								process.nextTick =>
									@ChannelManager.unsubscribe(@rclient, entity, @id1)
									@tearDownPromise3 = @clientChannelMapTearDown.get(@channel1)

									process.nextTick =>
										@subscribePromise4 = @ChannelManager.subscribe(@rclient, entity, @id1)
										process.nextTick =>
											@ChannelManager.unsubscribe(@rclient, entity, @id1)
											@tearDownPromise4 = @clientChannelMapTearDown.get(@channel1)

											# let some Promise.then calls run
											setTimeout done
				return null # ... no implicit return

			verifyConsistentBehaviour()

		describe "when lots of requests race with network dispatches in between", ->
			beforeEach (done) ->
				@subscribePromise1 = @ChannelManager.subscribe(@rclient, entity, @id1)
				setTimeout =>
					@ChannelManager.unsubscribe(@rclient, entity, @id1)
					@tearDownPromise1 = @clientChannelMapTearDown.get(@channel1)

					setTimeout =>
						@subscribePromise2 = @ChannelManager.subscribe(@rclient, entity, @id1)
						setTimeout =>
							@ChannelManager.unsubscribe(@rclient, entity, @id1)
							@tearDownPromise2 = @clientChannelMapTearDown.get(@channel1)

							setTimeout =>
								@subscribePromise3 = @ChannelManager.subscribe(@rclient, entity, @id1)
								setTimeout =>
									@ChannelManager.unsubscribe(@rclient, entity, @id1)
									@tearDownPromise3 = @clientChannelMapTearDown.get(@channel1)

									setTimeout =>
										@subscribePromise4 = @ChannelManager.subscribe(@rclient, entity, @id1)
										setTimeout =>
											@ChannelManager.unsubscribe(@rclient, entity, @id1)
											@tearDownPromise4 = @clientChannelMapTearDown.get(@channel1)
											setTimeout done
				return null # ... no implicit return

			verifyConsistentBehaviour()
