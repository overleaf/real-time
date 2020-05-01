logger = require 'logger-sharelatex'
metrics = require "metrics-sharelatex"
{EventEmitter} = require 'events'

IdMap = new Map() # keep track of whether ids are from projects or docs
RoomEvents = new EventEmitter() # emits {project,doc}-active and {project,doc}-empty events

# Manage socket.io rooms for individual projects and docs
#
# The first time someone joins a project or doc we emit a 'project-active' or
# 'doc-active' event.
#
# When the last person leaves a project or doc, we emit 'project-empty' or
# 'doc-empty' event.
#
# The pubsub side is handled by ChannelManager

module.exports = RoomManager =

    joinProject: (client, project_id, callback = () ->) ->
        @joinEntity client, "project", project_id, callback

    joinDoc: (client, doc_id, callback = () ->) ->
        @joinEntity client, "doc", doc_id, callback

    leaveDoc: (client, doc_id) ->
        @leaveEntity client, "doc", doc_id

    leaveProjectAndDocs: (client) ->
        # what rooms is this client in? we need to leave them all. socket.io
        # will cause us to leave the rooms, so we only need to manage our
        # channel subscriptions... but it will be safer if we leave them
        # explicitly, and then socket.io will just regard this as a client that
        # has not joined any rooms and do a final disconnection.
        roomsToLeave = @_roomsClientIsIn(client)
        logger.log {client: client.id, roomsToLeave: roomsToLeave}, "client leaving project"
        for id in roomsToLeave
            entity = IdMap.get(id)
            @leaveEntity client, entity, id

    emitOnCompletion: (promiseList, eventName) ->
        result = Promise.all(promiseList)
        result.then () -> RoomEvents.emit(eventName)
        result.catch (err) -> RoomEvents.emit(eventName, err)

    eventSource: () ->
        return RoomEvents

    joinEntity: (client, entity, id, callback) ->
      @_clientsInRoom client, id, (beforeCount) ->
        # client joins room immediately but joinDoc request does not complete
        # until room is subscribed
        client.join id
        # is this a new room? if so, subscribe
        if beforeCount == 0
            logger.log {entity, id}, "room is now active"
            RoomEvents.once "#{entity}-subscribed-#{id}", (err) ->
                # only allow the client to join when all the relevant channels have subscribed
                logger.log {client: client.id, entity, id, beforeCount}, "client joined new room and subscribed to channel"
                callback(err)
            RoomEvents.emit "#{entity}-active", id
            IdMap.set(id, entity)
            # keep track of the number of listeners
            metrics.gauge "room-listeners", RoomEvents.eventNames().length
        else
            logger.log {client: client.id, entity, id, beforeCount}, "client joined existing room"
            callback()

    leaveEntity: (client, entity, id) ->
      # Ignore any requests to leave when the client is not actually in the
      # room. This can happen if the client sends spurious leaveDoc requests
      # for old docs after a reconnection.
      if !@_clientAlreadyInRoom(client, id)
          logger.warn {client: client.id, entity, id}, "ignoring request from client to leave room it is not in"
          return
      client.leave id
      @_clientsInRoom client, id, (afterCount) ->
        logger.log {client: client.id, entity, id, afterCount}, "client left room"
        # is the room now empty? if so, unsubscribe
        if !entity?
            logger.error {entity: id}, "unknown entity when leaving with id"
            return
        if afterCount == 0
            logger.log {entity, id}, "room is now empty"
            RoomEvents.emit "#{entity}-empty", id
            IdMap.delete(id)
            metrics.gauge "room-listeners", RoomEvents.eventNames().length

    _clientsInRoom: (client, room, cb) ->
        cb(@getClientsInRoomSync(client.server, room).length)

    _roomsClientIsIn: (client) ->
        return @getRoomsClientIsInSync(client)

    _clientAlreadyInRoom: (client, room) ->
        return @getRoomsClientIsInSync(client).indexOf(room) != -1

    getClientsInRoomSync: (io, room) ->
        # the implementation in socket.io-adapter is prone to race conditions:
        # it passes the list of clients via process.nextTick, but given that
        # NodeJS can process multiple network events in the same event loop
        # cycle, multiple clients may seem to be the last in a room, but
        # actually there are not -- some other client joined in the mean time.
        # (mean time: calculating the list of clients and us receiving it)
        adapter = io.sockets.adapter
        return [] unless adapter.rooms.hasOwnProperty(room)
        return Object.keys(adapter.rooms[room].sockets).filter((id) ->
          return adapter.nsp.connected[id]
        )

    # HACK: it calls the callback synchronously -- hence the name pseudoAsync
    # calling it asynchronously would lead to race conditions -- see above
    getClientsInRoomPseudoAsync: (io, room, cb) ->
        cb(null, RoomManager.getClientsInRoomSync(io, room))

    getRoomsClientIsInSync: (client) ->
        # The implementation in socket.io is prone to race conditions:
        # The adapter will get updated immediately from joining, but the
        #  client local state (.rooms) is updated via process.nextTick.
        # Given that NodeJS can process multiple network events in the same
        #  event loop cycle, we can join a project and disconnect in the same
        #  cycle. We would not pick up the room (we just joined) for leaving.
        roomRegistry = client.server.sockets.adapter.sids
        return [] unless roomRegistry.hasOwnProperty(client.id)
        rooms = (room for room in Object.keys(roomRegistry[client.id]) when room isnt client.id)  # exclude the client socket entry
        return rooms
