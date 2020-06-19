sinon = require('sinon')

idCounter = 0

module.exports = class MockClient
	constructor: (ol_context) ->
		@ol_context = ol_context || {}
		@rooms = []
		@join = sinon.stub()
		@emit = sinon.stub()
		@disconnect = sinon.stub()
		@id = idCounter++
		@publicId = idCounter++
	disconnect: () ->
