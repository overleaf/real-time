/* eslint-disable
    camelcase,
    handle-callback-err,
    no-throw-literal,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
const RealTimeClient = require('./helpers/RealTimeClient')
const MockDocUpdaterServer = require('./helpers/MockDocUpdaterServer')
const FixturesManager = require('./helpers/FixturesManager')

const async = require('async')

const settings = require('@overleaf/settings')
const redis = require('@overleaf/redis-wrapper')
const rclient = redis.createClient(settings.redis.pubsub)

describe('leaveProject', function () {
  before(function (done) {
    return MockDocUpdaterServer.run(done)
  })

  describe('with other clients in the project', function () {
    before(function (done) {
      return async.series(
        [
          cb => {
            return FixturesManager.setUpProject(
              {
                privilegeLevel: 'owner',
                project: {
                  name: 'Test Project',
                },
              },
              (e, { project_id, user_id }) => {
                this.project_id = project_id
                this.user_id = user_id
                return cb()
              }
            )
          },

          cb => {
            this.clientA = RealTimeClient.connect()
            return this.clientA.on('connectionAccepted', cb)
          },

          cb => {
            this.clientB = RealTimeClient.connect()
            this.clientB.on('connectionAccepted', cb)

            this.clientBDisconnectMessages = []
            return this.clientB.on(
              'clientTracking.clientDisconnected',
              data => {
                return this.clientBDisconnectMessages.push(data)
              }
            )
          },

          cb => {
            return this.clientA.emit(
              'joinProject',
              { project_id: this.project_id },
              (error, project, privilegeLevel, protocolVersion) => {
                this.project = project
                this.privilegeLevel = privilegeLevel
                this.protocolVersion = protocolVersion
                return cb(error)
              }
            )
          },

          cb => {
            return this.clientB.emit(
              'joinProject',
              { project_id: this.project_id },
              (error, project, privilegeLevel, protocolVersion) => {
                this.project = project
                this.privilegeLevel = privilegeLevel
                this.protocolVersion = protocolVersion
                return cb(error)
              }
            )
          },

          cb => {
            return FixturesManager.setUpDoc(
              this.project_id,
              { lines: this.lines, version: this.version, ops: this.ops },
              (e, { doc_id }) => {
                this.doc_id = doc_id
                return cb(e)
              }
            )
          },

          cb => {
            return this.clientA.emit('joinDoc', this.doc_id, cb)
          },
          cb => {
            return this.clientB.emit('joinDoc', this.doc_id, cb)
          },

          cb => {
            // leaveProject is called when the client disconnects
            this.clientA.on('disconnect', () => cb())
            return this.clientA.disconnect()
          },

          cb => {
            // The API waits a little while before flushing changes
            return setTimeout(done, 1000)
          },
        ],
        done
      )
    })

    it('should emit a disconnect message to the room', function () {
      return this.clientBDisconnectMessages.should.deep.equal([
        this.clientA.publicId,
      ])
    })

    it('should no longer list the client in connected users', function (done) {
      return this.clientB.emit(
        'clientTracking.getConnectedUsers',
        (error, users) => {
          for (const user of Array.from(users)) {
            if (user.client_id === this.clientA.publicId) {
              throw 'Expected clientA to not be listed in connected users'
            }
          }
          return done()
        }
      )
    })

    it('should not flush the project to the document updater', function () {
      return MockDocUpdaterServer.deleteProject
        .calledWith(this.project_id)
        .should.equal(false)
    })

    it('should remain subscribed to the editor-events channels', function (done) {
      rclient.pubsub('CHANNELS', (err, resp) => {
        if (err) {
          return done(err)
        }
        resp.should.include(`editor-events:${this.project_id}`)
        return done()
      })
      return null
    })

    return it('should remain subscribed to the applied-ops channels', function (done) {
      rclient.pubsub('CHANNELS', (err, resp) => {
        if (err) {
          return done(err)
        }
        resp.should.include(`applied-ops:${this.doc_id}`)
        return done()
      })
      return null
    })
  })

  return describe('with no other clients in the project', function () {
    before(function (done) {
      return async.series(
        [
          cb => {
            return FixturesManager.setUpProject(
              {
                privilegeLevel: 'owner',
                project: {
                  name: 'Test Project',
                },
              },
              (e, { project_id, user_id }) => {
                this.project_id = project_id
                this.user_id = user_id
                return cb()
              }
            )
          },

          cb => {
            this.clientA = RealTimeClient.connect()
            return this.clientA.on('connect', cb)
          },

          cb => {
            return this.clientA.emit(
              'joinProject',
              { project_id: this.project_id },
              (error, project, privilegeLevel, protocolVersion) => {
                this.project = project
                this.privilegeLevel = privilegeLevel
                this.protocolVersion = protocolVersion
                return cb(error)
              }
            )
          },

          cb => {
            return FixturesManager.setUpDoc(
              this.project_id,
              { lines: this.lines, version: this.version, ops: this.ops },
              (e, { doc_id }) => {
                this.doc_id = doc_id
                return cb(e)
              }
            )
          },
          cb => {
            return this.clientA.emit('joinDoc', this.doc_id, cb)
          },

          cb => {
            // leaveProject is called when the client disconnects
            this.clientA.on('disconnect', () => cb())
            return this.clientA.disconnect()
          },

          cb => {
            // The API waits a little while before flushing changes
            return setTimeout(done, 1000)
          },
        ],
        done
      )
    })

    it('should flush the project to the document updater', function () {
      return MockDocUpdaterServer.deleteProject
        .calledWith(this.project_id)
        .should.equal(true)
    })

    it('should not subscribe to the editor-events channels anymore', function (done) {
      rclient.pubsub('CHANNELS', (err, resp) => {
        if (err) {
          return done(err)
        }
        resp.should.not.include(`editor-events:${this.project_id}`)
        return done()
      })
      return null
    })

    return it('should not subscribe to the applied-ops channels anymore', function (done) {
      rclient.pubsub('CHANNELS', (err, resp) => {
        if (err) {
          return done(err)
        }
        resp.should.not.include(`applied-ops:${this.doc_id}`)
        return done()
      })
      return null
    })
  })
})
