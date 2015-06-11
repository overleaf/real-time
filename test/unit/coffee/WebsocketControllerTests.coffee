chai = require('chai')
should = chai.should()
sinon = require("sinon")
modulePath = "../../../app/js/WebsocketController.js"
SandboxedModule = require('sandboxed-module')
tk = require "timekeeper"

describe 'WebsocketController', ->
	beforeEach ->
		tk.freeze(new Date())
		@project_id = "project-id-123"
		@user = {
			_id: @user_id = "user-id-123"
			first_name: "James"
			last_name: "Allen"
			email: "james@example.com"
			signUpDate: new Date("2014-01-01")
			loginCount: 42
		}
		@callback = sinon.stub()
		@client =
			id: @client_id = "mock-client-id-123"
			params: {}
			set: sinon.stub()
			get: (param, cb) -> cb null, @params[param]
			join: sinon.stub()
			leave: sinon.stub()
		@WebsocketController = SandboxedModule.require modulePath, requires:
			"./WebApiManager": @WebApiManager = {}
			"./AuthorizationManager": @AuthorizationManager = {}
			"./DocumentUpdaterManager": @DocumentUpdaterManager = {}
			"./TrackChangesManager": @TrackChangesManager = {}
			"./ConnectedUsersManager": @ConnectedUsersManager = {}
			"./WebsocketLoadBalancer": @WebsocketLoadBalancer = {}
			"logger-sharelatex": @logger = { log: sinon.stub(), error: sinon.stub() }
			"metrics-sharelatex": @metrics =
				inc: sinon.stub()
				set: sinon.stub()
				
	
	afterEach ->
		tk.reset()
	
	describe "joinProject", ->
		describe "when authorised", ->
			beforeEach ->
				@client.id = "mock-client-id"
				@project = {
					name: "Test Project"
					owner: {
						_id: @owner_id = "mock-owner-id-123"
					}
				}
				@privilegeLevel = "owner"
				@ConnectedUsersManager.updateUserPosition = sinon.stub().callsArg(4)
				@WebApiManager.joinProject = sinon.stub().callsArgWith(2, null, @project, @privilegeLevel)
				@WebsocketController.joinProject @client, @user, @project_id, @callback
				
			it "should load the project from web", ->
				@WebApiManager.joinProject
					.calledWith(@project_id, @user._id)
					.should.equal true
					
			it "should join the project room", ->
				@client.join.calledWith(@project_id).should.equal true
					
			it "should set the privilege level on the client", ->
				@client.set.calledWith("privilege_level", @privilegeLevel).should.equal true
					
			it "should set the user's id on the client", ->
				@client.set.calledWith("user_id", @user._id).should.equal true
					
			it "should set the user's email on the client", ->
				@client.set.calledWith("email", @user.email).should.equal true
					
			it "should set the user's first_name on the client", ->
				@client.set.calledWith("first_name", @user.first_name).should.equal true
				
			it "should set the user's last_name on the client", ->
				@client.set.calledWith("last_name", @user.last_name).should.equal true
					
			it "should set the user's sign up date on the client", ->
				@client.set.calledWith("signup_date", @user.signUpDate).should.equal true
					
			it "should set the user's login_count on the client", ->
				@client.set.calledWith("login_count", @user.loginCount).should.equal true
				
			it "should set the connected time on the client", ->
				@client.set.calledWith("connected_time", new Date()).should.equal true
				
			it "should set the project_id on the client", ->
				@client.set.calledWith("project_id", @project_id).should.equal true
				
			it "should set the project owner id on the client", ->
				@client.set.calledWith("owner_id", @owner_id).should.equal true
				
			it "should call the callback with the project, privilegeLevel and protocolVersion", ->
				@callback
					.calledWith(null, @project, @privilegeLevel, @WebsocketController.PROTOCOL_VERSION)
					.should.equal true
					
			it "should mark the user as connected in ConnectedUsersManager", ->
				@ConnectedUsersManager.updateUserPosition
					.calledWith(@project_id, @client.id, @user, null)
					.should.equal true
					
			it "should increment the join-project metric", ->
				@metrics.inc.calledWith("editor.join-project").should.equal true
				
		describe "when not authorized", ->
			beforeEach ->
				@WebApiManager.joinProject = sinon.stub().callsArgWith(2, null, null, null)
				@WebsocketController.joinProject @client, @user, @project_id, @callback

			it "should return an error", ->
				@callback
					.calledWith(new Error("not authorized"))
					.should.equal true
	
	describe "leaveProject", ->
		beforeEach ->
			@DocumentUpdaterManager.flushProjectToMongoAndDelete = sinon.stub().callsArg(1)
			@TrackChangesManager.flushProject = sinon.stub().callsArg(1)
			@ConnectedUsersManager.markUserAsDisconnected = sinon.stub().callsArg(2)
			@WebsocketLoadBalancer.emitToRoom = sinon.stub()
			@clientsInRoom = []
			@io =
				sockets:
					clients: (room_id) =>
						if room_id != @project_id
							throw "expected room_id to be project_id"
						return @clientsInRoom
			@client.params.project_id = @project_id
			@WebsocketController.FLUSH_IF_EMPTY_DELAY = 0
			tk.reset() # Allow setTimeout to work.
			
		describe "when the project is empty", ->
			beforeEach (done) ->
				@clientsInRoom = []
				@WebsocketController.leaveProject @io, @client, done
				
			it "should end clientTracking.clientDisconnected to the project room", ->
				@WebsocketLoadBalancer.emitToRoom
					.calledWith(@project_id, "clientTracking.clientDisconnected", @client.id)
					.should.equal true
			
			it "should mark the user as disconnected", ->
				@ConnectedUsersManager.markUserAsDisconnected
					.calledWith(@project_id, @client.id)
					.should.equal true
			
			it "should flush the project in the document updater", ->
				@DocumentUpdaterManager.flushProjectToMongoAndDelete
					.calledWith(@project_id)
					.should.equal true
					
			it "should flush the changes in the track changes api", ->
				@TrackChangesManager.flushProject
					.calledWith(@project_id)
					.should.equal true
					
			it "should increment the leave-project metric", ->
				@metrics.inc.calledWith("editor.leave-project").should.equal true
			
		describe "when the project is not empty", ->
			beforeEach ->
				@clientsInRoom = ["mock-remaining-client"]
				@WebsocketController.leaveProject @io, @client
				
			it "should not flush the project in the document updater", ->
				@DocumentUpdaterManager.flushProjectToMongoAndDelete
					.called.should.equal false
			
			it "should not flush the changes in the track changes api", ->
				@TrackChangesManager.flushProject
					.called.should.equal false
						
	describe "joinDoc", ->
		beforeEach ->
			@doc_id = "doc-id-123"
			@doc_lines = ["doc", "lines"]
			@version = 42
			@ops = ["mock", "ops"]
			
			@client.params.project_id = @project_id
			
			@AuthorizationManager.assertClientCanViewProject = sinon.stub().callsArgWith(1, null)
			@DocumentUpdaterManager.getDocument = sinon.stub().callsArgWith(3, null, @doc_lines, @version, @ops)
			
		describe "with a fromVersion", ->
			beforeEach ->
				@fromVersion = 40
				@WebsocketController.joinDoc @client, @doc_id, @fromVersion, @callback
				
			it "should check that the client is authorized to view the project", ->
				@AuthorizationManager.assertClientCanViewProject
					.calledWith(@client)
					.should.equal true
					
			it "should get the document from the DocumentUpdaterManager", ->
				@DocumentUpdaterManager.getDocument
					.calledWith(@project_id, @doc_id, @fromVersion)
					.should.equal true
					
			it "should join the client to room for the doc_id", ->
				@client.join
					.calledWith(@doc_id)
					.should.equal true
					
			it "should call the callback with the lines, version and ops", ->
				@callback
					.calledWith(null, @doc_lines, @version, @ops)
					.should.equal true
					
			it "should increment the join-doc metric", ->
				@metrics.inc.calledWith("editor.join-doc").should.equal true
					
		describe "with doclines that need escaping", ->
			beforeEach ->
				@doc_lines.push ["räksmörgås"]
				@WebsocketController.joinDoc @client, @doc_id, -1, @callback
						
			it "should call the callback with the escaped lines", ->
				escaped_lines = @callback.args[0][1]
				escaped_word = escaped_lines.pop()
				escaped_word.should.equal 'rÃ¤ksmÃ¶rgÃ¥s'
				# Check that unescaping works
				decodeURIComponent(escape(escaped_word)).should.equal "räksmörgås"
				
		describe "when not authorized", ->
			beforeEach ->
				@AuthorizationManager.assertClientCanViewProject = sinon.stub().callsArgWith(1, @err = new Error("not authorized"))
				@WebsocketController.joinDoc @client, @doc_id, -1, @callback
				
			it "should call the callback with an error", ->
				@callback.calledWith(@err).should.equal true
			
			it "should not call the DocumentUpdaterManager", ->
				@DocumentUpdaterManager.getDocument.called.should.equal false
				
	describe "leaveDoc", ->
		beforeEach ->
			@doc_id = "doc-id-123"			
			@client.params.project_id = @project_id
			@WebsocketController.leaveDoc @client, @doc_id, @callback
			
		it "should remove the client from the doc_id room", ->
			@client.leave
				.calledWith(@doc_id).should.equal true
				
		it "should call the callback", ->
			@callback.called.should.equal true
			
		it "should increment the leave-doc metric", ->
			@metrics.inc.calledWith("editor.leave-doc").should.equal true
			
	describe "getConnectedUsers", ->
		beforeEach ->
			@client.params.project_id = @project_id
			@users = ["mock", "users"]
			@ConnectedUsersManager.getConnectedUsers = sinon.stub().callsArgWith(1, null, @users)
			
		describe "when authorized", ->
			beforeEach ->
				@AuthorizationManager.assertClientCanViewProject = sinon.stub().callsArgWith(1, null)
				@WebsocketController.getConnectedUsers @client, @callback
				
			it "should check that the client is authorized to view the project", ->
				@AuthorizationManager.assertClientCanViewProject
					.calledWith(@client)
					.should.equal true
					
			it "should get the connected users for the project", ->
				@ConnectedUsersManager.getConnectedUsers
					.calledWith(@project_id)
					.should.equal true
					
			it "should return the users", ->
				@callback.calledWith(null, @users).should.equal true
				
			it "should increment the get-connected-users metric", ->
				@metrics.inc.calledWith("editor.get-connected-users").should.equal true
			
		describe "when not authorized", ->
			beforeEach ->
				@AuthorizationManager.assertClientCanViewProject = sinon.stub().callsArgWith(1, @err = new Error("not authorized"))
				@WebsocketController.getConnectedUsers @client, @callback
					
			it "should not get the connected users for the project", ->
				@ConnectedUsersManager.getConnectedUsers
					.called
					.should.equal false
					
			it "should return an error", ->
				@callback.calledWith(@err).should.equal true
				
	describe "updateClientPosition", ->
		beforeEach ->
			@WebsocketLoadBalancer.emitToRoom = sinon.stub()
			@ConnectedUsersManager.updateUserPosition = sinon.stub().callsArgWith(4)
			@AuthorizationManager.assertClientCanViewProject = sinon.stub().callsArgWith(1, null)
			@update = {
				doc_id: @doc_id = "doc-id-123"
				row: @row = 42
				column: @column = 37
			}

		describe "with a logged in user", ->
			beforeEach ->
				@clientParams = {
					project_id: @project_id
					first_name: @first_name = "Douglas"
					last_name: @last_name = "Adams"
					email: @email = "joe@example.com"
					user_id: @user_id = "user-id-123"
				}
				@client.get = (param, callback) => callback null, @clientParams[param]
				@WebsocketController.updateClientPosition @client, @update

				@populatedCursorData = 
					doc_id: @doc_id,
					id: @client.id
					name: "#{@first_name} #{@last_name}"
					row: @row
					column: @column
					email: @email
					user_id: @user_id

			it "should send the update to the project room with the user's name", ->
				@WebsocketLoadBalancer.emitToRoom.calledWith(@project_id, "clientTracking.clientUpdated", @populatedCursorData).should.equal true

			it "should send the  cursor data to the connected user manager", (done)->
				@ConnectedUsersManager.updateUserPosition.calledWith(@project_id, @client.id, {
					_id: @user_id,
					email: @email,
					first_name: @first_name,
					last_name: @last_name
				}, {
					row: @row
					column: @column
					doc_id: @doc_id
				}).should.equal true
				done()
				
			it "should increment the update-client-position metric at 0.1 frequency", ->
				@metrics.inc.calledWith("editor.update-client-position", 0.1).should.equal true

		describe "with an anonymous user", ->
			beforeEach ->
				@clientParams = {
					project_id: @project_id
				}
				@client.get = (param, callback) => callback null, @clientParams[param]
				@WebsocketController.updateClientPosition @client, @update

			it "should send the update to the project room with an anonymous name", ->
				@WebsocketLoadBalancer.emitToRoom
					.calledWith(@project_id, "clientTracking.clientUpdated", {
						doc_id: @doc_id,
						id: @client.id
						name: "Anonymous"
						row: @row
						column: @column
					})
					.should.equal true
				
			it "should not send cursor data to the connected user manager", (done)->
				@ConnectedUsersManager.updateUserPosition.called.should.equal false
				done()

	describe "applyOtUpdate", ->
		beforeEach ->
			@update = {op: [{p: 12, t: "foo"}]}
			@client.params.user_id = @user_id
			@client.params.project_id = @project_id
			@AuthorizationManager.assertClientCanEditProject = sinon.stub().callsArg(1)
			@DocumentUpdaterManager.queueChange = sinon.stub().callsArg(3)

		describe "succesfully", ->
			beforeEach ->
				@WebsocketController.applyOtUpdate @client, @doc_id, @update, @callback

			it "should set the source of the update to the client id", ->
				@update.meta.source.should.equal @client.id

			it "should set the user_id of the update to the user id", ->
				@update.meta.user_id.should.equal @user_id

			it "should queue the update", ->
				@DocumentUpdaterManager.queueChange
					.calledWith(@project_id, @doc_id, @update)
					.should.equal true

			it "should call the callback", ->
				@callback.called.should.equal true

			it "should update the active users metric", ->
				@metrics.set.calledWith("editor.active-users", @user_id).should.equal true
			
			it "should update the active projects metric", ->
				@metrics.set.calledWith("editor.active-projects", @project_id).should.equal true
			
			it "should increment the doc updates", ->
				@metrics.inc.calledWith("editor.doc-update").should.equal true

		describe "unsuccessfully", ->
			beforeEach ->
				@client.disconnect = sinon.stub()
				@DocumentUpdaterManager.queueChange = sinon.stub().callsArgWith(3, @error = new Error("Something went wrong"))
				@WebsocketController.applyOtUpdate @client, @doc_id, @update, @callback

			it "should disconnect the client", ->
				@client.disconnect.called.should.equal true

			it "should log an error", ->
				@logger.error.called.should.equal true

			it "should call the callback with the error", ->
				@callback.calledWith(@error).should.equal true
				
		describe "when not authorized", ->
			beforeEach ->
				@client.disconnect = sinon.stub()
				@AuthorizationManager.assertClientCanEditProject = sinon.stub().callsArgWith(1, @error = new Error("not authorized"))
				@WebsocketController.applyOtUpdate @client, @doc_id, @update, @callback

			# This happens in a setTimeout to allow the client a chance to receive the error first.
			# I'm not sure how to unit test, but it is acceptance tested.
			# it "should disconnect the client", ->
			# 	@client.disconnect.called.should.equal true

			it "should log an error", ->
				@logger.error.called.should.equal true

			it "should call the callback with the error", ->
				@callback.calledWith(@error).should.equal true

		describe "with UTF-16 surrogate pairs in the update", ->
			beforeEach ->
				@update = {op: [{p: 12, i: "foo"}, {p: 42, i: "\uD835\uDC00"}]}
				@WebsocketController.applyOtUpdate @client, @doc_id, @update, @callback

			it "should queue the update but with surrogate pairs removed", ->
				@DocumentUpdaterManager.queueChange
					.calledWith(@project_id, @doc_id, @update)
					.should.equal true
				
				# \uFFFD is 'replacement character'
				@update.op[1].i.should.equal "\uFFFD\uFFFD"
			