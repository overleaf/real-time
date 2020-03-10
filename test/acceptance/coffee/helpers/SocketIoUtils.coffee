{expect} = require("chai")

module.exports =
	getClientId: (client) ->
		return client.id

	expectClientIsConnected: (client) ->
		expect(client.connected).to.equal(true)

	expectClientIsDisconnected: (client) ->
		expect(client.connected).to.equal(false)
