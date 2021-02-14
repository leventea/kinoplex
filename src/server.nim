import asyncdispatch, asynchttpserver, sequtils, strutils, strformat
import ws
import protocol, config

type
  Client = ref object
    id: int
    name: string
    role: Role
    ws: WebSocket

var
  cfg = getConfig("server")
  clients: seq[Client]
  password = cfg.getSectionValue("server", "password")
  playing: bool
  playlist: seq[string]
  playlistIndex = 0
  globalId = 0
  timestamp = 0.0
  pauseOnLeave = cfg.getSectionBool("server", "pauseOnLeave")
  pauseOnChange = cfg.getSectionBool("server", "pauseOnChange")

template send(client, msg) =
  try:
    if client.ws.readyState == Open:
      asyncCheck client.ws.send($(%msg))
  except WebSocketError:
    discard

proc broadcast(msg: Event; skip=(-1)) =
  for c in clients:
    if c.id == skip: continue
    c.send(msg)

proc authorize(client: Client; name, pass: string) {.async.} =
  if pass.len > 0 and pass == password:
    client.role = admin

  client.name = name
  if clients.anyIt(it.name == client.name):
    client.send(Error("name already taken"))
    return
  if client.name.len == 0:
    client.send(Error("name empty"))
    return

  client.send(Joined(client.name, client.role))
  client.id = globalId
  inc globalId
  clients.add client
  broadcast(Joined(client.name, client.role), skip=client.id)
  echo &"New client: {client.name} ({client.id})"

  if playlist.len > 0:
    client.send(PlaylistLoad(playlist))
    client.send(PlaylistPlay(playlistIndex))
  client.send(State(playing, timestamp))
  client.send(Clients(clients.mapIt(it.name)))

proc handle(client: Client; ev: Event) {.async.} =
  # if ev.kind != EventKind.Auth:
  #   echo "(", client.name, ") ", ev

  template checkPermission(minRole) =
    if client.role < minRole:
      client.send(Message("You don't have permission"))
      return

  match ev:
    Auth(name, pass):
      asyncCheck client.authorize(name, pass)
    Message(msg):
      broadcast(Message(&"<{client.name}> {msg}"), skip=client.id)
    Clients:
      client.send(Clients(clients.mapIt(it.name)))
    State(state, time):
      checkPermission(admin)
      playing = state
      timestamp = time
      broadcast(ev, skip=client.id)
    PlaylistLoad:
      client.send(PlaylistLoad(playlist))
    PlaylistClear:
      checkPermission(admin)
      playlist.setLen(0)
      playing = false
      timestamp = 0.0
      broadcast(ev)
    PlaylistAdd(url):
      checkPermission(janny)
      if "http" notin url:
        client.send(Message("Invalid url"))
      else:
        playlist.add url
        broadcast(PlaylistAdd(url))
        broadcast(Message(&"{client.name} added {url}"))
    PlaylistPlay(index):
      checkPermission(admin)
      if index > playlist.high:
        client.send(Message("Index too high"))
      elif index < 0:
        client.send(Message("Index too low"))
      else:
        playlistIndex = index
        if pauseOnChange:
          playing = false
        timestamp = 0
        broadcast(ev, skip=client.id)
        broadcast(State(playing, timestamp))
    Janny(name, state):
      checkPermission(admin)
      var found = false
      for c in clients:
        if c.name != name: continue
        found = true
        if state and c.role == janny:
          client.send(Message(c.name & " is already a janny"))
        elif state and c.role == user:
          c.role = janny
          c.send(Janny(c.name, true))
          broadcast(Message(c.name & " became a janny"))
        elif not state and c.role == janny:
          c.role = user
          c.send(Janny(c.name, false))
          broadcast(Message(c.name & " is no longer a janny"))
      if not found:
        client.send(Error("Invalid user"))
    _: echo "unknown: ", ev

proc cb(req: Request) {.async, gcsafe.} =
  if req.url.path == cfg.getSectionValue("server", "websocketPath"):
    var client = Client()
    try:
      client.ws = await newWebSocket(req)
      while client.ws.readyState == Open:
        let msg = await client.ws.receiveStrPacket()
        if msg.len > 0:
          await client.handle(unpack msg)
    except WebSocketError:
      echo &"socket closed: {client.name} ({client.id})"
      clients.keepItIf(it != client)
      if client.name.len > 0:
        broadcast(Left(client.name))
        if pauseOnLeave:
          playing = false
          broadcast(State(playing, timestamp))
  else:
    await req.respond(Http200, "Welcome to the kinoplex, how may I help you?")


var server = newAsyncHttpServer()

let port = cfg.getSectionValue("server", "port").parseInt
waitFor server.serve(Port(port), cb) # add to config
