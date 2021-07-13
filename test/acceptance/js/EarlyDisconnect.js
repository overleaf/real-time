/* eslint-disable
    camelcase,
    no-return-assign,
*/
// TODO: This file was created by bulk-decaffeinate.
// Fix any style issues and re-enable lint.
/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/master/docs/suggestions.md
 */
const async = require('async')
const { expect } = require('chai')

const RealTimeClient = require('./helpers/RealTimeClient')
const MockDocUpdaterServer = require('./helpers/MockDocUpdaterServer')
const MockWebServer = require('./helpers/MockWebServer')
const FixturesManager = require('./helpers/FixturesManager')

const settings = require('@overleaf/settings')
const redis = require('@overleaf/redis-wrapper')
const rclient = redis.createClient(settings.redis.pubsub)
const rclientRT = redis.createClient(settings.redis.realtime)
const KeysRT = settings.redis.realtime.key_schema

describe('EarlyDisconnect', function () {
  before(function (done) {
    return MockDocUpdaterServer.run(done)
  })

  describe('when the client disconnects before joinProject completes', function () {
    before(function () {
      // slow down web-api requests to force the race condition
      let joinProject
      this.actualWebAPIjoinProject = joinProject = MockWebServer.joinProject
      return (MockWebServer.joinProject = (project_id, user_id, cb) =>
        setTimeout(() => joinProject(project_id, user_id, cb), 300))
    })

    after(function () {
      return (MockWebServer.joinProject = this.actualWebAPIjoinProject)
    })

    beforeEach(function (done) {
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
            this.clientA.emit(
              'joinProject',
              { project_id: this.project_id },
              () => {}
            )
            // disconnect before joinProject completes
            this.clientA.on('disconnect', () => cb())
            return this.clientA.disconnect()
          },

          cb => {
            // wait for joinDoc and subscribe
            return setTimeout(cb, 500)
          },
        ],
        done
      )
    })

    // we can force the race condition, there is no need to repeat too often
    return Array.from(Array.from({ length: 5 }).map((_, i) => i + 1)).map(
      attempt =>
        it(`should not subscribe to the pub/sub channel anymore (race ${attempt})`, function (done) {
          rclient.pubsub('CHANNELS', (err, resp) => {
            if (err) {
              return done(err)
            }
            expect(resp).to.not.include(`editor-events:${this.project_id}`)
            return done()
          })
          return null
        })
    )
  })

  describe('when the client disconnects before joinDoc completes', function () {
    beforeEach(function (done) {
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
            this.clientA.emit('joinDoc', this.doc_id, () => {})
            // disconnect before joinDoc completes
            this.clientA.on('disconnect', () => cb())
            return this.clientA.disconnect()
          },

          cb => {
            // wait for subscribe and unsubscribe
            return setTimeout(cb, 100)
          },
        ],
        done
      )
    })

    // we can not force the race condition, so we have to try many times
    return Array.from(Array.from({ length: 20 }).map((_, i) => i + 1)).map(
      attempt =>
        it(`should not subscribe to the pub/sub channels anymore (race ${attempt})`, function (done) {
          rclient.pubsub('CHANNELS', (err, resp) => {
            if (err) {
              return done(err)
            }
            expect(resp).to.not.include(`editor-events:${this.project_id}`)

            return rclient.pubsub('CHANNELS', (err, resp) => {
              if (err) {
                return done(err)
              }
              expect(resp).to.not.include(`applied-ops:${this.doc_id}`)
              return done()
            })
          })
          return null
        })
    )
  })

  return describe('when the client disconnects before clientTracking.updatePosition starts', function () {
    beforeEach(function (done) {
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
            this.clientA.emit(
              'clientTracking.updatePosition',
              {
                row: 42,
                column: 36,
                doc_id: this.doc_id,
              },
              () => {}
            )
            // disconnect before updateClientPosition completes
            this.clientA.on('disconnect', () => cb())
            return this.clientA.disconnect()
          },

          cb => {
            // wait for updateClientPosition
            return setTimeout(cb, 100)
          },
        ],
        done
      )
    })

    // we can not force the race condition, so we have to try many times
    return Array.from(Array.from({ length: 20 }).map((_, i) => i + 1)).map(
      attempt =>
        it(`should not show the client as connected (race ${attempt})`, function (done) {
          rclientRT.smembers(
            KeysRT.clientsInProject({ project_id: this.project_id }),
            (err, results) => {
              if (err) {
                return done(err)
              }
              expect(results).to.deep.equal([])
              return done()
            }
          )
          return null
        })
    )
  })
})
