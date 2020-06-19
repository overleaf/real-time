{clientMap} = require("./WebsocketServer")

module.exports = HttpController =
	_getConnectedClientView: (ioClient) ->
			client_id = ioClient.id
			{project_id, user_id, first_name, last_name, email, connected_time} = ioClient.ol_context
			client = {client_id, project_id, user_id, first_name, last_name, email, connected_time}
			client.rooms = ioClient.rooms
			return client

	getConnectedClients: (req, res) ->
		res.json Array.from(clientMap.values()).map(
			HttpController._getConnectedClientView
		)
			
	getConnectedClient: (req, res) ->
		{client_id} = req.params
		ioClient = clientMap.get(client_id)
		if !ioClient
			res.sendStatus(404)
			return
		res.json(HttpController._getConnectedClientView(ioClient))
