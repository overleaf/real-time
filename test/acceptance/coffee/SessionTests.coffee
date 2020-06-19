chai = require("chai")
expect = chai.expect

FixturesManager = require "./helpers/FixturesManager"
RealTimeClient = require "./helpers/RealTimeClient"
{getClientId, expectClientIsDisconnected} = require "./helpers/SocketIoUtils"

describe "Session", ->
	describe "when the bootstrap param is missing", ->
		before () ->
			RealTimeClient.bootstrap = ''

		before (done) ->
			@client = RealTimeClient.connect()

			@client.on "connectionRejected", (@reason) =>
				done()

		it "should tell the client to retry", () ->
			expect(@reason.message).to.equal('retry')

		it "should ask the client to flush the bootstrap blob", () ->
			expect(@reason.flushBootstrap).to.equal(true)

		it "should get disconnected", () ->
			expectClientIsDisconnected(@client)

	describe "with an invalid bootstrap param", ->
		before () ->
			RealTimeClient.bootstrap = 'foo:bar.123'

		before (done) ->
			@client = RealTimeClient.connect()

			@client.on "connectionRejected", (@reason) =>
				done()

		it "should tell the client to retry", () ->
			expect(@reason.message).to.equal('retry')

		it "should ask the client to flush the bootstrap blob", () ->
			expect(@reason.flushBootstrap).to.equal(true)

		it "should get disconnected", () ->
			expectClientIsDisconnected(@client)

	describe "with an invalid token", ->
		before () ->
			RealTimeClient.token = 'does-not-map-to-sid'
			RealTimeClient.regenerateBootstrap()

		before (done) ->
			@client = RealTimeClient.connect()

			@client.on "connectionRejected", (@reason) =>
				done()

		it "should tell the client to retry", () ->
			expect(@reason.message).to.equal('retry')

		it "should ask the client to flush the bootstrap blob", () ->
			expect(@reason.flushBootstrap).to.equal(true)

		it "should get disconnected", () ->
			expectClientIsDisconnected(@client)

	describe "with an invalid session", ->
		before (done) ->
			FixturesManager.setUpProject {
				privilegeLevel: "owner"
			}, done

		before (done) ->
			RealTimeClient.deleteSession(RealTimeClient.sessionId, done)

		before (done) ->
			@client = RealTimeClient.connect()

			@client.on "connectionRejected", (@reason) =>
				done()

		it "should tell the client about the invalid session", () ->
			expect(@reason.message).to.equal('invalid session')

		it "should not ask the client to flush the bootstrap blob", () ->
			expect(@reason.flushBootstrap).to.equal(undefined )

		it "should get disconnected", () ->
			expectClientIsDisconnected(@client)

	describe "with an established session", ->
		before (done) ->
			FixturesManager.setUpProject {
				privilegeLevel: "owner"
			}, (error, {@project_id}) => done()

		before (done) ->
			@user_id = "mock-user-id"
			RealTimeClient.setSession {
				user: { _id: @user_id }
			}, (error) =>
				throw error if error?
				@client = RealTimeClient.connect()

				@disconnected = false
				@client.on "disconnect", () =>
					@disconnected = true

				@client.on "connectionAccepted", () ->
					done()
			return null

		it "should not get disconnected", (done) ->
			setTimeout () =>
				expect(@disconnected).to.equal false
				done()
			, 100
			
		it "should appear in the list of connected clients", (done) ->
			RealTimeClient.getConnectedClients (error, clients) =>
				included = false
				for client in clients
					if client.client_id == getClientId(@client)
						included = true
						break
				expect(included).to.equal true
				done()
