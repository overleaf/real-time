/* eslint-disable
    camelcase,
    handle-callback-err,
    no-return-assign,
    no-unused-vars,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */

const SandboxedModule = require('sandboxed-module')
const assert = require('assert')
const path = require('path')
const sinon = require('sinon')
const modulePath = path.join(__dirname, '../../../app/js/ConnectedUsersManager')
const { expect } = require('chai')
const tk = require('timekeeper')

describe('ConnectedUsersManager', function () {
  beforeEach(function () {
    this.settings = {
      redis: {
        realtime: {
          key_schema: {
            clientsInProject({ project_id }) {
              return `clients_in_project:${project_id}`
            },
            connectedUser({ project_id, client_id }) {
              return `connected_user:${project_id}:${client_id}`
            }
          }
        }
      }
    }
    this.rClient = {
      auth() {},
      setex: sinon.stub(),
      sadd: sinon.stub(),
      get: sinon.stub(),
      srem: sinon.stub(),
      del: sinon.stub(),
      smembers: sinon.stub(),
      expire: sinon.stub(),
      hset: sinon.stub(),
      hgetall: sinon.stub(),
      exec: sinon.stub(),
      pipeline: () => {
        return this.rClient
      },
      multi: () => {
        return this.rClient
      }
    }
    tk.freeze(new Date())

    this.ConnectedUsersManager = SandboxedModule.require(modulePath, {
      requires: {
        'settings-sharelatex': this.settings,
        '@overleaf/redis-wrapper': {
          createClient: () => {
            return this.rClient
          }
        }
      }
    })
    this.client_id = '32132132'
    this.client = {
      publicId: this.client_id,
      ol_context: {}
    }
    this.project_id = 'dskjh2u21321'
    this.user = {
      _id: 'user-id-123',
      first_name: 'Joe',
      last_name: 'Bloggs',
      email: 'joe@example.com'
    }
    this.userSerialized = JSON.stringify({
      user_id: this.user._id,
      first_name: this.user.first_name,
      last_name: this.user.last_name,
      email: this.user.email
    })
    return (this.cursorData = {
      row: 12,
      column: 9,
      doc_id: '53c3b8c85fee64000023dc6e'
    })
  })

  afterEach(function () {
    return tk.reset()
  })

  describe('updateUserPosition', function () {
    beforeEach(function () {
      return this.rClient.exec.callsArgWith(0)
    })

    it('should set a single key with all user details', function (done) {
      return this.ConnectedUsersManager.updateUserPosition(
        this.project_id,
        this.client,
        this.user,
        null,
        (err) => {
          this.rClient.hset
            .calledWith(
              `connected_user:${this.project_id}:${this.client_id}`,
              'user',
              this.userSerialized
            )
            .should.equal(true)
          return done()
        }
      )
    })

    it('should push the client_id on to the project list', function (done) {
      return this.ConnectedUsersManager.updateUserPosition(
        this.project_id,
        this.client,
        this.user,
        null,
        (err) => {
          this.rClient.sadd
            .calledWith(`clients_in_project:${this.project_id}`, this.client_id)
            .should.equal(true)
          return done()
        }
      )
    })

    it('should add a ttl to the project set so it stays clean', function (done) {
      return this.ConnectedUsersManager.updateUserPosition(
        this.project_id,
        this.client,
        this.user,
        null,
        (err) => {
          this.rClient.expire
            .calledWith(
              `clients_in_project:${this.project_id}`,
              24 * 4 * 60 * 60
            )
            .should.equal(true)
          return done()
        }
      )
    })

    it('should add a ttl to the connected user so it stays clean', function (done) {
      return this.ConnectedUsersManager.updateUserPosition(
        this.project_id,
        this.client,
        this.user,
        null,
        (err) => {
          this.rClient.expire
            .calledWith(
              `connected_user:${this.project_id}:${this.client_id}`,
              60 * 15
            )
            .should.equal(true)
          return done()
        }
      )
    })

    it('should set the cursor position when provided', function (done) {
      return this.ConnectedUsersManager.updateUserPosition(
        this.project_id,
        this.client,
        this.user,
        this.cursorData,
        (err) => {
          this.rClient.hset
            .calledWith(
              `connected_user:${this.project_id}:${this.client_id}`,
              'cursorData',
              JSON.stringify(this.cursorData)
            )
            .should.equal(true)
          return done()
        }
      )
    })

    describe('when recently updated', function () {
      beforeEach(function (done) {
        this.rClient.expire
          .withArgs(`clients_in_project:${this.project_id}`)
          .yields(null)
        this.rClient.expire
          .withArgs(`connected_user:${this.project_id}:${this.client_id}`)
          .yields(null)
        this.ConnectedUsersManager.updateUserPosition(
          this.project_id,
          this.client,
          this.user,
          null,
          done
        )
      })
      beforeEach(function () {
        this.rClient.sadd.reset()
        this.rClient.hset.reset()
        this.rClient.expire.reset()
      })

      it('should not push the client_id on to the project list', function (done) {
        return this.ConnectedUsersManager.updateUserPosition(
          this.project_id,
          this.client,
          this.user,
          null,
          (err) => {
            this.rClient.sadd
              .calledWith(
                `clients_in_project:${this.project_id}`,
                this.client_id
              )
              .should.equal(false)
            done()
          }
        )
      })

      it('should not update user details', function (done) {
        this.ConnectedUsersManager.updateUserPosition(
          this.project_id,
          this.client,
          this.user,
          null,
          (err) => {
            this.rClient.hset
              .calledWith(
                `connected_user:${this.project_id}:${this.client_id}`,
                'user',
                this.userSerialized
              )
              .should.equal(false)
            done()
          }
        )
      })

      it('should not bump the ttl again', function (done) {
        this.ConnectedUsersManager.updateUserPosition(
          this.project_id,
          this.client,
          this.user,
          null,
          (err) => {
            this.rClient.expire
              .calledWith(`connected_user:${this.project_id}:${this.client_id}`)
              .should.equal(false)
            done()
          }
        )
      })
    })

    describe('when recently refreshed', function () {
      beforeEach(function () {
        this.rClient.expire
          .withArgs(`connected_user:${this.project_id}:${this.client_id}`)
          .yields(null)
        this.ConnectedUsersManager.refreshClient(this.project_id, this.client)
        this.rClient.expire.reset()
      })

      it('should not update user details', function (done) {
        this.ConnectedUsersManager.updateUserPosition(
          this.project_id,
          this.client,
          this.user,
          null,
          (err) => {
            this.rClient.hset
              .calledWith(
                `connected_user:${this.project_id}:${this.client_id}`,
                'user',
                this.userSerialized
              )
              .should.equal(false)
            done()
          }
        )
      })

      it('should not bump the ttl again', function (done) {
        this.ConnectedUsersManager.updateUserPosition(
          this.project_id,
          this.client,
          this.user,
          null,
          (err) => {
            this.rClient.expire
              .calledWith(`connected_user:${this.project_id}:${this.client_id}`)
              .should.equal(false)
            done()
          }
        )
      })
    })
  })

  describe('markUserAsDisconnected', function () {
    beforeEach(function () {
      return this.rClient.exec.callsArgWith(0)
    })

    it('should remove the user from the set', function (done) {
      return this.ConnectedUsersManager.markUserAsDisconnected(
        this.project_id,
        this.client_id,
        (err) => {
          this.rClient.srem
            .calledWith(`clients_in_project:${this.project_id}`, this.client_id)
            .should.equal(true)
          return done()
        }
      )
    })

    it('should delete the connected_user string', function (done) {
      return this.ConnectedUsersManager.markUserAsDisconnected(
        this.project_id,
        this.client_id,
        (err) => {
          this.rClient.del
            .calledWith(`connected_user:${this.project_id}:${this.client_id}`)
            .should.equal(true)
          return done()
        }
      )
    })

    return it('should add a ttl to the connected user set so it stays clean', function (done) {
      return this.ConnectedUsersManager.markUserAsDisconnected(
        this.project_id,
        this.client_id,
        (err) => {
          this.rClient.expire
            .calledWith(
              `clients_in_project:${this.project_id}`,
              24 * 4 * 60 * 60
            )
            .should.equal(true)
          return done()
        }
      )
    })
  })

  describe('_getConnectedUser', function () {
    it('should return a connected user if there is a user object', function (done) {
      const cursorData = JSON.stringify({ cursorData: { row: 1 } })
      this.rClient.hgetall.callsArgWith(1, null, {
        connected_at: new Date(),
        user: this.userSerialized,
        cursorData
      })
      return this.ConnectedUsersManager._getConnectedUser(
        this.project_id,
        this.client_id,
        (err, result) => {
          result.connected.should.equal(true)
          result.client_id.should.equal(this.client_id)
          result.user_id.should.equal(this.user._id)
          result.first_name.should.equal(this.user.first_name)
          result.last_name.should.equal(this.user.last_name)
          result.email.should.equal(this.user.email)
          return done()
        }
      )
    })

    it('should return a not connected user if there is no object', function (done) {
      this.rClient.hgetall.callsArgWith(1, null, null)
      return this.ConnectedUsersManager._getConnectedUser(
        this.project_id,
        this.client_id,
        (err, result) => {
          result.connected.should.equal(false)
          result.client_id.should.equal(this.client_id)
          return done()
        }
      )
    })

    return it('should return a not connected user if there is an empty object', function (done) {
      this.rClient.hgetall.callsArgWith(1, null, {})
      return this.ConnectedUsersManager._getConnectedUser(
        this.project_id,
        this.client_id,
        (err, result) => {
          result.connected.should.equal(false)
          result.client_id.should.equal(this.client_id)
          return done()
        }
      )
    })
  })

  return describe('getConnectedUsers', function () {
    beforeEach(function () {
      this.users = ['1234', '5678', '9123', '8234']
      this.rClient.smembers.callsArgWith(1, null, this.users)
      this.ConnectedUsersManager._getConnectedUser = sinon.stub()
      this.ConnectedUsersManager._getConnectedUser
        .withArgs(this.project_id, this.users[0])
        .callsArgWith(2, null, {
          connected: true,
          client_id: this.users[0]
        })
      this.ConnectedUsersManager._getConnectedUser
        .withArgs(this.project_id, this.users[1])
        .callsArgWith(2, null, {
          connected: false,
          client_id: this.users[1]
        })
      this.ConnectedUsersManager._getConnectedUser
        .withArgs(this.project_id, this.users[2])
        .callsArgWith(2, null, {
          connected: true,
          client_id: this.users[2]
        })
      return this.ConnectedUsersManager._getConnectedUser
        .withArgs(this.project_id, this.users[3])
        .callsArgWith(2, null, {
          connected: true,
          client_id: this.users[3]
        })
    })

    it('should return all the users which are still in redis', function (done) {
      return this.ConnectedUsersManager.getConnectedUsers(
        this.project_id,
        (err, users) => {
          users.length.should.equal(3)
          users[0].should.deep.equal({
            client_id: this.users[0],
            connected: true
          })
          users[1].should.deep.equal({
            client_id: this.users[2],
            connected: true
          })
          users[2].should.deep.equal({
            client_id: this.users[3],
            connected: true
          })
          return done()
        }
      )
    })
  })
})
