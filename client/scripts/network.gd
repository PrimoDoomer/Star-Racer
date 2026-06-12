extends Node

var socket: WebSocketPeer = null
var opened = false
var timeout_timer = 0
var message_queue = []

func terminate():
	if self.socket:
		self.socket.close()

func _process(delta: float) -> void:
	if ! self.socket:
		return

	self.socket.poll()

	var socket_state = self.socket.get_ready_state()

	if socket_state == WebSocketPeer.STATE_CONNECTING:
		self.timeout_timer += delta
		if self.timeout_timer > 3:
			terminate()
	elif socket_state == WebSocketPeer.STATE_CLOSED:
		self.socket = null
		%Game.switch_mode(Game.Mode.WELCOME_PAGE, !(self.timeout_timer > 3))
	elif socket_state == WebSocketPeer.STATE_OPEN:
		if !self.opened:
			%Game.on_connection()
			self.opened = true
		for message in self.message_queue:
			self.socket.send_text(message)
		self.message_queue.clear()
		while self.socket.get_available_packet_count() > 0:
			var message = JSON.parse_string(self.socket.get_packet().get_string_from_utf8())
			if !%Game.on_server_message(message):
				terminate()

func send(message: Variant):
	self.message_queue.push_back(JSON.stringify(message))

func connect_to_server() -> bool:
	if self.socket:
		printerr("Can't connect: already connected")
		return false

	var host = ""
	if OS.has_feature("web"):
		host = "wss://" + JavaScriptBridge.eval("window.location.hostname")
	else:
		host = "ws://127.0.0.1:8080"

	self.socket = WebSocketPeer.new()
	self.socket.inbound_buffer_size = 1000000
	self.socket.outbound_buffer_size = 1000000
	self.socket.max_queued_packets = 10000

	if self.socket.connect_to_url(host) != OK:
		printerr("Could not connect")
		return false

	self.opened = false
	self.timeout_timer = 0
	return true
