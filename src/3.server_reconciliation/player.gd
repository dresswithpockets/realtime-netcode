extends KinematicBody

class_name ServerRecon_Player

export var accel: float
export var damp: float
export var maxspeed: float

var velocity = Vector3.ZERO

var net = null
var net_id = 0
var local = false
var _latest_state_seq = 0
var _cmd_queue = []
var _cmd_sequence = 0

var _local_cmds = []
const _reconcile_limit = 10

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
        cmd = { wish_dir = wish_dir, seq = _next_cmd_id() }
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
    net.send_player_state(net_id, get_state(_latest_state_seq))

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


func get_state(seq):
    return { seq = seq, transform = global_transform, velocity = velocity }

# apply an authoritative state packet sent from the master node. all puppets
# should invoke this when a player state is recieved
func apply_state(state: Dictionary):
    # we need to replay everything thats occured since this state
    _replay_process(state)

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
