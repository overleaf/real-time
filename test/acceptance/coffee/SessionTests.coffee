chai = require("chai")
expect = chai.expect

RealTimeClient = require "./helpers/RealTimeClient"
{getClientId} = require "./helpers/SocketIoUtils"

describe "Session", ->
	describe "with an established session", ->
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

				@client.on "connect", () ->
					done()
			return null

		it "should not get disconnected", (done) ->
			setTimeout () =>
				expect(@disconnected).to.equal false
				done()
			, 500
			
		it "should appear in the list of connected clients", (done) ->
			RealTimeClient.getConnectedClients (error, clients) =>
				included = false
				for client in clients
					if client.client_id == getClientId(@client)
						included = true
						break
				expect(included).to.equal true
				done()
