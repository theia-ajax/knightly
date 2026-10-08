extends State
class_name CrouchIdleState

func _ready():
	play_anim("Crouch")

func _process(delta):
	body.sync_sprite_facing()
	body.try_attack("crouch_attack")
	body.velocity.x = 0
	if body.input_movement.y >= 0:
		machine.change_state("crouch_transition", func(s): s.reverse())
	if body.input_movement.x:
		machine.change_state("crouch_walk")

func _physics_process(delta):
	body.apply_gravity(delta)
	body.do_jump_if_valid()
	body.apply_friction(delta)
	body.move_and_slide()
	
	if not body.is_on_floor():
		machine.change_state("air")
