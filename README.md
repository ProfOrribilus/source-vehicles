# Driveable Vehicles for Source Engine Multiplayer

This is a SourceMod plugin that allows spawning driveable vehicles based on `prop_vehicle_driveable` in Source engine
multiplayer games.

**List of supported games:**

* Day of Defeat: Source

This plugin bundles the required entity fixes, and a few configurable nice-to-have features.

## Features

* Fully functioning driveable vehicles based on `prop_vehicle_driveable`
* Vehicle sounds
* Entry and exit animations (experimental)
* Physics collisions and damage against other players
* Vehicles are destroyable
* Support for a second passenger who can shoot
* Support for player models as passengers
* Automatic vehicle respawn system
* High customizability through plugin configuration and ConVars

## Dependencies

* SourceMod 1.12
* [LoadSoundScript](https://github.com/haxtonsale/LoadSoundScript) (optional, used for vehicle sounds)

## Installation

1. Download the latest version from the [releases](https://github.com/ProfOrribilus/source-vehicles/releases) page
2. Extract the contents of the ZIP file(s) into your server's game directory
3. Restart your server or type `sm plugins load vehicles` into your server console

## Usage

The easiest way to spawn vehicles is using the `sm_vehicle` command and selecting "Spawn a vehicle" in the menu.
This requires vehicles to be added to the [vehicle configuration](/addons/sourcemod/configs/vehicles/vehicles.cfg).

An automatic vehicles respawn system is present. A TXT file must be created in the server's "dod/resource" folder, with the name "your_map_name_vehicles.txt" where "your_map_name" is the name of the map for which you want to enable the automatic respawn. To create this file use the `sm_vehicle` command and select "Place a vehicle spawner here" in the menu; the file will be created and the respawner is placed where you are standing. Use again the "Place a vehicle spawner here" for each respawner you want to add. At the moment the system doesn't check for obstructions.

If you have access to `ent_create`, you can spawn vehicle entities without having to add them to the configuration.
The plugin automatically detects and hooks any vehicle spawned into the map.
If a configuration entry matches both the vehicle model and vehicle script, its properties will be applied accordingly.

**Example:**

`ent_create prop_vehicle_driveable model "models/buggy.mdl" VehicleScript "scripts/vehicles/jeep_test.txt"`

To enter a vehicle, look at it and use the `+use` console command.

## Configuration

The vehicle configuration allows you to add custom vehicles. Each vehicle requires at least a name, model, vehicle
script, and vehicle type. More documentation and examples can be found in
the [default configuration](/addons/sourcemod/configs/vehicles/vehicles.cfg).

To learn how to create custom vehicle models and scripts, check out
the [Vehicle Scripts for Source](https://steamcommunity.com/sharedfiles/filedetails/?id=1373837962) guide on Steam.

### Example Configuration

```
"Vehicles"
{
	"example_vehicle"
	{
		"name"					"#Vehicle_ExampleVehicle"
		"model"					"models/vehicles/example_vehicle.mdl"
		"script"				"scripts/vehicles/example_vehicle.txt"
		"type"					"car_wheels"
		"soundscript"			"scripts/example_soundscript.txt"
		"skins"					"0,1,2"
		"key_hint"				"#Hint_VehicleKeys_Car"
		"lock_speed"			"10.0"
		"is_passenger_visible"	"1"
		"horn_sound"			"sounds/vehicles/example_horn.wav"
		"downloads"
		{
			"0"	"materials/models/vehicles/example_vehicle.vmt"
			"1"	"materials/models/vehicles/example_vehicle.vtf"
		}
	}
}
```

### ConVars

The plugin creates the following console variables:

* `vehicle_config_path ( def. "configs/vehicles/vehicles.cfg" )` - Path to vehicle configuration file, relative to the SourceMod folder
* `vehicle_physics_damage_modifier ( def. "1.0" )` - Modifier of impact-based physics damage against other players
* `vehicle_passenger_damage_modifier ( def. "1.0" )` - Modifier of damage dealt to vehicle passengers
* `vehicle_enable_entry_exit_anims ( def. "0" )` - If set to 1, enables entry and exit animations (experimental)
* `vehicle_enable_horns ( def. "1" )` - If set to 1, enables vehicle horns

## Entry and Exit Animations

Most vehicles have entry and exit animations that make the player transition between the vehicle and the entry/exit
points. The plugin fully supports these animations.

However, since Valve never intended `prop_vehicle_driveable` to be used outside Half-Life 2, there is code that does not
function properly in a multiplayer environment and can even cause client crashes.

Because of that, entry and exit animations on all vehicles are disabled by default and have to be manually enabled by
setting `vehicle_enable_entry_exit_anims` to `1`. If you intend to use this plugin on a public server, it is **highly
recommended** to keep the animations disabled.

## Known issues

1. MGs can't be deployed while being on or inside a car.
2. Nades and rockets launching is disabled for car passengers to avoid some still unresolved glitch.
3. Entering and exiting a vehicle could get the player looking to a different direction.
4. Vehicles sounds sometimes keep looping even if you are not driving them or if they are despawned/destroyed. Use `snd_restart` on your client console to temporarily fix it (thanks to TVoLk for the tip).

## Credits

I wish to thank the following people who helped me in testing this plugin: [Glubtasticon](https://steamcommunity.com/id/Thiagales), [DNA.styks](https://steamcommunity.com/id/DNA-styx), [TVoLk](https://steamcommunity.com/profiles/76561198334480736), [dNky](https://steamcommunity.com/profiles/76561198127634836), [SkOosH](https://steamcommunity.com/profiles/76561197975135063).