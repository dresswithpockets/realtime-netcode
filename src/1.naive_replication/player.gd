extends KinematicBody

class_name NaiveRepl_Player

export var accel = 5
export var damp = 0.95
export var maxspeed = 10

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
    if local:
        _local_process(delta)
            
    if is_network_master():
        _master_process(delta)

func _local_process(delta):
    var wish_dir = Vector3.ZERO
    wish_dir.z = Input.get_axis("move_forward", "move_backward")
    wish_dir.x = Input.get_axis("move_left", "move_right")
    var cmd = { wish_dir = wish_dir }
    net.send_player_command(cmd)

func _master_process(delta: float):
    var wish_dir = Vector3.ZERO
    var cmd = null
    if len(_cmd_queue) > 0:
        cmd = _cmd_queue.front()
    _cmd_queue.clear()
    if cmd != null:
        wish_dir = cmd.wish_dir
    
    wish_dir = wish_dir.normalized()
    velocity += wish_dir * accel * delta
    velocity *= damp
    move_and_slide(velocity, Vector3.UP)

    net.send_player_state(net_id, get_state())

func get_state():
    return { transform = global_transform }

# apply an authoritative state packet sent from the master node. all puppets
# should invoke this when a player state is recieved
func apply_state(state):
    global_transform = state.transform

# queue the command to be processed on the next fixed frame
func queue_cmd(cmd):
    _cmd_queue.push_back(cmd)
