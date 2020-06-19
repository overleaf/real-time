logger = require 'logger-sharelatex'
metrics = require "metrics-sharelatex"
{EventEmitter} = require 'events'

IdMap = new Map() # keep track of whether ids are from projects or docs
RoomEvents = new EventEmitter() # emits {project,doc}-active and {project,doc}-empty events

RoomClients = new Map() # 'room' -> [clients...]

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
        beforeCount = @countClientsInRoom(id)
        # client joins room immediately but joinDoc request does not complete
        # until room is subscribed
        @_clientJoinRoom client, id
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
      # It can also happen when we process a join and disconnect event in the
      #  same event loop cycle.
        if !@_clientAlreadyInRoom(client, id)
          logger.log {client: client.id, entity, id}, "ignoring request from client to leave room it is not in"
          return
        @_clientLeaveRoom client, id
        afterCount = @countClientsInRoom(id)
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

    _clientJoinRoom: (client, room) ->
        client.rooms.push(room)
        RoomClients.set(room, []) unless RoomClients.has(room)
        RoomClients.get(room).push(client)

    _clientLeaveRoom: (client, room) ->
        client.rooms.splice(client.rooms.indexOf(room), 1)
        clients = RoomClients.get(room)
        clients.splice(clients.indexOf(client), 1)
        if clients.length == 0
            RoomClients.delete(room)

    _roomsClientIsIn: (client) ->
        return client.rooms.slice()

    _clientAlreadyInRoom: (client, room) ->
        return client.rooms.includes(room)

    # UNSAFE: iterating over the client list returned from here is not safe
    # e.g. calling .disconnect() on a list member will manipulate the list and
    #       hence break the iterator.
    _getClientsInRoomSyncUnsafe: (room) ->
        return RoomClients.get(room) || []

    countClientsInRoom: (room) ->
        return RoomManager._getClientsInRoomSyncUnsafe(room).length
        
    getClientsInRoomSync: (room) ->
        return RoomManager._getClientsInRoomSyncUnsafe(room).slice()

    # HACK: it calls the callback synchronously -- hence the name pseudoAsync
    getClientsInRoomPseudoAsync: (room, cb) ->
        cb(null, RoomManager.getClientsInRoomSync(room))
