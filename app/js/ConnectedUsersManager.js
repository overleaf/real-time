/* eslint-disable
    camelcase,
*/
const async = require('async')
const Settings = require('settings-sharelatex')
const logger = require('logger-sharelatex')
const redis = require('@overleaf/redis-wrapper')
const OError = require('@overleaf/o-error')
const rclient = redis.createClient(Settings.redis.realtime)
const Keys = Settings.redis.realtime.key_schema

const ONE_HOUR_IN_S = 60 * 60
const ONE_DAY_IN_S = ONE_HOUR_IN_S * 24
const THREE_DAYS_IN_S = ONE_DAY_IN_S * 3
const FOUR_DAYS_IN_S = ONE_DAY_IN_S * 4

const USER_TIMEOUT_IN_S = ONE_HOUR_IN_S / 4

let MAX_NETWORK_LATENCY_IN_S = 1
const MAX_NETWORK_LATENCY_LIMIT_IN_S = 60
function updateNetworkLatency(oldNowInSeconds) {
  const nowInSeconds = Date.now() / 1000
  const lastLatency = nowInSeconds - oldNowInSeconds

  // Limit the accumulated maximum latency
  MAX_NETWORK_LATENCY_IN_S = Math.min(
    MAX_NETWORK_LATENCY_LIMIT_IN_S,
    Math.max(MAX_NETWORK_LATENCY_IN_S, lastLatency)
  )
}

function getEffectiveTTLInS(expiresAt) {
  if (!expiresAt) {
    // not set yet
    return 0
  }
  const nowInSeconds = Date.now() / 1000
  const ttl = expiresAt - nowInSeconds
  if (ttl < MAX_NETWORK_LATENCY_IN_S) {
    return 0
  }
  return ttl
}

const KEEP_TTL_ABOVE = 0.9
function trackKeyExpiry(client, field, ttlInSeconds) {
  const nowBeforeSendingInSeconds = Date.now() / 1000

  function updateInternalTTL() {
    updateNetworkLatency(nowBeforeSendingInSeconds)
    client.ol_context[field] = nowBeforeSendingInSeconds + ttlInSeconds
  }
  const ttl = getEffectiveTTLInS(client.ol_context[field])
  const ttlRecentlyBumped = ttl > ttlInSeconds * KEEP_TTL_ABOVE
  return { ttl, ttlRecentlyBumped, updateInternalTTL }
}

function trackClientsInProjectTTL(client) {
  const {
    ttl: clientsInProjectTTL,
    updateInternalTTL: updateInternalTTLForClientsInProject
  } = trackKeyExpiry(client, 'clientsInProjectExpiry', FOUR_DAYS_IN_S)
  return { clientsInProjectTTL, updateInternalTTLForClientsInProject }
}
function trackConnectedUserTTL(client) {
  const {
    ttl: connectedUserTTL,
    ttlRecentlyBumped: connectedUserTTLRecentlyBumped,
    updateInternalTTL: updateInternalTTLForConnectedUser
  } = trackKeyExpiry(client, 'connectedUserExpiry', USER_TIMEOUT_IN_S)
  return {
    connectedUserTTL,
    connectedUserTTLRecentlyBumped,
    updateInternalTTLForConnectedUser
  }
}

module.exports = {
  // Use the same method for when a user connects, and when a user sends a cursor
  // update. This way we don't care if the connected_user key has expired when
  // we receive a cursor update.
  updateUserPosition(project_id, client, user, cursorData, callback) {
    // NOTE: The publicId is exposed to other clients only.
    const client_id = client.publicId
    logger.log({ project_id, client_id }, 'marking user as joined or connected')

    // It is safe to use a pipeline instead of a multi here:
    //  - others commands can change the clientsInProject hash without
    //     impacting our operation
    //  - other commands can update the connectedUser fields/expiry without
    //     impacting any consistency requirements
    const multi = rclient.pipeline()

    const {
      clientsInProjectTTL,
      updateInternalTTLForClientsInProject
    } = trackClientsInProjectTTL(client)
    const {
      connectedUserTTL,
      connectedUserTTLRecentlyBumped,
      updateInternalTTLForConnectedUser
    } = trackConnectedUserTTL(client)

    if (clientsInProjectTTL < THREE_DAYS_IN_S) {
      // Effectively lower expiry to three days without activity of ANY client.
      multi.sadd(Keys.clientsInProject({ project_id }), client_id)
      multi.expire(
        Keys.clientsInProject({ project_id }),
        FOUR_DAYS_IN_S,
        (err) => {
          if (!err) {
            updateInternalTTLForClientsInProject()
          }
        }
      )
    }

    if (connectedUserTTL <= 0) {
      // Skip re-populating the hash field unless the key is expired.
      multi.hset(
        Keys.connectedUser({ project_id, client_id }),
        'user',
        JSON.stringify({
          user_id: user._id,
          first_name: user.first_name || '',
          last_name: user.last_name || '',
          email: user.email || ''
        })
      )
    }

    if (cursorData) {
      multi.hset(
        Keys.connectedUser({ project_id, client_id }),
        'cursorData',
        JSON.stringify(cursorData)
      )
    }
    if (!connectedUserTTLRecentlyBumped) {
      multi.expire(
        Keys.connectedUser({ project_id, client_id }),
        USER_TIMEOUT_IN_S,
        (err) => {
          if (!err) {
            updateInternalTTLForConnectedUser()
          }
        }
      )
    }

    multi.exec(function (err) {
      if (err) {
        err = new OError('problem marking user as connected').withCause(err)
      }
      callback(err)
    })
  },

  refreshClient(project_id, client) {
    // NOTE: The publicId is exposed to other clients.
    const client_id = client.publicId
    logger.log({ project_id, client_id }, 'refreshing connected client')
    const {
      connectedUserTTLRecentlyBumped,
      updateInternalTTLForConnectedUser
    } = trackConnectedUserTTL(client)
    if (connectedUserTTLRecentlyBumped) return
    rclient.expire(
      Keys.connectedUser({ project_id, client_id }),
      USER_TIMEOUT_IN_S,
      function (err) {
        if (err) {
          logger.err(
            { err, project_id, client_id },
            'problem refreshing connected client'
          )
        } else {
          updateInternalTTLForConnectedUser()
        }
      }
    )
  },

  markUserAsDisconnected(project_id, client_id, callback) {
    logger.log({ project_id, client_id }, 'marking user as disconnected')
    // It is safe to use a pipeline instead of a multi here:
    //  - others commands can change the clientsInProject hash without
    //     impacting our operation
    //  - deleting the connectedUser entry can happen independent to the
    //     operations on clientsInProject
    const multi = rclient.pipeline()
    multi.srem(Keys.clientsInProject({ project_id }), client_id)
    multi.expire(Keys.clientsInProject({ project_id }), FOUR_DAYS_IN_S)
    multi.del(Keys.connectedUser({ project_id, client_id }))
    multi.exec(function (err) {
      if (err) {
        err = new OError('problem marking user as disconnected').withCause(err)
      }
      callback(err)
    })
  },

  _getConnectedUser(project_id, client_id, callback) {
    rclient.hgetall(Keys.connectedUser({ project_id, client_id }), function (
      err,
      result
    ) {
      if (err) {
        err = new OError('problem fetching connected user details', {
          other_client_id: client_id
        }).withCause(err)
        return callback(err)
      }
      // old format: .user_id, new format: .user
      const hasData = result && (result.user_id || result.user)
      if (!hasData) {
        result = {
          connected: false,
          client_id
        }
      } else {
        result.connected = true
        result.client_id = client_id

        if (result.user) {
          // inflate the merged user object
          try {
            Object.assign(result, JSON.parse(result.user))
          } catch (e) {
            OError.tag(e, 'error parsing user JSON', {
              other_client_id: client_id,
              user: result.user
            })
            return callback(e)
          }
          delete result.user
        }

        if (result.cursorData) {
          try {
            result.cursorData = JSON.parse(result.cursorData)
          } catch (e) {
            OError.tag(e, 'error parsing cursorData JSON', {
              other_client_id: client_id,
              cursorData: result.cursorData
            })
            return callback(e)
          }
        }
      }
      callback(err, result)
    })
  },

  getConnectedUsers(project_id, callback) {
    const self = this
    rclient.smembers(Keys.clientsInProject({ project_id }), function (
      err,
      results
    ) {
      if (err) {
        err = new OError('problem getting clients in project').withCause(err)
        return callback(err)
      }
      const jobs = results.map((client_id) => (cb) =>
        self._getConnectedUser(project_id, client_id, cb)
      )
      async.series(jobs, function (err, users) {
        if (err) {
          OError.tag(err, 'problem getting connected users')
          return callback(err)
        }
        users = users.filter((user) => user && user.connected)
        callback(null, users)
      })
    })
  }
}
