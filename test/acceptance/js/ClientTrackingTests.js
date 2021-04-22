/* eslint-disable
    camelcase,
    handle-callback-err,
    no-unused-vars,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
const { expect } = require('chai')

const RealTimeClient = require('./helpers/RealTimeClient')
const MockWebServer = require('./helpers/MockWebServer')
const FixturesManager = require('./helpers/FixturesManager')

const async = require('async')

const Settings = require('settings-sharelatex')
const redis = require('@overleaf/redis-wrapper')
const Keys = Settings.redis.realtime.key_schema
const rclient = redis.createClient(Settings.redis.realtime)

describe('clientTracking', function () {
  describe('when a client updates its cursor location', function () {
    before(function (done) {
      return async.series(
        [
          (cb) => {
            return FixturesManager.setUpProject(
              {
                privilegeLevel: 'owner',
                project: { name: 'Test Project' }
              },
              (error, { user_id, project_id }) => {
                this.user_id = user_id
                this.project_id = project_id
                return cb()
              }
            )
          },

          (cb) => {
            return FixturesManager.setUpDoc(
              this.project_id,
              { lines: this.lines, version: this.version, ops: this.ops },
              (e, { doc_id }) => {
                this.doc_id = doc_id
                return cb(e)
              }
            )
          },

          (cb) => {
            this.clientA = RealTimeClient.connect()
            return this.clientA.on('connectionAccepted', cb)
          },

          (cb) => {
            this.clientB = RealTimeClient.connect()
            return this.clientB.on('connectionAccepted', cb)
          },

          (cb) => {
            return this.clientA.emit(
              'joinProject',
              {
                project_id: this.project_id
              },
              cb
            )
          },

          (cb) => {
            return this.clientA.emit('joinDoc', this.doc_id, cb)
          },

          (cb) => {
            return this.clientB.emit(
              'joinProject',
              {
                project_id: this.project_id
              },
              cb
            )
          },

          (cb) => {
            this.updates = []
            this.clientB.on('clientTracking.clientUpdated', (data) => {
              return this.updates.push(data)
            })

            return this.clientA.emit(
              'clientTracking.updatePosition',
              {
                row: (this.row = 42),
                column: (this.column = 36),
                doc_id: this.doc_id
              },
              (error) => {
                if (error != null) {
                  throw error
                }
                return setTimeout(cb, 300)
              }
            )
          } // Give the message a chance to reach client B.
        ],
        done
      )
    })

    it('should tell other clients about the update', function () {
      return this.updates.should.deep.equal([
        {
          row: this.row,
          column: this.column,
          doc_id: this.doc_id,
          id: this.clientA.publicId,
          user_id: this.user_id,
          name: 'Joe Bloggs'
        }
      ])
    })

    return it('should record the update in getConnectedUsers', function (done) {
      return this.clientB.emit(
        'clientTracking.getConnectedUsers',
        (error, users) => {
          for (const user of Array.from(users)) {
            if (user.client_id === this.clientA.publicId) {
              expect(user.cursorData).to.deep.equal({
                row: this.row,
                column: this.column,
                doc_id: this.doc_id
              })
              return done()
            }
          }
          throw new Error('user was never found')
        }
      )
    })
  })

  describe('when an anonymous client updates its cursor location', function () {
    before(function (done) {
      return async.series(
        [
          (cb) => {
            return FixturesManager.setUpProject(
              {
                privilegeLevel: 'owner',
                project: { name: 'Test Project' },
                publicAccess: 'readAndWrite'
              },
              (error, { user_id, project_id }) => {
                this.user_id = user_id
                this.project_id = project_id
                return cb()
              }
            )
          },

          (cb) => {
            return FixturesManager.setUpDoc(
              this.project_id,
              { lines: this.lines, version: this.version, ops: this.ops },
              (e, { doc_id }) => {
                this.doc_id = doc_id
                return cb(e)
              }
            )
          },

          (cb) => {
            this.clientA = RealTimeClient.connect()
            return this.clientA.on('connectionAccepted', cb)
          },

          (cb) => {
            return this.clientA.emit(
              'joinProject',
              {
                project_id: this.project_id
              },
              cb
            )
          },

          (cb) => {
            return RealTimeClient.setSession({}, cb)
          },

          (cb) => {
            this.anonymous = RealTimeClient.connect()
            return this.anonymous.on('connectionAccepted', cb)
          },

          (cb) => {
            return this.anonymous.emit(
              'joinProject',
              {
                project_id: this.project_id
              },
              cb
            )
          },

          (cb) => {
            return this.anonymous.emit('joinDoc', this.doc_id, cb)
          },

          (cb) => {
            this.updates = []
            this.clientA.on('clientTracking.clientUpdated', (data) => {
              return this.updates.push(data)
            })

            return this.anonymous.emit(
              'clientTracking.updatePosition',
              {
                row: (this.row = 42),
                column: (this.column = 36),
                doc_id: this.doc_id
              },
              (error) => {
                if (error != null) {
                  throw error
                }
                return setTimeout(cb, 300)
              }
            )
          } // Give the message a chance to reach client B.
        ],
        done
      )
    })

    return it('should tell other clients about the update', function () {
      return this.updates.should.deep.equal([
        {
          row: this.row,
          column: this.column,
          doc_id: this.doc_id,
          id: this.anonymous.publicId,
          user_id: 'anonymous-user',
          name: ''
        }
      ])
    })
  })

  describe('can read old/new user details', function () {
    let projectId, docId, userId
    beforeEach('set up editor session', function (done) {
      FixturesManager.setUpEditorSession(
        {
          privilegeLevel: 'owner'
        },
        (error, { project_id, doc_id, user_id }) => {
          projectId = project_id
          docId = doc_id
          userId = user_id
          done(error)
        }
      )
    })
    let clientA, clientAPublicId
    beforeEach('connect clientA', function (done) {
      clientA = RealTimeClient.connect()
      clientA.on('connectionAccepted', (_, publicId) => {
        clientAPublicId = publicId
        done()
      })
    })
    let clientB, clientBPublicId
    beforeEach('connect clientB', function (done) {
      clientB = RealTimeClient.connect()
      clientB.on('connectionAccepted', (_, publicId) => {
        clientBPublicId = publicId
        done()
      })
    })
    function joinClient(client, done) {
      client.emit('joinProject', { project_id: projectId }, (error) => {
        if (error) return done(error)
        client.emit('joinDoc', docId, done)
      })
    }
    beforeEach('join clientA', function (done) {
      joinClient(clientA, done)
    })

    beforeEach('join clientB', function (done) {
      joinClient(clientB, done)
    })

    let cursorA, cursorB
    beforeEach('set old user details', function (done) {
      cursorA = { row: 21, column: 42, doc_id: docId }

      const pipeline = rclient.pipeline()
      const connectedUserKey = Keys.connectedUser({
        project_id: projectId,
        client_id: clientAPublicId
      })
      pipeline.hdel(connectedUserKey, 'user')
      pipeline.hset(connectedUserKey, 'user_id', userId)
      pipeline.hset(connectedUserKey, 'first_name', 'Jane')
      pipeline.hset(connectedUserKey, 'last_name', 'Doe')
      pipeline.hset(connectedUserKey, 'email', 'jane.doe@overleaf.com')
      pipeline.hset(connectedUserKey, 'cursorData', JSON.stringify(cursorA))
      pipeline.exec(done)
    })
    beforeEach('set new user details', function (done) {
      cursorB = {
        row: 42,
        column: 1337,
        doc_id: docId
      }
      clientB.emit('clientTracking.updatePosition', cursorB, done)
    })

    let connectedUsers
    beforeEach('fetch connected users', function (done) {
      clientA.emit('clientTracking.getConnectedUsers', (error, users) => {
        connectedUsers = users
        done(error)
      })
    })

    it('should be able to read the old format', function () {
      expect(connectedUsers).to.deep.include({
        connected: true,
        client_id: clientAPublicId,
        first_name: 'Jane',
        last_name: 'Doe',
        user_id: userId,
        email: 'jane.doe@overleaf.com',
        cursorData: cursorA
      })
    })

    it('should be able to read the new format', function () {
      expect(connectedUsers).to.deep.include({
        connected: true,
        client_id: clientBPublicId,
        first_name: 'Joe',
        last_name: 'Bloggs',
        user_id: userId,
        email: '',
        cursorData: cursorB
      })
    })
  })
})
