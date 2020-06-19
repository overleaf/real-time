should = require('chai').should()
sinon = require "sinon"
SandboxedModule = require('sandboxed-module')
path = require "path"
modulePath = path.join __dirname, "../../../app/js/DrainManager"

describe "DrainManager", ->
	beforeEach ->
		@DrainManager = SandboxedModule.require modulePath, requires:
			"logger-sharelatex": @logger = log: sinon.stub()
			"./WebsocketServer": {clientMap: @clientMap = new Map()}

	describe "startDrainTimeWindow", ->
		beforeEach ->
			for i in [0..5399]
				@clientMap.set(i, {
					id: i
					emit: sinon.stub()
				})
			@DrainManager.startDrain = sinon.stub()

		it "should set a drain rate fast enough", (done)->
			@DrainManager.startDrainTimeWindow(9)
			@DrainManager.startDrain.calledWith(10).should.equal true
			done()


	describe "reconnectNClients", ->
		beforeEach ->
			@clients = {}
			for i in [0..9]
				@clientMap.set(i, @clients[i] = {
					id: i
					emit: sinon.stub()
				})

		describe "after first pass", ->
			beforeEach ->
				@DrainManager.reconnectNClients(3)
			
			it "should reconnect the first 3 clients", ->
				for i in [0..2]
					@clients[i].emit.calledWith("reconnectGracefully").should.equal true
			
			it "should not reconnect any more clients", ->
				for i in [3..9]
					@clients[i].emit.calledWith("reconnectGracefully").should.equal false
			
			describe "after second pass", ->
				beforeEach ->
					@DrainManager.reconnectNClients(3)
				
				it "should reconnect the next 3 clients", ->
					for i in [3..5]
						@clients[i].emit.calledWith("reconnectGracefully").should.equal true
				
				it "should not reconnect any more clients", ->
					for i in [6..9]
						@clients[i].emit.calledWith("reconnectGracefully").should.equal false
				
				it "should not reconnect the first 3 clients again", ->
					for i in [0..2]
						@clients[i].emit.calledOnce.should.equal true
				
				describe "after final pass", ->
					beforeEach ->
						@DrainManager.reconnectNClients(100)
				
					it "should not reconnect the first 6 clients again", ->
						for i in [0..5]
							@clients[i].emit.calledOnce.should.equal true
					
					it "should log out that it reached the end", ->
						@logger.log
							.calledWith("All clients have been told to reconnectGracefully")
							.should.equal true
