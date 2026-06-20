extends Node

# Autoload singleton: lightweight i18n for Pocket Racing.
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
		"quit_confirm": "Quit the game?",
		"quit_yes": "Quit",
		"quit_cancel": "Cancel",
		"pad_browse": "Browse races",
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
		"ui_create_race": "Create race",
		"ui_pilots": "PILOTS",
		"ui_back_to_menu": "Back to menu",
		"ui_resume": "Resume",
		"ui_leave": "Leave",
		"ui_settings": "Settings",
		"ui_editor": "Editor",
		"ui_about": "About",
		# --- Grid / auto-start (was "min/max players") ---
		"ui_players_max": "Grid size",
		"ui_players_min": "Auto-start at",
		"tip_grid": "Number of starting slots — the race is full at this many pilots.",
		"tip_start": "Pilots needed before the countdown to launch begins.",
		# --- Lobby list columns / states ---
		"col_name": "Race",
		"col_owner": "Host",
		"col_players": "Grid",
		"col_min": "Start",
		"col_state": "Status",
		"col_start": "Opened",
		"col_track": "Track",
		"state_racing": "Racing",
		"state_intermission": "Open",
		"state_full": "Full",
		# --- Status / info messages ---
		"fetching": "Searching for open races…",
		"no_connection": "Server offline — try refreshing in a moment",
		"lobbies_fetched": "Pick a race to join, or create your own",
		"no_lobbies": "No open races — create the first one!",
		"spectating": "Spectating — you're in the next race",
		"lobby_count": "%d / %d on grid — auto-start at %d",
		"current_track": "Current track: %s",
		"waiting_one": "Waiting for %d player",
		"waiting_many": "Waiting for %d players",
		"start_in": "Start in %d...",
		"lap": "Lap %d / %d",
		"finished": "Finished!",
		"finish_in": "Race ends in %ds",
		"race_finished": "Race finished!",
		"could_not_join": "Could not join: %s",
		# --- Join errors ---
		"err_nickname_used": "Nickname already in use",
		"err_lobby_full": "Lobby is full",
		"err_lobby_exists": "Lobby already exists",
		"err_lobby_not_found": "Lobby not found",
		"err_invalid_config": "Invalid lobby configuration",
		"err_invalid_name": "Enter a valid name (3–20 characters)",
		"err_track_not_found": "Track not found on server",
		"err_unknown": "Unknown error: %s",
		# --- HUD ---
		"boost_ready": "BOOST READY",
		"hud_controls": "CONTROLS",
		"hud_ranking": "RANKING",
		# --- Settings panel ---
		"set_title": "SETTINGS",
		"set_language": "LANGUAGE",
		"set_controls": "CONTROLS",
		"set_keyboard": "Keyboard",
		"set_gamepad": "Gamepad",
		"set_press_key": "Press a key...",
		"set_press_button": "Press a button...",
		"set_reset": "Reset to defaults",
		"set_close": "Close",
		"set_unbound": "—",
		# --- Rebindable actions ---
		"act_Throttle": "Accelerate",
		"act_Steering Left": "Steer left",
		"act_Steering Right": "Steer right",
		"act_Drift": "Drift",
		"act_Turbo": "Turbo",
		"act_Respawn": "Respawn",
		"act_Pause": "Pause",
		"act_Back View": "Look back",
		"act_View Left": "Look left",
		"act_View Right": "Look right",
		"act_View Up": "Look up",
		"act_View Down": "Look down",
		# --- About panel ---
		"about_tagline": "Toy-scale racing in giant rooms",
		"about_version": "Version",
		"about_build": "Build",
		"about_source": "Source",
		"about_team": "Made by",
		"about_team_designer": "P.-A. Goya — design & direction",
		"about_team_claude": "Claude (Opus 4.8) — code & art",
		"about_credits": "Credits",
		"about_credits_cc0": "Car models — Kenney “Car Kit” — CC0 (public domain), with thanks",
		"about_credits_engine": "Engine — Godot 4.6 (MIT)",
		"about_credits_physics": "Physics — Rapier · rapier3d (Apache-2.0)",
		"about_credits_server": "Server — Rust · Tokio · Serde (MIT)",
		"about_credits_art": "Decor, sky & sound — synthesised in-engine",
	},
	"fr": {
		# --- Online menu (static scene text) ---
		"ui_quit": "Quitter",
		"quit_confirm": "Quitter le jeu ?",
		"quit_yes": "Quitter",
		"quit_cancel": "Annuler",
		"pad_browse": "Parcourir les courses",
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
		"ui_create_race": "Créer la course",
		"ui_pilots": "PILOTES",
		"ui_back_to_menu": "Retour au menu",
		"ui_resume": "Reprendre",
		"ui_leave": "Quitter",
		"ui_settings": "Paramètres",
		"ui_editor": "Éditeur",
		"ui_about": "À propos",
		# --- Grille / départ auto (anciennement "joueurs min/max") ---
		"ui_players_max": "Places sur la grille",
		"ui_players_min": "Départ auto à",
		"tip_grid": "Nombre de places de départ — la course est pleine à ce nombre de pilotes.",
		"tip_start": "Pilotes requis avant le lancement du compte à rebours.",
		# --- Lobby list columns / states ---
		"col_name": "Course",
		"col_owner": "Hôte",
		"col_players": "Grille",
		"col_min": "Départ",
		"col_state": "Statut",
		"col_start": "Ouverte",
		"col_track": "Circuit",
		"state_racing": "En course",
		"state_intermission": "Ouverte",
		"state_full": "Complète",
		# --- Status / info messages ---
		"fetching": "Recherche de courses ouvertes…",
		"no_connection": "Serveur injoignable — réessayez dans un instant",
		"lobbies_fetched": "Choisissez une course ou créez la vôtre",
		"no_lobbies": "Aucune course ouverte — créez la première !",
		"spectating": "Spectateur — vous courez à la prochaine",
		"lobby_count": "%d / %d sur la grille — départ auto à %d",
		"current_track": "Circuit actuel : %s",
		"waiting_one": "En attente de %d joueur",
		"waiting_many": "En attente de %d joueurs",
		"start_in": "Départ dans %d...",
		"lap": "Tour %d / %d",
		"finished": "Terminé !",
		"finish_in": "Fin de course dans %ds",
		"race_finished": "Course terminée !",
		"could_not_join": "Impossible de rejoindre : %s",
		# --- Join errors ---
		"err_nickname_used": "Pseudo déjà utilisé",
		"err_lobby_full": "Le salon est plein",
		"err_lobby_exists": "Le salon existe déjà",
		"err_lobby_not_found": "Salon introuvable",
		"err_invalid_config": "Configuration de salon invalide",
		"err_invalid_name": "Entrez un nom valide (3–20 caractères)",
		"err_track_not_found": "Circuit introuvable sur le serveur",
		"err_unknown": "Erreur inconnue : %s",
		# --- HUD ---
		"boost_ready": "BOOST PRÊT",
		"hud_controls": "CONTRÔLES",
		"hud_ranking": "CLASSEMENT",
		# --- Settings panel ---
		"set_title": "PARAMÈTRES",
		"set_language": "LANGUE",
		"set_controls": "COMMANDES",
		"set_keyboard": "Clavier",
		"set_gamepad": "Manette",
		"set_press_key": "Appuyez sur une touche...",
		"set_press_button": "Appuyez sur un bouton...",
		"set_reset": "Réinitialiser",
		"set_close": "Fermer",
		"set_unbound": "—",
		# --- Rebindable actions ---
		"act_Throttle": "Accélérer",
		"act_Steering Left": "Tourner à gauche",
		"act_Steering Right": "Tourner à droite",
		"act_Drift": "Drift",
		"act_Turbo": "Turbo",
		"act_Respawn": "Réapparaître",
		"act_Pause": "Pause",
		"act_Back View": "Regard arrière",
		"act_View Left": "Regard gauche",
		"act_View Right": "Regard droit",
		"act_View Up": "Regard haut",
		"act_View Down": "Regard bas",
		# --- Panneau À propos ---
		"about_tagline": "Course de jouets dans des pièces géantes",
		"about_version": "Version",
		"about_build": "Build",
		"about_source": "Code source",
		"about_team": "Créé par",
		"about_team_designer": "P.-A. Goya — design & direction",
		"about_team_claude": "Claude (Opus 4.8) — code & art",
		"about_credits": "Crédits",
		"about_credits_cc0": "Voitures — Kenney « Car Kit » — CC0 (domaine public), avec gratitude",
		"about_credits_engine": "Moteur — Godot 4.6 (MIT)",
		"about_credits_physics": "Physique — Rapier · rapier3d (Apache-2.0)",
		"about_credits_server": "Serveur — Rust · Tokio · Serde (MIT)",
		"about_credits_art": "Décor, ciel & sons — synthétisés dans le moteur",
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
