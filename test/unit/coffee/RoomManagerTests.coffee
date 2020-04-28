chai = require('chai')
expect = chai.expect
should = chai.should()
sinon = require("sinon")
modulePath = "../../../app/js/RoomManager.js"
SandboxedModule = require('sandboxed-module')

describe 'RoomManager', ->
	beforeEach ->
		@project_id = "project-id-123"
		@doc_id = "doc-id-456"
		@other_doc_id = "doc-id-789"
		@client = {namespace: {name: ''}, id: "first-client"}
		@RoomManager = SandboxedModule.require modulePath, requires:
			"settings-sharelatex": @settings = {}
			"logger-sharelatex": @logger = { log: sinon.stub(), warn: sinon.stub(), error: sinon.stub() }
			"metrics-sharelatex": @metrics = { gauge: sinon.stub() }
		@RoomManager._clientsInRoom = sinon.stub()
		@RoomManager._clientAlreadyInRoom = sinon.stub()
		@RoomEvents = @RoomManager.eventSource()
		sinon.spy(@RoomEvents, 'emit')
		sinon.spy(@RoomEvents, 'once')

	describe "joinProject", ->

		describe "when the project room is empty", ->

			beforeEach (done) ->
				@RoomManager._clientsInRoom
					.withArgs(@client, @project_id)
					.onFirstCall().yields(0)
				@client.join = sinon.stub()
				@callback = sinon.stub()
				@RoomEvents.on 'project-active', (id) =>
					setTimeout () =>
						@RoomEvents.emit "project-subscribed-#{id}"
					, 100
				@RoomManager.joinProject @client, @project_id, (err) =>
					@callback(err)
					done()

			it "should emit a 'project-active' event with the id", ->
				@RoomEvents.emit.calledWithExactly('project-active', @project_id).should.equal true

			it "should listen for the 'project-subscribed-id' event", ->
				@RoomEvents.once.calledWith("project-subscribed-#{@project_id}").should.equal true

			it "should join the room using the id", ->
				@client.join.calledWithExactly(@project_id).should.equal true

		describe "when there are other clients in the project room", ->

			beforeEach ->
				@RoomManager._clientsInRoom
					.withArgs(@client, @project_id)
					.onFirstCall().yields(123)
					.onSecondCall().yields(124)
				@client.join = sinon.stub()
				@RoomManager.joinProject @client, @project_id

			it "should join the room using the id", ->
				@client.join.called.should.equal true

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false


	describe "joinDoc", ->

		describe "when the doc room is empty", ->

			beforeEach (done) ->
				@RoomManager._clientsInRoom
					.withArgs(@client, @doc_id)
					.onFirstCall().yields(0)
				@client.join = sinon.stub()
				@callback = sinon.stub()
				@RoomEvents.on 'doc-active', (id) =>
					setTimeout () =>
						@RoomEvents.emit "doc-subscribed-#{id}"
					, 100
				@RoomManager.joinDoc @client, @doc_id, (err) =>
					@callback(err)
					done()

			it "should emit a 'doc-active' event with the id", ->
				@RoomEvents.emit.calledWithExactly('doc-active', @doc_id).should.equal true

			it "should listen for the 'doc-subscribed-id' event", ->
				@RoomEvents.once.calledWith("doc-subscribed-#{@doc_id}").should.equal true

			it "should join the room using the id", ->
				@client.join.calledWithExactly(@doc_id).should.equal true

		describe "when there are other clients in the doc room", ->

			beforeEach ->
				@RoomManager._clientsInRoom
					.withArgs(@client, @doc_id)
					.onFirstCall().yields(123)
					.onSecondCall().yields(124)
				@client.join = sinon.stub()
				@RoomManager.joinDoc @client, @doc_id

			it "should join the room using the id", ->
				@client.join.called.should.equal true

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false


	describe "leaveDoc", ->

		describe "when doc room will be empty after this client has left", ->

			beforeEach ->
				@RoomManager._clientAlreadyInRoom
					.withArgs(@client, @doc_id)
					.returns(true)
				@RoomManager._clientsInRoom
					.withArgs(@client, @doc_id)
					.onCall(0).yields(0)
				@client.leave = sinon.stub()
				@RoomManager.leaveDoc @client, @doc_id

			it "should leave the room using the id", ->
				@client.leave.calledWithExactly(@doc_id).should.equal true

			it "should emit a 'doc-empty' event with the id", ->
				@RoomEvents.emit.calledWithExactly('doc-empty', @doc_id).should.equal true


		describe "when there are other clients in the doc room", ->

			beforeEach ->
				@RoomManager._clientAlreadyInRoom
					.withArgs(@client, @doc_id)
					.returns(true)
				@RoomManager._clientsInRoom
					.withArgs(@client, @doc_id)
					.onCall(0).yields(123)
				@client.leave = sinon.stub()
				@RoomManager.leaveDoc @client, @doc_id

			it "should leave the room using the id", ->
				@client.leave.calledWithExactly(@doc_id).should.equal true

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false

		describe "when the client is not in the doc room", ->

			beforeEach ->
				@RoomManager._clientAlreadyInRoom
					.withArgs(@client, @doc_id)
					.returns(false)
				@RoomManager._clientsInRoom
					.withArgs(@client, @doc_id)
					.onCall(0).yields(0)
				@client.leave = sinon.stub()
				@RoomManager.leaveDoc @client, @doc_id

			it "should not leave the room", ->
				@client.leave.called.should.equal false

			it "should not emit any events", ->
				@RoomEvents.emit.called.should.equal false


	describe "leaveProjectAndDocs", ->

		describe "when the client is connected to the project and multiple docs", ->

			beforeEach ->
				@RoomManager._roomsClientIsIn = sinon.stub().returns [@project_id, @doc_id, @other_doc_id]
				@client.join = sinon.stub()
				@client.leave = sinon.stub()

			describe "when this is the only client connected", ->

				beforeEach (done) ->
					# first call is for the join,
					# second for the leave
					@RoomManager._clientsInRoom
						.withArgs(@client, @doc_id)
						.onCall(0).yields(0)
						.onCall(1).yields(0)
					@RoomManager._clientsInRoom
						.withArgs(@client, @other_doc_id)
						.onCall(0).yields(0)
						.onCall(1).yields(0)
					@RoomManager._clientsInRoom
						.withArgs(@client, @project_id)
						.onCall(0).yields(0)
						.onCall(1).yields(0)
					@RoomManager._clientAlreadyInRoom
						.withArgs(@client, @doc_id)
						.returns(true)
						.withArgs(@client, @other_doc_id)
						.returns(true)
						.withArgs(@client, @project_id)
						.returns(true)
					@RoomEvents.on 'project-active', (id) =>
						setTimeout () =>
							@RoomEvents.emit "project-subscribed-#{id}"
						, 100
					@RoomEvents.on 'doc-active', (id) =>
						setTimeout () =>
							@RoomEvents.emit "doc-subscribed-#{id}"
						, 100
					# put the client in the rooms
					@RoomManager.joinProject @client, @project_id, () =>
						@RoomManager.joinDoc @client, @doc_id, () =>
							@RoomManager.joinDoc @client, @other_doc_id, () =>
								# now leave the project
								@RoomManager.leaveProjectAndDocs @client
								done()

				it "should leave all the docs", ->
					@client.leave.calledWithExactly(@doc_id).should.equal true
					@client.leave.calledWithExactly(@other_doc_id).should.equal true

				it "should leave the project", ->
					@client.leave.calledWithExactly(@project_id).should.equal true

				it "should emit a 'doc-empty' event with the id for each doc", ->
					@RoomEvents.emit.calledWithExactly('doc-empty', @doc_id).should.equal true
					@RoomEvents.emit.calledWithExactly('doc-empty', @other_doc_id).should.equal true

				it "should emit a 'project-empty' event with the id for the project", ->
					@RoomEvents.emit.calledWithExactly('project-empty', @project_id).should.equal true

			describe "when other clients are still connected", ->

				beforeEach ->
					@RoomManager._clientsInRoom
						.withArgs(@client, @doc_id)
						.onFirstCall().returns(123)
						.onSecondCall().returns(122)
					@RoomManager._clientsInRoom
						.withArgs(@client, @other_doc_id)
						.onFirstCall().returns(123)
						.onSecondCall().returns(122)
					@RoomManager._clientsInRoom
						.withArgs(@client, @project_id)
						.onFirstCall().returns(123)
						.onSecondCall().returns(122)
					@RoomManager._clientAlreadyInRoom
						.withArgs(@client, @doc_id)
						.returns(true)
						.withArgs(@client, @other_doc_id)
						.returns(true)
						.withArgs(@client, @project_id)
						.returns(true)
					@RoomManager.leaveProjectAndDocs @client

				it "should leave all the docs", ->
					@client.leave.calledWithExactly(@doc_id).should.equal true
					@client.leave.calledWithExactly(@other_doc_id).should.equal true

				it "should leave the project", ->
					@client.leave.calledWithExactly(@project_id).should.equal true

				it "should not emit any events", ->
					@RoomEvents.emit.called.should.equal false

	describe "getClientsInRoomSync", ->
		beforeEach ->
			@io = {
				sockets: {
					adapter: {
						rooms: {},
						nsp: {
							connected: {}
						}
					}
				}
			}
			@room = "some-project-id"

		describe "when the room does not exist", ->
			it "should return an empty array", ->
				expect(@RoomManager.getClientsInRoomSync(@io, @room)).to.deep.equal([])

		describe "when the room exists", ->
			beforeEach ->
				@io.sockets.adapter.rooms[@room] = {sockets: {}}

			describe "when nobody is in the room", ->
				it "should return an empty array", ->
					expect(@RoomManager.getClientsInRoomSync(@io, @room))
						.to.deep.equal([])


			describe "when a client is in the room", ->
				beforeEach ->
					@clientId = 'some-client-id'
					@io.sockets.adapter.rooms[@room].sockets[@clientId] = true

				describe "when the client is not connected", ->
					it "should return an empty array", ->
						expect(@RoomManager.getClientsInRoomSync(@io, @room))
							.to.deep.equal([])

				describe "when the client is connected", ->
					beforeEach ->
						@io.sockets.adapter.nsp.connected[@clientId] = { mock: 'client' }

					it "should return a list with the clientId", ->
						expect(@RoomManager.getClientsInRoomSync(@io, @room))
							.to.deep.equal([@clientId])

			describe "when two clients are in the room and are connected", ->
				beforeEach ->
					@clientId = 'some-client-id'
					@io.sockets.adapter.rooms[@room].sockets[@clientId] = true
					@clientId2 = 'some-client-id-2'
					@io.sockets.adapter.rooms[@room].sockets[@clientId2] = true
					@io.sockets.adapter.nsp.connected[@clientId] = { mock: 'client1' }
					@io.sockets.adapter.nsp.connected[@clientId2] = { mock: 'client1' }

				it "should return a list with the two clientIds", ->
					expect(@RoomManager.getClientsInRoomSync(@io, @room))
						.to.deep.equal([@clientId, @clientId2])
