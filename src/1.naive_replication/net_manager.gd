extends Node

# handles naive syncing from peer to peer. This implementation will exclusively act as a relay
# for peers to send and receive peer commands.
class_name NaiveRepl_NetManager

export var host = false
export var port = 26000
export var max_peers = 2
export var hostname = "localhost"

onready var player_scene = preload("res://1.naive_replication/player.tscn")
onready var players_node = $players
onready var spawn_points = $Level/Spawnpoints

var players = {}

func _ready():
    if OS.has_feature("standalone"):
        host = OS.has_feature("listen_server")
    get_tree().connect("network_peer_connected", self, "_peer_connected")
    get_tree().connect("network_peer_disconnected", self, "_peer_disconnected")
    
    var peer = NetworkedMultiplayerENet.new()
    if host:
        if peer.create_server(port, max_peers) == OK:
            _server_ready()
    else:
        get_tree().connect("connected_to_server", self, "_connected")
        get_tree().connect("connection_failed", self, "_connection_failed")
        get_tree().connect("server_disconnected", self, "_server_disconnected")
        peer.create_client(hostname, port)

    get_tree().network_peer = peer
    
    # dont need to do this since by default the network master will always be the network server
    # self.set_network_master(peer.get_unique_id())

func _server_ready():
    # we've successfully created the server.
    # since we only support listen servers, that means the server is also a player! instantiate a
    # new player instance for the listen server and set it to be local.
    instance_player(1, true, get_random_spawn())

func _connected():
    # we've successfully connected to the server.
    # instantiate a player instance, flagging it as local.
    # query for network peers and instantiate player instances for those peers
    #   as well.
    instance_player(get_tree().get_network_unique_id(), true)
    for peer in get_tree().get_network_connected_peers():
        if not peer in players:
            instance_player(peer, false)

func _connection_failed():
    pass

func _server_disconnected():
    # we've lost connection to the server.
    # clean up the scene, delete all players
    for id in players:
        var player = players[id]
        player.queue_free()
    players.clear()

func _peer_connected(id: int):
    var spawn: Node = null
    if get_tree().is_network_server():
        # we're a listen server and a client has joined.
        # instantiate a new player node, setting it to master and passing the id of the peer that
        # it represents.
        spawn = get_random_spawn()
    else:
        # we're a client connected to a server and another player has joined.
        # instantiate a new player node, setting it to puppet and passing the id of the peer that
        # it represents.
        pass

    instance_player(id, false, spawn)

func _peer_disconnected(id: int):
    if get_tree().is_network_server():
        # we're a listen server and a client has left.
        # remove the master player node by id, if there is one
        pass
    else:
        # we're a client connected to a server and another player has left.
        # remove the puppet player node by id, if there is one
        pass
    
    remove_player(id)

func get_random_spawn() -> Node:
    return spawn_points.get_children()[0]

func instance_player(id: int, is_local: bool, spawn: Node = null) -> Node:
    # by default the network master is always going to be the network server, so we dont' actually
    # have to set_network_master() on the new player node.
    var new_player = player_scene.instance()
    new_player.net = self
    new_player.local = is_local
    new_player.name = str(id)
    new_player.net_id = id
    new_player.add_to_group("players")
    if spawn:
        new_player.global_transform = spawn.global_transform
    players[id] = new_player
    players_node.add_child(new_player)
    return new_player

func remove_player(id: int):
    players_node.remove_child(players[id])

func send_player_command(cmd):
    assert(cmd != null)
    rpc_unreliable("_do_player_cmd", cmd)

func send_player_state(id: int, state):
    assert(state != null)
    rpc_unreliable("_receive_player_state", id, state)

master func _do_player_cmd(cmd):
    assert(cmd != null)
    var id = get_tree().get_rpc_sender_id()
    if id != 1:
        pass
    var player_node = players[id]
    if player_node != null:
        player_node.queue_cmd(cmd)

puppet func _receive_player_state(id: int, state):
    assert(state != null)
    var player_node = players[id]
    if player_node != null:
        if not player_node.local:
            print ("applying state for ", id, ": ")
        player_node.apply_state(state)
