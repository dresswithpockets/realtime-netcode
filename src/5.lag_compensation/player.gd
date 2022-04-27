extends KinematicBody

class_name Interp_Player

export var accel: float
export var damp: float
export var maxspeed: float

var velocity = Vector3.ZERO

var net = null
var net_id = 0
var local = false
var _latest_state_seq = 0

# queue of states for the past _lagcomp_limit iterations used for lag compensation.
var _state_queue = []
onready var _lagcomp_limit = Engine.iterations_per_second / 4 # 1/4th a second of lag comp

# queue of commands received that havent been replayed or processed via a state received from the
# server. used for client-side server-state reconciliation
var _cmd_queue = []

# queue of commands sent since
var _local_cmds = []
var _cmd_sequence = 0
var _reconcile_limit = 10

onready var render = $Render
onready var camera = $Camera

func _ready():
    if local:
        remove_child(render)
    if not local:
        remove_child(camera)

func _physics_process(delta: float):
    var cmd = _get_input_cmd()
    if local and not is_network_master():
        # cmd should never be empty when local
        assert(not cmd.empty())
        _local_process(delta, cmd)

    _shared_process(delta, cmd)

    if is_network_master():
        # cmd might be empty if there are not commands to be processed
        if not cmd.empty():
            _latest_state_seq = cmd.seq
        _master_process(delta, cmd)

func _get_input_cmd() -> Dictionary:
    var cmd = {}
    if local:
        var wish_dir = Vector3.ZERO
        wish_dir.z = Input.get_axis("move_forward", "move_backward")
        wish_dir.x = Input.get_axis("move_left", "move_right")
        var shoot = Input.is_action_just_pressed("shoot")
        cmd = get_command(wish_dir, shoot)
    elif is_network_master():
        if len(_cmd_queue) > 0:
            _cmd_queue.sort_custom(SequenceSort, "sort_descending")
            cmd = _cmd_queue[0]
            _cmd_queue.clear()
    return cmd

func _local_process(delta: float, cmd: Dictionary):
    net.send_player_command(cmd)
    _local_cmds.push_back(cmd)
    
    # keep our queue short
    if len(_local_cmds) > _reconcile_limit:
        print_debug("_local_cmds has exceeded _reconcile_limit")
        var end = len(_local_cmds) - 1
        _local_cmds = _local_cmds.slice(end - _reconcile_limit, end)
    
func _shared_process(delta: float, cmd: Dictionary):
    if not cmd.empty():
        var wish_dir = cmd.wish_dir.normalized()
        velocity += wish_dir * accel * delta
        velocity *= damp
        velocity = move_and_slide(velocity, Vector3.UP)

func _master_process(delta: float, cmd: Dictionary):
    
    if not cmd.empty() and cmd.shoot:
        _shoot(cmd.t)
    
    var new_state = get_state()
    _state_queue.push_back(new_state)
    
    # keep our queue short
    if len(_state_queue) > _lagcomp_limit:
        var end = len(_state_queue) - 1
        _state_queue = _state_queue.slice(end - _lagcomp_limit, end)
        
    net.send_player_state(net_id, new_state)

func _shoot(client_t: int):
    # use lag compensation in order to get the state when the client sent this command
    var server_t = net.client_to_server_time(net_id, client_t)
    var tick_state = net.get_state_at_tick(server_t)
    
    # temporarily set the world state to be the state at the tick we want to simulate
    var real_state = net.get_current_state()
    net.apply_state_direct(tick_state)
    
    var space_state = get_world().direct_space_state
    var result = space_state.intersect_ray(
        global_transform.origin + Vector3(0, 0.5, 0),
        global_transform.origin + Vector3(0, 0.5, -100),
        [self])
    var other_hit = null
    if not result.empty() and result.collider.is_in_group("players"):
        print_debug("player ", net_id, " hit other player ", result.collider.name)
        print_debug("player ", net_id, " was at: ", global_transform.origin)
        print_debug("player ", result.collider.name, " was at: ", result.collider.global_transform.origin)
        other_hit = result.collider
    
    # revert back to our real world state
    net.apply_state_direct(real_state)
    
    print_debug("player ", net_id, " is really at: ", global_transform.origin)
    if other_hit:
        print_debug("player ", other_hit.name, " is really at: ", other_hit.global_transform.origin)

func _replay_process(state: Dictionary):
    var seq = state.seq
    _local_cmds.sort_custom(SequenceSort, "sort_ascending")
    
    if len(_local_cmds) > 0:
        var oldest_cmd = _local_cmds[0]
        if seq < oldest_cmd.seq:
            return
        
        # pop all local cmds in queue up until the one just after the state we received
        for i in range(len(_local_cmds)):
            var cmd = _local_cmds[i]
            if cmd.seq == seq:
                _local_cmds.resize(i)
                break
    
    global_transform = state.transform
    velocity = velocity
    
    # replay all commands since the last sequence received
    for cmd in _local_cmds:
        var physics_delta = 1.0 / Engine.iterations_per_second
        _shared_process(physics_delta, cmd)

# returns an interpolated state between states a and b, where a is the most recent state before t,
# and b is the most recent state after t. If there is only a, then returns a. If there is only b,
# then returns b, otherwise results an empty dictionary.
#
# t must be a server tick in msec, not a client tick. see NetManager.client_to_server_time to
# convert from client tick time to server tick time.
func get_state_at_tick(t: int) -> Dictionary:
    _state_queue.sort_custom(TimeSort, "sort_ascending")
    var previous = {}
    for s in _state_queue:
        if s.t > t:
            return interpolate_states(previous, s, t)
        previous = s
    return previous

# t must be a server tick in msec, not a client tick. see NetManager.client_to_server_time to
# convert from client tick time to server tick time.
func interpolate_states(a: Dictionary, b: Dictionary, t: int) -> Dictionary:
    var a_empty = a.empty()
    var b_empty = b.empty()
    if a_empty:
        if b_empty:
            return {}
        return b
    if b_empty:
        return a
    
    var alpha = float(t) / b.t - a.t
    var new = b.duplicate()
    new.t = t
    new.transform = a.transform.interpolate_with(b.transform, alpha)
    new.velocity = a.velocity.linear_interpolate(b.velocity, alpha)
    return new

func get_state() -> Dictionary:
    return { t = OS.get_ticks_msec(), seq = _latest_state_seq, transform = global_transform, velocity = velocity }

func get_command(wish_dir: Vector3, shoot: bool) -> Dictionary:
    return { t = OS.get_ticks_msec(), wish_dir = wish_dir, shoot = shoot, seq = _next_cmd_id() }

# apply an authoritative state packet sent from the master node. all puppets
# should invoke this when a player state is recieved
func apply_state(state: Dictionary):
    # we need to replay everything thats occured since this state
    _replay_process(state)

func apply_state_direct(state: Dictionary):
    global_transform = state.transform
    velocity = velocity

# queue the command to be processed on the next fixed frame
func queue_cmd(cmd: Dictionary):
    _cmd_queue.push_back(cmd)

func _next_cmd_id() -> int:
    _cmd_sequence += 1
    return _cmd_sequence

class SequenceSort:
    static func sort_ascending(a, b):
        if a.seq < b.seq:
            return true
        return false
    static func sort_descending(a, b):
        if b.seq < a.seq:
            return true
        return false

class TimeSort:
    static func sort_ascending(a, b):
        if a.t < b.t:
            return true
        return false
    static func sort_descending(a, b):
        if b.t < a.t:
            return true
        return false
