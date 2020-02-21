{expect} = require("chai")

module.exports =
	getClientId: (client) ->
		return client.socket.sessionid

	expectClientIsConnected: (client) ->
		expect(client.socket.connected).to.equal(true)

	expectClientIsDisconnected: (client) ->
		expect(client.socket.connected).to.equal(false)
