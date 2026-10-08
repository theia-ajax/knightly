extends State

class_name AttackState

var next_attack_buffer = 0
var attack_end_hold = 0
var attack_num = 0

func _ready():
	play_anim("AttackNoMovement")
	attack_num = 0
#	body.velocity.x = body.facing * 10

func _process(delta):
	if next_attack_buffer > 0:
		next_attack_buffer -= delta

	if body.attack_request:
		next_attack_buffer = 0.2
		
	if attack_end_hold > 0:
		if next_attack_buffer > 0:
			attack_num += 1
			attack_end_hold = 0
			if attack_num % 2 == 0:
				play_anim("AttackNoMovement")
			else:
				play_anim("Attack2NoMovement")
		else:
			attack_end_hold -= delta
			if attack_end_hold <= 0:
				on_end_attack()

func _physics_process(delta):
	body.apply_gravity(delta)
	body.apply_friction(delta)
	body.move_and_slide()
	if not body.is_on_floor():
		machine.change_state("air")

func on_anim_finished():
	if attack_num % 2 == 0:
		attack_end_hold = 8.0 / 60.0
	else:
		attack_end_hold = 4 / 60.0

func on_end_attack():
	machine.change_state("idle")
