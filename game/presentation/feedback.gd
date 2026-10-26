extends AudioStreamPlayer

const SAMPLE_RATE: int = 22050
const NOTE_FRAMES: int = 1764
const PATTERNS: Dictionary = {
	"command": [880.0], "queued": [440.0], "error": [220.0, 165.0],
	"order": [523.25, 659.25, 783.99], "save": [659.25, 880.0],
	"repair": [392.0, 523.25],
}

var settings_path: String = "user://preferences.cfg"
var sound_enabled: bool = true
var settings_error: Error = OK
var clips: Dictionary = {}


func _ready() -> void:
	volume_db = -12.0
	for cue: String in PATTERNS:
		clips[cue] = _synthesize(PATTERNS[cue])
	var settings := ConfigFile.new()
	settings_error = settings.load(settings_path)
	if settings_error == ERR_FILE_NOT_FOUND:
		settings_error = OK
	elif settings_error == OK:
		var stored: Variant = settings.get_value("audio", "enabled", true)
		if stored is bool:
			sound_enabled = stored
		else:
			settings_error = ERR_INVALID_DATA


func set_sound_enabled(enabled: bool) -> Error:
	sound_enabled = enabled
	if not enabled:
		stop()
	var settings := ConfigFile.new()
	settings.set_value("audio", "enabled", enabled)
	settings_error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(settings_path.get_base_dir()))
	if settings_error == OK:
		settings_error = settings.save(settings_path)
	return settings_error


func cue(name: String) -> bool:
	if not sound_enabled or not clips.has(name):
		return false
	stream = clips[name]
	play()
	return true


func _synthesize(notes: Array) -> AudioStreamWAV:
	var samples := PackedByteArray()
	samples.resize(notes.size() * NOTE_FRAMES * 2)
	for note_index: int in range(notes.size()):
		for sample_index: int in range(NOTE_FRAMES):
			var elapsed: float = float(sample_index) / SAMPLE_RATE
			var remaining: float = float(NOTE_FRAMES - 1 - sample_index) / SAMPLE_RATE
			var envelope: float = clampf(minf(elapsed / 0.005, remaining / 0.025), 0.0, 1.0) * exp(-6.0 * elapsed)
			var phase: float = TAU * float(notes[note_index]) * elapsed
			var amplitude: float = (sin(phase) * 0.75 + sin(phase * 2.7) * 0.25) * envelope
			samples.encode_s16((note_index * NOTE_FRAMES + sample_index) * 2, int(amplitude * 12000.0))
	var clip := AudioStreamWAV.new()
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = SAMPLE_RATE
	clip.stereo = false
	clip.data = samples
	return clip