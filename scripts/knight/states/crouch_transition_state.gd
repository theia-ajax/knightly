extends State
class_name CrouchTransitionState

var duration = 0.05
var timer = 0.0
var direction = 1

func sync_anim():
	play_anim("CrouchTransition")

func norm_time():
	return clampf(timer / duration, 0.0, 1.0)

func reverse():
	timer = duration
	direction = -1
	sync_anim()

func _process(delta):
	timer += delta * direction
	sync_anim()

	body.apply_gravity(delta)
	body.apply_walk_accel(delta)
	body.move_and_slide()

	if direction > 0:
		if timer >= duration:
			if body.input_movement.x:
				machine.change_state("crouch_walk")
			else:
				machine.change_state("crouch_idle")
	elif direction < 0:
		if timer <= 0.0:
			machine.change_state("idle")
