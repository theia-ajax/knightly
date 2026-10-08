extends State

class_name AirState

const MOVE_ACCEL = 200.0
const MAX_SPEED = 140.0
const FRICTION = 0.0

func _ready():
	body.walk_move_accel = MOVE_ACCEL
	body.walk_max_speed = MAX_SPEED
	body.walk_friction = FRICTION
	sync_air_anim()

func _physics_process(delta):	
	body.apply_gravity(delta)
	body.apply_walk_accel(delta)
	body.move_and_slide()

	sync_air_anim()

	if body.is_on_floor():
		if body.input_movement.x:
			machine.change_state("run")
		else:
			machine.change_state("idle")


func sync_air_anim():
	if body.velocity.y < -body.fall_blend_threshold:
		play_anim("Jump")
	elif body.velocity.y < body.fall_blend_threshold:
		play_anim("JumpFallInbetween")
	else:
		play_anim("Fall")
