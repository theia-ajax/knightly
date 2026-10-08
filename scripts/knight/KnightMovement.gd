extends CharacterBody2D

const SPEED = 140.0
const JUMP_VELOCITY = -300.0

@export var fall_blend_threshold: float = 20.0

@export var ground_friction: float = 0.4

@onready var _animator = $AnimatedSprite2D
@onready var sprite_offset_x = _animator.transform.get_origin().x

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/2d/default_gravity")
var facing = 1

var input_movement = Vector2(0, 0)
var jump_request = false
var attack_request = false
var dash_request = false
var roll_request = false

var walk_move_accel = 800.0
var walk_max_speed = 140.0
var walk_max_speed_decay = 400.0
var walk_friction = ground_friction

var debug_font

var state_machine
var states = {
	StringName("idle"): IdleState,
	StringName("run"): RunState,
	StringName("jump"): JumpState,
	StringName("air"): AirState,
	StringName("crouch_transition"): CrouchTransitionState,
	StringName("crouch_idle"): CrouchIdleState,
	StringName("crouch_walk"): CrouchWalkState,
	StringName("crouch_attack"): CrouchAttackState,
	StringName("attack"): AttackState,
}
func _ready():
	debug_font = load("res://fonts/prstartk.ttf")

	state_machine = StateMachine.new(self, states, _animator)
	add_child(state_machine)
	state_machine.change_state("idle")

func _input(event):
	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().quit()

func _draw():
	draw_string(debug_font, Vector2(0, 0), "speed %0.2f" % velocity.x, HORIZONTAL_ALIGNMENT_LEFT, -1, 8)
	draw_string(debug_font, Vector2(0, 10), "state: %s" % state_machine.get_active_state_name(), HORIZONTAL_ALIGNMENT_LEFT, -1, 8)

func _process(delta):
	if Input.is_action_just_pressed("Jump"):
		jump_request = true

	attack_request = Input.is_action_just_pressed("Attack")
	dash_request = Input.is_action_just_pressed("Dash")
	roll_request = Input.is_action_just_pressed("Roll")

func _physics_process(delta):
	if not is_on_floor():
		jump_request = false
		roll_request = false

	input_movement.x = Input.get_axis("MoveLeft", "MoveRight")
	input_movement.y = Input.get_axis("MoveDown", "MoveUp")
	
	if input_movement.x:
		facing = input_movement.x
		
	queue_redraw()
	
func do_jump_if_valid():
	if jump_request and is_on_floor():
		velocity.y = JUMP_VELOCITY
		jump_request = false

func apply_gravity(delta):
	if not is_on_floor():
		velocity.y += gravity * delta

func apply_walk_accel(delta):
	var change = walk_move_accel * input_movement.x * delta

	# acceleration cannot accelerate past max speed
	# however if already past max speed won't immediately clamp velocity to it
	# allows for slow off of excess speed like when max speed is changed in different states
	if abs(velocity.x + change) > walk_max_speed:
		if change > 0:
			velocity.x = max(velocity.x, walk_max_speed)
		else:
			velocity.x = min(velocity.x, -walk_max_speed)
	else:
		velocity.x += change
	
	
	var decay = walk_max_speed_decay * delta
	if velocity.x > walk_max_speed:
		velocity.x = max(velocity.x - decay, walk_max_speed)
	elif velocity.x < -walk_max_speed:
		velocity.x =  min(velocity.x + decay, walk_max_speed)

func apply_friction(delta):
	if is_on_floor():
		walk_friction = ground_friction

	var fric_mag = -velocity.x * walk_friction
	
	if fric_mag > 0:
		velocity.x = minf(velocity.x + fric_mag, 0.0)
	else:
		velocity.x = maxf(velocity.x + fric_mag, 0.0)

func sync_sprite_facing():
	_animator.flip_h = facing < 0
	# We use the base origin to figure out to the total offset but have to subtract it out of our offset when we set a new one so it's not added in.
	# really wish there was just a transform.set_origin call available...
#	_animator.offset.x = sprite_offset_x * facing - sprite_offset_x
	_animator.transform.origin.x = sprite_offset_x * facing

func try_attack(attack: StringName):
	if attack_request:
		attack_request = false
		state_machine.change_state(attack)

func _on_animated_sprite_2d_animation_looped():
	state_machine.on_anim_looped()

func _on_animated_sprite_2d_animation_finished():
	state_machine.on_anim_finished()

func _on_animated_sprite_2d_animation_changed():
	state_machine.on_anim_changed()
