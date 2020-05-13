logger = require 'logger-sharelatex'
metrics = require "metrics-sharelatex"
settings = require "settings-sharelatex"

ClientMap = new Map() # for each redis client, store a Map of subscribed channels (channelname -> subscribe promise)
ClientMapTearDown = new Map() # as ClientMap but tracks unsubscribe requests

# Manage redis pubsub subscriptions for individual projects and docs, ensuring
# that we never subscribe to a channel multiple times. The socket.io side is
# handled by RoomManager.

module.exports = ChannelManager =
    getClientMapEntry: (rclient) ->
        # return the per-client channel map if it exists, otherwise create and
        # return an empty map for the client.
        ClientMap.get(rclient) || ClientMap.set(rclient, new Map()).get(rclient)

    getClientMapTearDownEntry: (rclient) ->
        ClientMapTearDown.get(rclient) || ClientMapTearDown.set(rclient, new Map()).get(rclient)

    subscribe: (rclient, baseChannel, id) ->
        clientChannelMap = @getClientMapEntry(rclient)
        clientChannelMapTearDown = @getClientMapTearDownEntry(rclient)
        channel = "#{baseChannel}:#{id}"
        # we track pending subscribes because we want to be sure that the
        # channel is active before letting the client join the doc or project,
        # so that events are not lost.
        if clientChannelMap.has(channel)
            logger.warn {channel}, "subscribe already actioned"
            # return the existing subscribe promise, so we can wait for it to resolve
            return clientChannelMap.get(channel)
        else
            actualSubscribe = () ->
                p = rclient.subscribe channel
                p.catch () ->
                    metrics.inc "subscribe.failed.#{baseChannel}"
                    # clear state on error, following subscribes should retry
                    # new subscribe requests can overtake, skip cleanup then
                    if clientChannelMap.get(channel) is subscribePromise
                        clientChannelMap.delete(channel)
                return p

            # wait for the unsubscribe request to complete
            unsubscribePromise = Promise.resolve(clientChannelMapTearDown.get(channel))
            # unsubscribePromise never rejects
            subscribePromise = unsubscribePromise.then(actualSubscribe)

            clientChannelMap.set(channel, subscribePromise)
            logger.log {channel}, "subscribed to new channel"
            metrics.inc "subscribe.#{baseChannel}"
            return subscribePromise

    unsubscribe: (rclient, baseChannel, id) ->
        clientChannelMap = @getClientMapEntry(rclient)
        clientChannelMapTearDown = @getClientMapTearDownEntry(rclient)
        channel = "#{baseChannel}:#{id}"

        if !clientChannelMap.has(channel)
            logger.error {channel}, "not subscribed - shouldn't happen"
            return
        else
            actualUnsubscribe = () ->
                if clientChannelMapTearDown.get(channel) isnt unsubscribePromise
                    # new unsubscribe request overtook, skip unsubscribe
                    return Promise.resolve()

                if clientChannelMap.has(channel)
                    # new subscribe request overtook, skip unsubscribe
                    clientChannelMapTearDown.delete(channel)
                    return Promise.resolve()

                # nothing is attaching to this Promise, catch any errors
                p = rclient.unsubscribe(channel)
                .finally () ->
                    # new unsubscribe requests can overtake, skip cleanup
                    if clientChannelMapTearDown.get(channel) is unsubscribePromise
                        clientChannelMapTearDown.delete(channel)
                .catch (err) ->
                    logger.error {channel, err}, "failed to unsubscribed from channel"
                    metrics.inc "unsubscribe.failed.#{baseChannel}"
                return p

            # wait for the subscribe request to complete
            subscribePromise = clientChannelMap.get(channel)
            # subscribePromise can reject, unsubscribe in any case
            unsubscribePromise = subscribePromise.then(actualUnsubscribe, actualUnsubscribe)
            clientChannelMapTearDown.set(channel, unsubscribePromise)

            # new subscribe requests must wait for the unsubscribe request to
            #  complete -- they will chain onto the clientChannelMapTearDown
            #  entry when they do not find any existing (pending) subscribe
            #  request in clientChannelMap -- so clear it now.
            clientChannelMap.delete(channel)
            logger.log {channel}, "unsubscribed from channel"
            metrics.inc "unsubscribe.#{baseChannel}"
            return

    publish: (rclient, baseChannel, id, data) ->
        metrics.summary "redis.publish.#{baseChannel}", data.length
        if id is 'all' or !settings.publishOnIndividualChannels
            channel = baseChannel
        else
            channel = "#{baseChannel}:#{id}"
        # we publish on a different client to the subscribe, so we can't
        # check for the channel existing here
        rclient.publish channel, data
