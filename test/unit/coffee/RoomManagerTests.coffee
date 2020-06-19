chai = require('chai')
expect = chai.expect
should = chai.should()
sinon = require("sinon")
modulePath = "../../../app/js/RoomManager.js"
SandboxedModule = require('sandboxed-module')
MockClient = require "./helpers/MockClient"

describe 'RoomManager', ->
	beforeEach ->
		@project_id = "project-id-123"
		@doc_id = "doc-id-456"
		@other_doc_id = "doc-id-789"
		@client = new MockClient()
		@RoomManager = SandboxedModule.require modulePath, requires:
			"settings-sharelatex": @settings = {}
			"logger-sharelatex": @logger = { log: sinon.stub(), warn: sinon.stub(), error: sinon.stub() }
			"metrics-sharelatex": @metrics = { gauge: sinon.stub() }
			"./WebsocketServer": {clientMap: @clientMap = new Map()}
		@RoomEvents = @RoomManager.eventSource()

		@RoomEvents.on 'project-active', (id) =>
			setTimeout () =>
				@RoomEvents.emit "project-subscribed-#{id}"

		@RoomEvents.on 'doc-active', (id) =>
			setTimeout () =>
				@RoomEvents.emit "doc-subscribed-#{id}"

	describe "joinProject", ->

		describe "when the project room is empty", ->

			beforeEach (done) ->
				sinon.spy(@RoomEvents, 'emit')
				sinon.spy(@RoomEvents, 'once')
				@RoomManager.joinProject @client, @project_id, done

			it "should emit a 'project-active' event with the id", ->
				@RoomEvents.emit.calledWithExactly('project-active', @project_id).should.equal true

			it "should listen for the 'project-subscribed-id' event", ->
				@RoomEvents.once.calledWith("project-subscribed-#{@project_id}").should.equal true

			it "should join the room using the id", ->
				@RoomManager._clientAlreadyInRoom(@client, @project_id).should.equal true

		describe "when there are other clients in the project room", ->
			beforeEach (done) ->
				@RoomManager.joinProject new MockClient(), @project_id, done

			beforeEach (done) ->
				sinon.spy(@RoomEvents, 'emit')
				@RoomManager.joinProject @client, @project_id, done

			it "should join the room using the id", ->
				@RoomManager._clientAlreadyInRoom(@client, @project_id).should.equal true

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false


	describe "joinDoc", ->

		describe "when the doc room is empty", ->

			beforeEach (done) ->
				sinon.spy(@RoomEvents, 'emit')
				sinon.spy(@RoomEvents, 'once')
				@RoomManager.joinDoc @client, @doc_id, done

			it "should emit a 'doc-active' event with the id", ->
				@RoomEvents.emit.calledWithExactly('doc-active', @doc_id).should.equal true

			it "should listen for the 'doc-subscribed-id' event", ->
				@RoomEvents.once.calledWith("doc-subscribed-#{@doc_id}").should.equal true

			it "should join the room using the id", ->
				@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal true

		describe "when there are other clients in the doc room", ->
			beforeEach (done) ->
				@RoomManager.joinDoc new MockClient(), @doc_id, done

			beforeEach (done) ->
				sinon.spy(@RoomEvents, 'emit')
				@RoomManager.joinDoc @client, @doc_id, done

			it "should join the room using the id", ->
				@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal true

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false


	describe "leaveDoc", ->

		describe "when doc room will be empty after this client has left", ->
			beforeEach (done) ->
				@RoomManager.joinDoc @client, @doc_id, done

			beforeEach ->
				sinon.spy(@RoomEvents, 'emit')
				@RoomManager.leaveDoc @client, @doc_id

			it "should leave the room using the id", ->
				@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal false

			it "should emit a 'doc-empty' event with the id", ->
				@RoomEvents.emit.calledWithExactly('doc-empty', @doc_id).should.equal true


		describe "when there are other clients in the doc room", ->
			beforeEach (done) ->
				@RoomManager.joinDoc new MockClient(), @doc_id, () =>
					@RoomManager.joinDoc new MockClient(), @doc_id, () =>
						@RoomManager.joinDoc @client, @doc_id, done

			beforeEach ->
				sinon.spy(@RoomEvents, 'emit')
				@RoomManager.leaveDoc @client, @doc_id

			it "should leave the room using the id", ->
				@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal false

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false

		describe "when the client is not in the doc room", ->

			beforeEach ->
				sinon.spy(@RoomEvents, 'emit')
				@RoomManager.leaveDoc @client, @doc_id

			it "should not leave the room", ->
				@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal false

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false


	describe "leaveProjectAndDocs", ->

		describe "when the client is connected to the project and multiple docs", ->

			beforeEach (done) ->
				@RoomManager.joinProject @client, @project_id, () =>
					@RoomManager.joinDoc @client, @doc_id, () =>
						@RoomManager.joinDoc @client, @other_doc_id, done

			describe "when this is the only client connected", ->

				beforeEach (done) ->
					sinon.spy(@RoomEvents, 'emit')
					@RoomManager.leaveProjectAndDocs @client
					done()

				it "should leave all the docs", ->
					@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal false
					@RoomManager._clientAlreadyInRoom(@client, @other_doc_id).should.equal false

				it "should leave the project", ->
					@RoomManager._clientAlreadyInRoom(@client, @project_id).should.equal false

				it "should emit a 'doc-empty' event with the id for each doc", ->
					@RoomEvents.emit.calledWithExactly('doc-empty', @doc_id).should.equal true
					@RoomEvents.emit.calledWithExactly('doc-empty', @other_doc_id).should.equal true

				it "should emit a 'project-empty' event with the id for the project", ->
					@RoomEvents.emit.calledWithExactly('project-empty', @project_id).should.equal true

			describe "when other clients are still connected", ->
				beforeEach (done) ->
					@RoomManager.joinProject new MockClient(), @project_id, () =>
						@RoomManager.joinProject new MockClient(), @project_id, () =>
							@RoomManager.joinDoc new MockClient(), @doc_id, () =>
								@RoomManager.joinDoc new MockClient(), @doc_id, () =>
									@RoomManager.joinDoc new MockClient(), @other_doc_id, () =>
										@RoomManager.joinDoc new MockClient(), @other_doc_id, done

				beforeEach ->
					sinon.spy(@RoomEvents, 'emit')
					@RoomManager.leaveProjectAndDocs @client

				it "should leave all the docs", ->
					@RoomManager._clientAlreadyInRoom(@client, @doc_id).should.equal false
					@RoomManager._clientAlreadyInRoom(@client, @other_doc_id).should.equal false

				it "should leave the project", ->
					@RoomManager._clientAlreadyInRoom(@client, @project_id).should.equal false

				it "should not emit any events", ->
					@RoomEvents.emit.called.should.equal false

	describe "getClientsInRoomSync", ->
		beforeEach ->
			@room = "some-project-id"

		describe "when the room does not exist", ->
			it "should return an empty array", ->
				expect(@RoomManager.getClientsInRoomSync(@room)).to.deep.equal([])

		describe "when the room exists", ->
			beforeEach (done) ->
				# room exists artificially -- we clean it up as the last client leaves
				@RoomManager.joinProject @client, @room, () =>
					@RoomManager.leaveProjectAndDocs @client, @room
					done()

			describe "when nobody is in the room", ->
				it "should return an empty array", ->
					expect(@RoomManager.getClientsInRoomSync(@room))
						.to.deep.equal([])


			describe "when a client is in the room", ->
				beforeEach (done) ->
					@RoomManager.joinProject @client, @room, done

				it "should return a list with the client", ->
					expect(@RoomManager.getClientsInRoomSync(@room))
						.to.deep.equal([@client])

			describe "when two clients are in the room and are connected", ->
				beforeEach (done) ->
					@RoomManager.joinProject @client, @room, done
				beforeEach (done) ->
					@otherClient = new MockClient()
					@RoomManager.joinProject @otherClient, @room, done

				it "should return a list with the two clients", ->
					expect(@RoomManager.getClientsInRoomSync(@room))
						.to.deep.equal([@client, @otherClient])
