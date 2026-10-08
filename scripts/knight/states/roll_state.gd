extends State

class_name RunState

const MOVE_ACCEL = 800.0
const MAX_SPEED = 140.0
const FRICTION = 0.4

func _ready():
	body.walk_move_accel = MOVE_ACCEL
	body.walk_max_speed = MAX_SPEED
	body.walk_friction = FRICTION
	play_anim("Roll")

func _process(delta):
	body.sync_sprite_facing()
	body.try_attack("attack")
	
	if not body.input_movement.x:
		machine.change_state("idle")
	
	if body.input_movement.y < 0:
		machine.change_state("crouch_transition")

func _physics_process(delta):
	body.apply_gravity(delta)
	body.do_jump_if_valid()
	body.apply_walk_accel(delta)
	body.move_and_slide()

	if not body.is_on_floor():
		machine.change_state("air")
