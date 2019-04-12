SandboxedModule = require('sandboxed-module')
sinon = require('sinon')
require('chai').should()
modulePath = require('path').join __dirname, '../../../app/js/WebsocketLoadBalancer'

describe "WebsocketLoadBalancer", ->
	beforeEach ->
		@rclient = {}
		@WebsocketLoadBalancer = SandboxedModule.require modulePath, requires:
			"redis-sharelatex": 
				createClient: () => @rclient
			"logger-sharelatex": @logger = { log: sinon.stub(), error: sinon.stub() }
			"./SafeJsonParse": @SafeJsonParse =
				parse: (data, cb) => cb null, JSON.parse(data)
			"./EventLogger": {checkEventOrder: sinon.stub()}
		@io = {}
		@WebsocketLoadBalancer.rclientPub = publish: sinon.stub()
		@WebsocketLoadBalancer.rclientSub =
			subscribe: sinon.stub()
			on: sinon.stub()
		
		@room_id = "room-id"
		@message = "message-to-editor"
		@payload = ["argument one", 42]

	describe "emitToRoom", ->
		beforeEach ->
			@WebsocketLoadBalancer.emitToRoom(@room_id, @message, @payload...)

		it "should publish the message to redis", ->
			@WebsocketLoadBalancer.rclientPub.publish
				.calledWith("editor-events", JSON.stringify(
					room_id: @room_id,
					message: @message
					payload: @payload
				))
				.should.equal true

	describe "emitToAll", ->
		beforeEach ->
			@WebsocketLoadBalancer.emitToRoom = sinon.stub()
			@WebsocketLoadBalancer.emitToAll @message, @payload...

		it "should emit to the room 'all'", ->
			@WebsocketLoadBalancer.emitToRoom
				.calledWith("all", @message, @payload...)
				.should.equal true
			
	describe "listenForEditorEvents", ->
		beforeEach ->
			@WebsocketLoadBalancer._processEditorEvent = sinon.stub()
			@WebsocketLoadBalancer.listenForEditorEvents()

		it "should subscribe to the editor-events channel", ->
			@WebsocketLoadBalancer.rclientSub.subscribe
				.calledWith("editor-events")
				.should.equal true

		it "should process the events with _processEditorEvent", ->
			@WebsocketLoadBalancer.rclientSub.on
				.calledWith("message", sinon.match.func)
				.should.equal true

	describe "_processEditorEvent", ->
		describe "with bad JSON", ->
			beforeEach ->
				@SafeJsonParse.parse = sinon.stub().callsArgWith 1, new Error("oops")
				@WebsocketLoadBalancer._processEditorEvent(@io, "editor-events", "blah")
			
			it "should log an error", ->
				@logger.error.called.should.equal true

		describe "with a designated room", ->
			beforeEach ->
				@io.sockets =
					clients: sinon.stub().returns([
						{id: 'client-id-1', emit: @emit1 = sinon.stub()}
						{id: 'client-id-2', emit: @emit2 = sinon.stub()}
						{id: 'client-id-1', emit: @emit3 = sinon.stub()} # duplicate client
					])
				data = JSON.stringify
					room_id: @room_id
					message: @message
					payload: @payload
				@WebsocketLoadBalancer._processEditorEvent(@io, "editor-events", data)

			it "should send the message to all (unique) clients in the room", ->
				@io.sockets.clients
					.calledWith(@room_id)
					.should.equal true
				@emit1.calledWith(@message, @payload...).should.equal true
				@emit2.calledWith(@message, @payload...).should.equal true
				@emit3.called.should.equal false # duplicate client should be ignored

		describe "when emitting to all", ->
			beforeEach ->
				@io.sockets =
					emit: @emit = sinon.stub()
				data = JSON.stringify
					room_id: "all"
					message: @message
					payload: @payload
				@WebsocketLoadBalancer._processEditorEvent(@io, "editor-events", data)

			it "should send the message to all clients", ->
				@emit.calledWith(@message, @payload...).should.equal true
			
