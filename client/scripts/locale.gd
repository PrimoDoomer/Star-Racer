extends Node

# Autoload singleton: lightweight i18n for Star Racer.
#
# Translations are built in code and registered with Godot's TranslationServer,
# so static Control text (set to the keys below) is auto-translated and the
# whole UI re-translates live when the locale changes — no CSV import needed.
# Runtime strings use `tr("key")`.
#
# Supported locales: "en" and "fr". On first launch the OS language picks the
# default ("fr" if the system is French, else "en"); after that the player's
# explicit choice in Settings is remembered.

const SETTINGS_PATH := "user://settings.cfg"

const LOCALES := ["en", "fr"]

const STRINGS := {
	"en": {
		# --- Online menu (static scene text) ---
		"ui_quit": "Quit",
		"ui_pilot": "PILOT",
		"ui_nickname": "NICKNAME",
		"ui_nickname_ph": "Your nickname",
		"ui_tab_join": "Join",
		"ui_tab_create": "Create",
		"ui_refresh": "Refresh",
		"ui_join_race": "Join race",
		"ui_race_name": "RACE NAME",
		"ui_race_name_ph": "Race name",
		"ui_track": "Track",
		"ui_players_min": "Min players",
		"ui_players_max": "Max",
		"ui_create_race": "Create race",
		"ui_pilots": "PILOTS",
		"ui_back_to_menu": "Back to menu",
		"ui_resume": "Resume",
		"ui_leave": "Leave",
		"ui_settings": "Settings",
		"ui_editor": "Editor",
		# --- Lobby list columns / states ---
		"col_name": "Name",
		"col_owner": "Owner",
		"col_players": "Players",
		"col_min": "Min needed",
		"col_state": "State",
		"col_start": "Start time",
		"col_track": "Track",
		"state_racing": "Racing",
		"state_intermission": "Intermission",
		# --- Status / info messages ---
		"fetching": "Fetching lobbies...",
		"no_connection": "Couldn't connect to server",
		"lobbies_fetched": "Lobbies fetched, select one to join or create a new one",
		"spectating": "Spectating — next race you'll be in",
		"current_track": "Current track: %s",
		"waiting_one": "Waiting for %d player",
		"waiting_many": "Waiting for %d players",
		"start_in": "Start in %d...",
		"lap": "Lap %d / %d",
		"finished": "Finished!",
		"race_finished": "Race finished!",
		"could_not_join": "Could not join: %s",
		# --- Join errors ---
		"err_nickname_used": "Nickname already in use",
		"err_lobby_full": "Lobby is full",
		"err_lobby_exists": "Lobby already exists",
		"err_lobby_not_found": "Lobby not found",
		"err_invalid_config": "Invalid lobby configuration",
		"err_track_not_found": "Track not found on server",
		"err_unknown": "Unknown error: %s",
		# --- HUD ---
		"boost_ready": "BOOST READY",
		# --- Settings panel ---
		"set_title": "SETTINGS",
		"set_language": "LANGUAGE",
		"set_controls": "CONTROLS",
		"set_press_key": "Press a key...",
		"set_reset": "Reset to defaults",
		"set_close": "Close",
		"set_unbound": "—",
		# --- Rebindable actions ---
		"act_Throttle": "Accelerate",
		"act_Steering Left": "Steer left",
		"act_Steering Right": "Steer right",
		"act_Star Drift": "Star Drift",
		"act_Pause": "Pause",
		"act_Back View": "Look back",
		"act_View Left": "Look left",
		"act_View Right": "Look right",
		"act_View Up": "Look up",
		"act_View Down": "Look down",
	},
	"fr": {
		# --- Online menu (static scene text) ---
		"ui_quit": "Quitter",
		"ui_pilot": "PILOTE",
		"ui_nickname": "PSEUDO",
		"ui_nickname_ph": "Votre pseudo",
		"ui_tab_join": "Rejoindre",
		"ui_tab_create": "Créer",
		"ui_refresh": "Actualiser",
		"ui_join_race": "Rejoindre la course",
		"ui_race_name": "NOM DE LA COURSE",
		"ui_race_name_ph": "Nom de la course",
		"ui_track": "Circuit",
		"ui_players_min": "Joueurs min",
		"ui_players_max": "Max",
		"ui_create_race": "Créer la course",
		"ui_pilots": "PILOTES",
		"ui_back_to_menu": "Retour au menu",
		"ui_resume": "Reprendre",
		"ui_leave": "Quitter",
		"ui_settings": "Paramètres",
		"ui_editor": "Éditeur",
		# --- Lobby list columns / states ---
		"col_name": "Nom",
		"col_owner": "Hôte",
		"col_players": "Joueurs",
		"col_min": "Min requis",
		"col_state": "État",
		"col_start": "Départ",
		"col_track": "Circuit",
		"state_racing": "En course",
		"state_intermission": "Salon",
		# --- Status / info messages ---
		"fetching": "Récupération des salons...",
		"no_connection": "Connexion au serveur impossible",
		"lobbies_fetched": "Salons récupérés, sélectionnez-en un ou créez le vôtre",
		"spectating": "Spectateur — vous jouerez à la prochaine course",
		"current_track": "Circuit actuel : %s",
		"waiting_one": "En attente de %d joueur",
		"waiting_many": "En attente de %d joueurs",
		"start_in": "Départ dans %d...",
		"lap": "Tour %d / %d",
		"finished": "Terminé !",
		"race_finished": "Course terminée !",
		"could_not_join": "Impossible de rejoindre : %s",
		# --- Join errors ---
		"err_nickname_used": "Pseudo déjà utilisé",
		"err_lobby_full": "Le salon est plein",
		"err_lobby_exists": "Le salon existe déjà",
		"err_lobby_not_found": "Salon introuvable",
		"err_invalid_config": "Configuration de salon invalide",
		"err_track_not_found": "Circuit introuvable sur le serveur",
		"err_unknown": "Erreur inconnue : %s",
		# --- HUD ---
		"boost_ready": "BOOST PRÊT",
		# --- Settings panel ---
		"set_title": "PARAMÈTRES",
		"set_language": "LANGUE",
		"set_controls": "COMMANDES",
		"set_press_key": "Appuyez sur une touche...",
		"set_reset": "Réinitialiser",
		"set_close": "Fermer",
		"set_unbound": "—",
		# --- Rebindable actions ---
		"act_Throttle": "Accélérer",
		"act_Steering Left": "Tourner à gauche",
		"act_Steering Right": "Tourner à droite",
		"act_Star Drift": "Star Drift",
		"act_Pause": "Pause",
		"act_Back View": "Regard arrière",
		"act_View Left": "Regard gauche",
		"act_View Right": "Regard droit",
		"act_View Up": "Regard haut",
		"act_View Down": "Regard bas",
	},
}

func _enter_tree() -> void:
	_register()
	TranslationServer.set_locale(_initial_locale())

func _register() -> void:
	for code in LOCALES:
		var t := Translation.new()
		t.locale = code
		for key in STRINGS[code]:
			t.add_message(key, STRINGS[code][key])
		TranslationServer.add_translation(t)

func _initial_locale() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var saved := String(cfg.get_value("Settings", "locale", ""))
		if saved in LOCALES:
			return saved
	return "fr" if OS.get_locale_language().begins_with("fr") else "en"

# Two-letter code of the active locale ("en" / "fr").
func current() -> String:
	var loc := TranslationServer.get_locale()
	return loc.substr(0, 2)

func set_locale(code: String) -> void:
	if code not in LOCALES:
		code = "en"
	TranslationServer.set_locale(code)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep other settings intact
	cfg.set_value("Settings", "locale", code)
	cfg.save(SETTINGS_PATH)
