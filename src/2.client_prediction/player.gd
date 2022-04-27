extends KinematicBody

class_name ClientPrediction_Player

export var accel: float
export var damp: float
export var maxspeed: float

var velocity = Vector3.ZERO

var net = null
var net_id = 0
var local = false
var _cmd_queue = []

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
        _local_process(delta, cmd)
    
    if cmd:
        var wish_dir = cmd.wish_dir.normalized()
        velocity += wish_dir * accel * delta
        velocity *= damp
        move_and_slide(velocity, Vector3.UP)
            
    if is_network_master():
        _master_process(delta)

func _get_input_cmd():
    var cmd
    if local:
        var wish_dir = Vector3.ZERO
        wish_dir.z = Input.get_axis("move_forward", "move_backward")
        wish_dir.x = Input.get_axis("move_left", "move_right")
        cmd = { wish_dir = wish_dir }
    elif is_network_master():
        if len(_cmd_queue) > 0:
            cmd = _cmd_queue.front()
            _cmd_queue.clear()
    return cmd

func _local_process(delta, cmd):
    net.send_player_command(cmd)

func _master_process(delta: float):
    net.send_player_state(net_id, get_state())

func get_state():
    return { transform = global_transform, velocity = velocity }

# apply an authoritative state packet sent from the master node. all puppets
# should invoke this when a player state is recieved
func apply_state(state):
    global_transform = state.transform
    velocity = velocity

# queue the command to be processed on the next fixed frame
func queue_cmd(cmd):
    _cmd_queue.push_back(cmd)
