/* eslint-disable
    handle-callback-err,
    no-return-assign,
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

describe('Session', function () {
  return describe('with an established session', function () {
    before(function (done) {
      this.user_id = 'mock-user-id'
      RealTimeClient.setSession(
        {
          user: { _id: this.user_id },
        },
        error => {
          if (error != null) {
            throw error
          }
          this.client = RealTimeClient.connect()
          return done()
        }
      )
      return null
    })

    it('should not get disconnected', function (done) {
      let disconnected = false
      this.client.on('disconnect', () => (disconnected = true))
      return setTimeout(() => {
        expect(disconnected).to.equal(false)
        return done()
      }, 500)
    })

    return it('should appear in the list of connected clients', function (done) {
      return RealTimeClient.getConnectedClients((error, clients) => {
        let included = false
        for (const client of Array.from(clients)) {
          if (client.client_id === this.client.socket.sessionid) {
            included = true
            break
          }
        }
        expect(included).to.equal(true)
        return done()
      })
    })
  })
})
