/**
 * Copyright (C) 2026  Mikusch and Prof. Orribilus
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <sourcemod>
#include <sdkhooks>
#include <adminmenu>
#include <dhooks>
#include <sdktools>
#include <events>

#pragma semicolon 1
#pragma newdecls required

#undef REQUIRE_EXTENSIONS
#tryinclude <loadsoundscript>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION	"2.4.2 ProfOrribilus-fork-0.1.6" //This plugin is a work derived from the version 2.4.2 of the original one made by Mikusch.
#define PLUGIN_AUTHOR	"Mikusch and Prof. Orribilus"
#define PLUGIN_URL		"https://github.com/ProfOrribilus/source-vehicles"

#define VEHICLE_CLASSNAME "prop_vehicle_driveable"

#define VEHICLEDUMMY_MODELNAME_TEMPLATE "models/vehicles/%s_dummy_%s.mdl"
#define VEHICLEPLAYER_MODELNAME_TEMPLATE "models/player/%s_%s_%s_%s"
#define VEHICLEPLAYER_MODELNAMEWITHSUFFIX_TEMPLATE "models/player/%s_%s_%s_%s-%s"
#define VEHICLESPAWNERS_FILENAME_TEMPLATE "resource/%s_vehicles.txt"

#define COLLISION_GROUP_DEBRIS 1
#define COLLISION_GROUP_VEHICLE	7
#define TFCOLLISION_GROUP_RESPAWNROOMS 25

#define ACTIVITY_NOT_AVAILABLE -1

enum PassengerRole
{
	VEHICLE_ROLE_NONE = -1,
	VEHICLE_ROLE_DRIVER = 0,
	LAST_SHARED_VEHICLE_ROLE,
};

enum VehicleType
{
	VEHICLE_TYPE_CAR_WHEELS = (1 << 0),
	VEHICLE_TYPE_CAR_RAYCAST = (1 << 1),
	VEHICLE_TYPE_JETSKI_RAYCAST = (1 << 2),
	VEHICLE_TYPE_AIRBOAT_RAYCAST = (1 << 3),
};

bool g_LoadSoundscript;

ConVar vehicle_config_path;
ConVar vehicle_physics_damage_modifier;
ConVar vehicle_passenger_damage_modifier;
ConVar vehicle_enable_entry_exit_anims;
ConVar vehicle_enable_horns;

DynamicHook g_DHookShouldCollide;
DynamicHook g_DHookSetPassenger;
DynamicHook g_DHookIsPassengerVisible;
DynamicHook g_DHookHandlePassengerEntry;
DynamicHook g_DHookGetExitAnimToUse;
DynamicHook g_DHookGetInVehicle;
DynamicHook g_DHookLeaveVehicle;
DynamicHook g_DHookCheckExitPoint;

Handle g_SDKCallVehicleSetupMove;
Handle g_SDKCallCanEnterVehicle;
Handle g_SDKCallGetAttachmentLocal;
Handle g_SDKCallGetVehicleEnt;
Handle g_SDKCallHandlePassengerEntry;
Handle g_SDKCallHandlePassengerExit;
Handle g_SDKCallHandleEntryExitFinish;
Handle g_SDKCallStudioFrameAdvance;
Handle g_SDKCallGetInVehicle;
Handle g_SDKCallSetParent;
Handle g_SDKCallSnapEyeAngles;

ArrayList g_AllVehicles;
ArrayList g_VehicleProperties;
ArrayList g_VehicleSpawnerProperties;
ArrayList g_ConVars;

char g_DefaultPlayerModels[2][6][PLATFORM_MAX_PATH];

char g_PlayerModelTeamName[2][PLATFORM_MAX_PATH];
char g_PlayerModelClassName[6][PLATFORM_MAX_PATH];
char g_ModelVehiclePassengerClassName[2][PLATFORM_MAX_PATH];
char g_ModelFileExtensions[6][PLATFORM_MAX_PATH];

int g_ClientTeam[MAXPLAYERS + 1];
bool g_ClientInUse[MAXPLAYERS + 1];
bool g_ClientIsUsingHorn[MAXPLAYERS + 1];
int g_ClientIsInVehicleAsDriver[MAXPLAYERS + 1];
int g_ClientIsInVehicleAsShooter[MAXPLAYERS + 1];
bool g_ClientHasVehicleUseDisabled[MAXPLAYERS + 1];
bool g_ClientHasEyesForced[MAXPLAYERS + 1];

int g_CollisionGroupDefault = -1;
float g_VecViewOffsetDefault[3];
bool g_ExecRoundStartHookFunction;
float g_playerMins[] = {-16.0, -16.0, -36.0};
float g_playerMaxs[] = {16.0, 16.0, 36.0};

enum struct VehicleConfig
{
	char id[256];									/**< Unique identifier of the vehicle */
	char name[256];									/**< Display name of the vehicle */
	char model[PLATFORM_MAX_PATH];					/**< Vehicle model */
	char dummyModel[PLATFORM_MAX_PATH];				/**< Dummy model parented to the vehicle which gives player damage (only needed in DoDS, at the moment) */
	char passengerModelVersion[PLATFORM_MAX_PATH];	/**< Passenger model version (suffix at the end of the model name, before file extension) */
	char script[PLATFORM_MAX_PATH];					/**< Vehicle script path */
	VehicleType type;								/**< The type of vehicle */
	char soundscript[PLATFORM_MAX_PATH];			/**< Custom soundscript */
	ArrayList skins;								/**< Model skins */
	char key_hint[256];								/**< Vehicle key hint */
	float lock_speed;								/**< Vehicle lock speed */
	bool is_passenger_visible;						/**< Whether the passenger is visible */
	char horn_sound[PLATFORM_MAX_PATH];				/**< Custom horn sound */
	
	void ReadConfig(KeyValues kv)
	{
		if (kv.GetSectionName(this.id, sizeof(this.id)))
		{
			char modelFileName[PLATFORM_MAX_PATH];
			char modelFullFileName[PLATFORM_MAX_PATH];

			kv.GetString("name", this.name, sizeof(this.name));

			kv.GetString("model", this.model, sizeof(this.model));
			if (this.model[0] != EOS)
			{
				if (StrContains(this.model, ".mdl") == -1 || (StrContains(this.model, ".mdl") != -1 && StrContains(this.model, ".mdl") != (strlen(this.model) - 4)))
				{
					for (int i = 0; i < 6; i++)
					{
						Format(modelFileName, sizeof(modelFileName), "%s%s", this.model, g_ModelFileExtensions[i]);
						AddFileToDownloadsTable(modelFileName);
					}

					StrCat(this.model, sizeof(this.model), ".mdl");
				}
			}

			kv.GetString("dummy_model", this.dummyModel, sizeof(this.dummyModel));
			if (this.dummyModel[0] != EOS)
			{
				if (StrContains(this.dummyModel, ".mdl") == -1 || (StrContains(this.dummyModel, ".mdl") != -1 && StrContains(this.dummyModel, ".mdl") != (strlen(this.dummyModel) - 4)))
				{
					for (int i = 0; i < 6; i++)
					{
						Format(modelFileName, sizeof(modelFileName), "%s%s", this.dummyModel, g_ModelFileExtensions[i]);
						AddFileToDownloadsTable(modelFileName);
					}

					StrCat(this.dummyModel, sizeof(this.dummyModel), ".mdl");
				}
			}

			kv.GetString("passenger_model_version", this.passengerModelVersion, sizeof(this.passengerModelVersion));
			//kv.GetVector("dummy_driver_origin", this.dummyDriverOrigin);
			kv.GetString("script", this.script, sizeof(this.script));
			
			char type[32];
			kv.GetString("type", type, sizeof(type));
			if (StrEqual(type, "car_wheels"))
				this.type = VEHICLE_TYPE_CAR_WHEELS;
			else if (StrEqual(type, "car_raycast"))
				this.type = VEHICLE_TYPE_CAR_RAYCAST;
			else if (StrEqual(type, "jetski_raycast"))
				this.type = VEHICLE_TYPE_JETSKI_RAYCAST;
			else if (StrEqual(type, "airboat_raycast"))
				this.type = VEHICLE_TYPE_AIRBOAT_RAYCAST;
			else if (type[0] != EOS)
				LogError("%s: Invalid vehicle type '%s'", this.id, type);
			
			kv.GetString("soundscript", this.soundscript, sizeof(this.soundscript));
			if (this.soundscript[0] != EOS)
			{
				if (g_LoadSoundscript)
				{
#if defined _loadsoundscript_included
					SoundScript soundscript = LoadSoundScript(this.soundscript);
					for (int i = 0; i < soundscript.Count; i++)
					{
						SoundEntry entry = soundscript.GetSound(i);
						char soundname[256];
						entry.GetName(soundname, sizeof(soundname));
						PrecacheScriptSound(soundname);
					}
#else
					LogMessage("%s: Failed to load vehicle soundscript '%s' because the plugin was compiled without the LoadSoundscript include", this.id, this.soundscript);
#endif
				}
				else
				{
					LogMessage("%s: Failed to load vehicle soundscript '%s' because the LoadSoundscript extension could not be found", this.id, this.soundscript);
				}
			}
			
			this.skins = new ArrayList();
			
			char skins[128];
			kv.GetString("skins", skins, sizeof(skins), "0");
			
			char split[32][4];
			int retrieved = ExplodeString(skins, ",", split, sizeof(split), sizeof(split[]));
			for (int i = 0; i < retrieved; i++)
			{
				int skin;
				if (TrimString(split[i]) > 0 && StringToIntEx(split[i], skin) > 0)
					this.skins.Push(skin);
			}
			
			this.lock_speed = kv.GetFloat("lock_speed", 10.0);
			kv.GetString("key_hint", this.key_hint, sizeof(this.key_hint));
			this.is_passenger_visible = kv.GetNum("is_passenger_visible", true) != 0;
			
			kv.GetString("horn_sound", this.horn_sound, sizeof(this.horn_sound));
			if (this.horn_sound[0] != EOS)
			{
				char filepath[PLATFORM_MAX_PATH];
				Format(filepath, sizeof(filepath), "sound/%s", this.horn_sound);
				if (FileExists(filepath, true))
				{
					AddFileToDownloadsTable(filepath);
					Format(this.horn_sound, sizeof(this.horn_sound), ")%s", this.horn_sound);
					PrecacheSound(this.horn_sound);
				}
				else
				{
					LogError("%s: The file '%s' does not exist", this.id, filepath);
					this.horn_sound[0] = EOS;
				}
			}
			
			if (kv.JumpToKey("downloads"))
			{
				if (kv.GotoFirstSubKey(false))
				{
					do
					{
						char filename[PLATFORM_MAX_PATH];
						kv.GetString(NULL_STRING, filename, sizeof(filename));
						AddFileToDownloadsTable(filename);
					}
					while (kv.GotoNextKey(false));
					kv.GoBack();
				}
				kv.GoBack();
			}

			//Precaches and adds to downloads table the passengers' models.
			if (this.is_passenger_visible)
			{
				bool foundAllPassengersModels = true;

				for (int i = 0; i < 2; i++)
				{
					for (int j = 0; j < 6; j++)
					{
						for (int k = 0; k < 2; k++)
						{
							if (Format(modelFileName, sizeof(modelFileName), VEHICLEPLAYER_MODELNAME_TEMPLATE, g_PlayerModelTeamName[i], g_PlayerModelClassName[j], this.id, g_ModelVehiclePassengerClassName[k]) > 0)
							{
								if (this.passengerModelVersion[0] != EOS)
								{
									StrCat(modelFileName, sizeof(modelFileName), "-");
									StrCat(modelFileName, sizeof(modelFileName), this.passengerModelVersion);
								}
								Format(modelFullFileName, sizeof(modelFullFileName), "%s%s", modelFileName, ".mdl");

								if (FileExists(modelFullFileName, true))
								{
									PrecacheModel(modelFullFileName);
									for (int l = 0; l < 6; l++)
									{
										Format(modelFullFileName, sizeof(modelFullFileName), "%s%s", modelFileName, g_ModelFileExtensions[l]);
										AddFileToDownloadsTable(modelFullFileName);
									}
								}
								else
								{
									foundAllPassengersModels = false;
								}
							}
							else
							{
								LogError("Vehicle player model name generation failed");
							}
						}
					}
				}

				if (!foundAllPassengersModels)
					LogError("One or more player passenger's models not found for vehicle %s", this.id);
			}
		}
	}
}

enum struct VehicleProperties
{
	int entity;
	int owner;
	int spawner;
	float health;
	int shooter; // The player who enters the vehicle as second passenger.
	int dummyDriver; // The entity spawned to the driver seat of a vehicle when a player enters the vehicle; it will represent the player who is driving to avoid his upper body to follow his aiming.
	int damageDealer; // For DoDS only, at the moment: since, in this game, vehicles' collision with player doesn't work, an invisible model is spawned as prop_dynamic parented to the vehicle's entity which gives damage to run over players.
	int pusher; // The entity which pushes away players who are around the vehicle when it is moving.
	int explosive; // The entity which emits the explosion and damage when the vehicle is destroyed.
	bool destroyed;
}

enum struct VehicleSpawnerProperties
{
	int id;
	char vehicleId[64];
	float position[3];
	float angles[3];
}

enum struct ConVarData
{
	ConVar convar;
	char desiredValue[256];
	char initialValue[256];
}

methodmap Player
{
	public Player(int client)
	{
		return view_as<Player>(client);
	}
	
	property int _client
	{
		public get()
		{
			return view_as<int>(this);
		}
	}
	
	property int Team // This is needed because the GetClientTeam function gives inconsistent values after the player joins spectators team. Used to set the correct player model while he is inside a vehicle.
	{
		public get()
		{
			return g_ClientTeam[this._client];
		}
		
		public set(int value)
		{
			g_ClientTeam[this._client] = value;
		}
	}
	
	property bool InUse
	{
		public get()
		{
			return g_ClientInUse[this._client];
		}
		public set(bool value)
		{
			g_ClientInUse[this._client] = value;
		}
	}
	
	property bool IsUsingHorn
	{
		public get()
		{
			return g_ClientIsUsingHorn[this._client];
		}
		public set(bool value)
		{
			g_ClientIsUsingHorn[this._client] = value;
		}
	}

	property int VehicleIsInAsDriver // Stores which vehicle the player is driving.
	{
		public get()
		{
			return g_ClientIsInVehicleAsDriver[this._client];
		}
		public set(int value)
		{
			g_ClientIsInVehicleAsDriver[this._client] = value;
		}
	}
	
	property int VehicleIsInAsShooter // Store which vehicle the player is the second passenger of.
	{
		public get()
		{
			return g_ClientIsInVehicleAsShooter[this._client];
		}
		public set(int value)
		{
			g_ClientIsInVehicleAsShooter[this._client] = value;
		}
	}

	property bool HasVehicleUseDisabled // Used to prevent erroneous vehicle exiting soon after getting on for second passengers.
	{
		public get()
		{
			return g_ClientHasVehicleUseDisabled[this._client];
		}
		public set(bool value)
		{
			g_ClientHasVehicleUseDisabled[this._client] = value;
		}
	}
	
	property bool HasEyesForced // Used to store if a passenger's aiming has to be forced inside a restricted cone.
	{
		public get()
		{
			return g_ClientHasEyesForced[this._client];
		}
		public set(bool value)
		{
			g_ClientHasEyesForced[this._client] = value;
		}
	}

	public void Reset()
	{
		this.InUse = false;
		this.IsUsingHorn = false;
		this.VehicleIsInAsDriver = -1;
		this.VehicleIsInAsShooter = -1;
		this.HasVehicleUseDisabled = false;
	}
}

methodmap Vehicle
{
	public Vehicle(int entity)
	{
		return view_as<Vehicle>(entity);
	}
	
	property int _entityRef
	{
		public get()
		{
			// Doubly convert it to ensure it is an entity reference
			return EntIndexToEntRef(EntRefToEntIndex(view_as<int>(this)));
		}
	}
	
	property int _listIndex
	{
		public get()
		{
			return g_VehicleProperties.FindValue(this._entityRef, VehicleProperties::entity);
		}
	}
	
	property int Owner
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::owner);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::owner);
		}
	}

	property int Spawner
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::spawner);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::spawner);
		}
	}

	property float Health
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::health);
			
			return -1.0;
		}
		public set(float value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::health);
		}
	}

	property int Shooter
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::shooter);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::shooter);
		}
	}

	property int DummyDriver
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::dummyDriver);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::dummyDriver);
		}
	}

	property int DamageDealer
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::damageDealer);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::damageDealer);
		}
	}

	property int Pusher
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::pusher);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::pusher);
		}
	}

	property int Explosive
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::explosive);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::explosive);
		}
	}

	property bool Destroyed
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::destroyed);
			
			return false;
		}
		public set(bool value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::destroyed);
		}
	}

	public static bool Register(int entity)
	{
		if (!IsValidEntity(entity))
			return false;
		
		// Doubly convert it to ensure it is an entity reference
		entity = EntIndexToEntRef(EntRefToEntIndex(entity));
		
		if (g_VehicleProperties.FindValue(entity, VehicleProperties::entity) == -1)
		{
			VehicleProperties properties;
			properties.entity = entity;
			properties.owner = -1;
			properties.spawner = -1;
			properties.health = -1.0;
			properties.shooter = -1;
			properties.dummyDriver = -1;
			properties.damageDealer = -1;
			properties.pusher = -1;
			properties.explosive = -1;
			properties.destroyed = false;
			
			g_VehicleProperties.PushArray(properties);
		}
		
		return true;
	}
	
	public void Destroy()
	{
		// Delay by one frame to allow subplugins to access data in OnEntityDestroyed
		RequestFrame(RequestFrameCallback_DestroyVehicle, this._entityRef);
	}
};

methodmap VehicleSpawner
{
	public VehicleSpawner(int id)
	{
		return view_as<VehicleSpawner>(id);
	}

	property int _id
	{
		public get()
		{
			return view_as<int>(this);
		}
	}

	property int _listIndex
	{
		public get()
		{
			return g_VehicleSpawnerProperties.FindValue(this._id, VehicleSpawnerProperties::id);
		}
	}

	public int GetVehicleId(char vehicleId[64])
	{
		if (this._listIndex != -1)
			return g_VehicleSpawnerProperties.GetString(this._listIndex, vehicleId, sizeof(vehicleId), VehicleSpawnerProperties::vehicleId);
	}

	public int GetPosition(float position[3])
	{
		if (this._listIndex != -1)
			return g_VehicleSpawnerProperties.GetArray(this._listIndex, position, sizeof(position), VehicleSpawnerProperties::position);
	}

	public int GetAngles(float angles[3])
	{
		if (this._listIndex != -1)
			return g_VehicleSpawnerProperties.GetArray(this._listIndex, angles, sizeof(angles), VehicleSpawnerProperties::angles);
	}

	public static bool Register(int id, char vehicleId[64], float position[3], float angles[3])
	{	
		if (id < 0)
			return false;

		if (g_VehicleSpawnerProperties.FindValue(id, VehicleSpawnerProperties::id) == -1)
		{
			VehicleSpawnerProperties properties;
			properties.id = id;
			properties.vehicleId = vehicleId;
			properties.position = position;
			properties.angles = angles;
			
			g_VehicleSpawnerProperties.PushArray(properties);
		}
		
		return true;
	}
	
	public void Destroy()
	{
		int index = g_VehicleSpawnerProperties.FindValue(this._id, VehicleSpawnerProperties::id);
		if (index != -1)
			g_VehicleSpawnerProperties.Erase(index);
	}
}

public Plugin myinfo =
{
	name = "Driveable Vehicles",
	author = PLUGIN_AUTHOR,
	description = "Fully functioning driveable vehicles.",
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
};

//-----------------------------------------------------------------------------
// SourceMod Forwards
//-----------------------------------------------------------------------------

public void OnPluginStart()
{	
	LoadTranslations("common.phrases");
	LoadTranslations("vehicles.phrases");
	
	// Create plugin convars
	vehicle_config_path = CreateConVar("vehicle_config_path", "configs/vehicles/vehicles.cfg", "Path to vehicle configuration file, relative to the SourceMod folder.");
	vehicle_config_path.AddChangeHook(ConVarChanged_ReloadVehicleConfig);
	vehicle_physics_damage_modifier = CreateConVar("vehicle_physics_damage_modifier", "1.0", "Modifier of impact-based physics damage against other players.", _, true, 0.0);
	vehicle_passenger_damage_modifier = CreateConVar("vehicle_passenger_damage_modifier", "1.0", "Modifier of damage dealt to vehicle passengers.", _, true, 0.0);
	vehicle_enable_entry_exit_anims = CreateConVar("vehicle_enable_entry_exit_anims", "0", "If set to 1, enables entry and exit animations.");
	vehicle_enable_horns = CreateConVar("vehicle_enable_horns", "1", "If set to 1, enables vehicle horns.");
	
	RegAdminCmd("sm_vehicle", ConCmd_OpenVehicleMenu, ADMFLAG_GENERIC, "Open vehicle menu");
	RegAdminCmd("sm_vehicle_create", ConCmd_CreateVehicle, ADMFLAG_GENERIC, "Create new vehicle");
	RegAdminCmd("sm_vehicle_removeaim", ConCmd_RemoveAimTargetVehicle, ADMFLAG_GENERIC, "Remove vehicle at crosshair");
	RegAdminCmd("sm_vehicle_remove", ConCmd_RemovePlayerVehicles, ADMFLAG_GENERIC, "Remove player vehicles");
	RegAdminCmd("sm_vehicle_removeall", ConCmd_RemoveAllVehicles, ADMFLAG_BAN, "Remove all vehicles");
	RegAdminCmd("sm_vehicle_reload", ConCmd_ReloadVehicleConfig, ADMFLAG_CONFIG, "Reload vehicle configuration");
	RegAdminCmd("sm_vehicle_placespawner", ConCmd_PlaceVehicleSpawnerHere, ADMFLAG_CONFIG, "Place a vehicle spawner where you are");

	AddCommandListener(CommandListener_VoiceMenu, "voicemenu");
	if (GetEngineVersion() == Engine_DODS)
		AddCommandListener(CommandListener_PlayerJoinTeam, "jointeam");

	g_VehicleProperties = new ArrayList(sizeof(VehicleProperties));
	g_VehicleSpawnerProperties = new ArrayList(sizeof(VehicleSpawnerProperties));
	g_AllVehicles = new ArrayList(sizeof(VehicleConfig));
	g_ConVars = new ArrayList(sizeof(ConVarData));
	
	InitializeVehiclePlayerModelsStrings();
	
	GameData gamedata = new GameData("vehicles");
	if (!gamedata)
		SetFailState("Could not find vehicles gamedata");
	
	CreateDynamicDetour(gamedata, "CPlayerMove::SetupMove", DHookCallback_SetupMovePre);
	g_DHookShouldCollide = CreateDynamicHook(gamedata, "CGameRules::ShouldCollide");
	g_DHookSetPassenger = CreateDynamicHook(gamedata, "CBaseServerVehicle::SetPassenger");
	g_DHookIsPassengerVisible = CreateDynamicHook(gamedata, "CBaseServerVehicle::IsPassengerVisible");
	g_DHookHandlePassengerEntry = CreateDynamicHook(gamedata, "CBaseServerVehicle::HandlePassengerEntry");
	g_DHookGetExitAnimToUse = CreateDynamicHook(gamedata, "CBaseServerVehicle::GetExitAnimToUse");
	g_DHookGetInVehicle = CreateDynamicHook(gamedata, "CBasePlayer::GetInVehicle");
	g_DHookLeaveVehicle = CreateDynamicHook(gamedata, "CBasePlayer::LeaveVehicle");
	g_DHookCheckExitPoint = CreateDynamicHook(gamedata, "CBaseServerVehicle::CheckExitPoint");
	CreateDynamicDetour(gamedata, "CPointPush::PushEntity", DHookCallback_PushEntity);
	 
	g_SDKCallVehicleSetupMove = PrepSDKCall_VehicleSetupMove(gamedata);
	g_SDKCallCanEnterVehicle = PrepSDKCall_CanEnterVehicle(gamedata);
	g_SDKCallGetAttachmentLocal = PrepSDKCall_GetAttachmentLocal(gamedata);
	g_SDKCallGetVehicleEnt = PrepSDKCall_GetVehicleEnt(gamedata);
	g_SDKCallHandlePassengerEntry = PrepSDKCall_HandlePassengerEntry(gamedata);
	g_SDKCallHandlePassengerExit = PrepSDKCall_HandlePassengerExit(gamedata);
	g_SDKCallHandleEntryExitFinish = PrepSDKCall_HandleEntryExitFinish(gamedata);
	g_SDKCallStudioFrameAdvance = PrepSDKCall_StudioFrameAdvance(gamedata);
	g_SDKCallGetInVehicle = PrepSDKCall_GetInVehicle(gamedata);
	g_SDKCallSetParent = PrepSDKCall_SetParent(gamedata);
	g_SDKCallSnapEyeAngles = PrepSDKCall_SnapEyeAngles(gamedata);

	delete gamedata;
	
	// Hook all clients
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			OnClientPutInServer(client);
	}
}

public void OnPluginEnd()
{
	OnMapEnd();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("vehicles");
	
	CreateNative("Vehicle.Create", NativeCall_VehicleCreate);
	CreateNative("Vehicle.Owner.get", NativeCall_VehicleOwnerGet);
	CreateNative("Vehicle.Owner.set", NativeCall_VehicleOwnerSet);
	CreateNative("Vehicle.GetId", NativeCall_VehicleGetId);
	CreateNative("Vehicle.ForcePlayerIn", NativeCall_VehicleForcePlayerIn);
	CreateNative("Vehicle.ForcePlayerOut", NativeCall_VehicleForcePlayerOut);
	CreateNative("GetVehicleName", NativeCall_GetVehicleName);
	
	MarkNativeAsOptional("LoadSoundScript");
	
	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	g_LoadSoundscript = LibraryExists("LoadSoundscript");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "LoadSoundscript"))
	{
		g_LoadSoundscript = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "LoadSoundscript"))
	{
		g_LoadSoundscript = false;
	}
}

public void OnMapStart()
{
	DHookGamerulesObject();

	if (GetEngineVersion() == Engine_DODS)
	{
		HookEvent("dod_round_start", EventHook_RoundStart);
		HookEvent("dod_round_active", EventHook_RoundActive);
		HookEvent("dod_round_restart_seconds", EventHook_PreRoundRestart);
		HookEvent("dod_round_win", EventHook_PreRoundRestart);
	}
	else
	{
		// Hook all vehicles
		int vehicle = -1;
		while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
		{
			Vehicle.Register(vehicle);
			
			SDKHook(vehicle, SDKHook_Think, SDKHookCB_PropVehicleDriveable_Think);
			SDKHook(vehicle, SDKHook_Use, SDKHookCB_PropVehicleDriveable_Use);
			SDKHook(vehicle, SDKHook_OnTakeDamage, SDKHookCB_PropVehicleDriveable_OnTakeDamage);
			SDKHook(vehicle, SDKHook_OnTakeDamagePost, SDKHookCB_PropVehicleDriveable_OnTakeDamagePost);
			
			DHookVehicle(GetServerVehicle(vehicle));
		}
	}
}

public void OnMapEnd()
{
	RestoreConVar("tf_allow_player_use");
	RestoreConVar("sv_turbophysics");
}

public void OnConfigsExecuted()
{
	SetupConVar("tf_allow_player_use", "1");
	SetupConVar("sv_turbophysics", "0");

	ReadVehicleConfig();
}

public void OnClientPutInServer(int client)
{
	DHookClient(client);

	Player(client).Reset();

	HookEvent("player_team", EventCallback_PlayerTeam, EventHookMode_Post);
	HookEvent("player_death", EventCallback_PlayerDeath, EventHookMode_Pre);
	
	if (g_CollisionGroupDefault == -1)
	{
		g_CollisionGroupDefault = GetEntProp(client, Prop_Send, "m_CollisionGroup");
		g_VecViewOffsetDefault[0] = GetEntPropFloat(client, Prop_Send, "m_vecViewOffset[0]");
		g_VecViewOffsetDefault[1] = GetEntPropFloat(client, Prop_Send, "m_vecViewOffset[1]");
		g_VecViewOffsetDefault[2] = GetEntPropFloat(client, Prop_Send, "m_vecViewOffset[2]");
	}
}

public void OnClientDisconnect(int client)
{
	if (Player(client).VehicleIsInAsDriver != -1)
	{
		if (Vehicle(Player(client).VehicleIsInAsDriver).DummyDriver != -1)
		{
			AcceptEntityInput(Vehicle(Player(client).VehicleIsInAsDriver).DummyDriver, "ClearParent");
			RemoveEntity(Vehicle(Player(client).VehicleIsInAsDriver).DummyDriver);
			Vehicle(Player(client).VehicleIsInAsDriver).DummyDriver = -1;
		}

		Player(client).VehicleIsInAsDriver = -1;
	}
	
	if (Player(client).VehicleIsInAsShooter != -1)
	{
		Vehicle(Player(client).VehicleIsInAsShooter).Shooter = -1;
		Player(client).VehicleIsInAsShooter = -1;
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	Action actionToReturn = Plugin_Continue;

	if (Player(client).InUse)
	{
		Player(client).InUse = false;
		buttons |= IN_USE;
		actionToReturn = Plugin_Changed;
	}
	
	if (vehicle_enable_horns.BoolValue)
	{
		int vehicle = GetEntPropEnt(client, Prop_Data, "m_hVehicle");
		if (vehicle != -1)
		{
			VehicleConfig config;
			if (GetConfigByVehicleEnt(vehicle, config) && config.horn_sound[0] != EOS)
			{
				if (buttons & IN_ATTACK3)
				{
					if (!Player(client).IsUsingHorn)
					{
						Player(client).IsUsingHorn = true;
						EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT);
					}
				}
				else if (g_ClientIsUsingHorn[client])
				{
					Player(client).IsUsingHorn = false;
					EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT, SND_STOP | SND_STOPLOOPING);
				}
			}
			
			if (GetEngineVersion() == Engine_DODS) // Prevents handbrake use in DoDS since it crashes the server.
			{
				if (buttons & IN_JUMP)
				{
					buttons = buttons & ~(buttons & IN_JUMP);
					actionToReturn = Plugin_Changed;
				}				
			}
		}
	}
	
	if (Player(client).VehicleIsInAsShooter != -1)
	{
		if (buttons & IN_ATTACK) // Prevents nades to be launched from vehicle because the launch direction is bugged.
		{
			char weaponName[32];
			GetClientWeapon(client, weaponName, sizeof(weaponName));
			
			if (StrEqual(weaponName, "weapon_riflegren_us") || StrEqual(weaponName, "weapon_smoke_us") || StrEqual(weaponName, "weapon_frag_us") || StrEqual(weaponName, "weapon_bazooka") ||
				StrEqual(weaponName, "weapon_riflegren_ger") || StrEqual(weaponName, "weapon_smoke_ger") || StrEqual(weaponName, "weapon_frag_ger") || StrEqual(weaponName, "weapon_pschreck"))
				buttons = buttons & ~(buttons & IN_ATTACK);
			
			actionToReturn = Plugin_Changed;
		}

		if (buttons & IN_ATTACK2) // Prevents MGs to be deployed in vehicle because it doesn't work.
		{
			char weaponName[32];
			GetClientWeapon(client, weaponName, sizeof(weaponName));
			
			if (StrEqual(weaponName, "weapon_30cal") || StrEqual(weaponName, "weapon_mg42"))
				buttons = buttons & ~(buttons & IN_ATTACK2);
			
			actionToReturn = Plugin_Changed;
		}
	}
		
	return actionToReturn;
}


public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{	
	if (Player(client).HasEyesForced) // If enabled, forces player aiming in a restricted cone.
	{
		float vehicleLocalEyesOrigin[3];
		float vehicleLocalEyesAngles[3];
		
		if (SDKCall_GetAttachmentLocal(Player(client).VehicleIsInAsShooter, LookupEntityAttachment(Player(client).VehicleIsInAsShooter, "vehicle_shooter_eyes"), vehicleLocalEyesOrigin, vehicleLocalEyesAngles))
			ForceClientEyeDirectionInCone(client, vehicleLocalEyesAngles, angles, 89.0);
	}
}
				
public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, VEHICLE_CLASSNAME))
	{
		Vehicle.Register(entity);
		
		SDKHook(entity, SDKHook_Think, SDKHookCB_PropVehicleDriveable_Think);
		SDKHook(entity, SDKHook_Use, SDKHookCB_PropVehicleDriveable_Use);
		SDKHook(entity, SDKHook_OnTakeDamage, SDKHookCB_PropVehicleDriveable_OnTakeDamage);
		SDKHook(entity, SDKHook_OnTakeDamagePost, SDKHookCB_PropVehicleDriveable_OnTakeDamagePost);
		SDKHook(entity, SDKHook_Spawn, SDKHookCB_PropVehicleDriveable_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_PropVehicleDriveable_SpawnPost);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity == -1)
		return;
	
	if (IsEntityVehicle(entity))
	{
		if (Vehicle(entity).Shooter != -1)
			GetShooterOutFromVehicle(Vehicle(entity).Shooter, true);
		
		if (Vehicle(entity).DummyDriver != -1)
			if (IsValidEntity(Vehicle(entity).DummyDriver))
				RemoveEntity(Vehicle(entity).DummyDriver);
		
		if (Vehicle(entity).DamageDealer != -1)
			if (IsValidEntity(Vehicle(entity).DamageDealer))
				RemoveEntity(Vehicle(entity).DamageDealer);
		
		if (Vehicle(entity).Pusher != -1)
			if (IsValidEntity(Vehicle(entity).Pusher))
				RemoveEntity(Vehicle(entity).Pusher);
		
		if (Vehicle(entity).Explosive != -1)
			if (IsValidEntity(Vehicle(entity).Explosive))
				RemoveEntity(Vehicle(entity).Explosive);
		
		Vehicle(entity).Destroy();
		SDKCall_HandleEntryExitFinish(GetServerVehicle(entity), true, true);
	}
}

//-----------------------------------------------------------------------------
// Plugin Functions
//-----------------------------------------------------------------------------

int CreateVehicle(VehicleConfig config, float origin[3], float angles[3], int owner = -1, int spawner = -1)
{
	int vehicle = CreateVehicleNoSpawn(config, origin, angles, owner, spawner);

	DispatchSpawn(vehicle);
	
	AcceptEntityInput(vehicle, "HandBrakeOn");

	return vehicle;
}

int CreateVehicleNoSpawn(VehicleConfig config, float origin[3], float angles[3], int owner, int spawner)
{
	int vehicle = CreateEntityByName(VEHICLE_CLASSNAME);
	
	char targetname[256];
	Format(targetname, sizeof(targetname), "%s_%d", config.id, vehicle);

	DispatchKeyValue(vehicle, "targetname", targetname);
	DispatchKeyValue(vehicle, "model", config.model);
	DispatchKeyValue(vehicle, "vehiclescript", config.script);
	DispatchKeyValue(vehicle, "spawnflags", "1"); // SF_PROP_VEHICLE_ALWAYSTHINK
	DispatchKeyValueVector(vehicle, "origin", origin);
	DispatchKeyValueVector(vehicle, "angles", angles);
	SetEntProp(vehicle, Prop_Data, "m_nSkin", (config.skins.Length == 1 ? config.skins.Get(0) : config.skins.Get(GetRandomInt(0, config.skins.Length - 2))));
	SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
	
	Vehicle(vehicle).Owner = owner;
	Vehicle(vehicle).Spawner = spawner;
	Vehicle(vehicle).Health = 100.0;

	return vehicle;	
}

bool GetClientViewPos(int client, int entity, int mask, float position[3], float angles[3])
{
	GetClientEyePosition(client, position);
	GetClientEyeAngles(client, angles);
	
	if (TR_PointOutsideWorld(position))
		return false;
	
	// Get end position
	TR_TraceRayFilter(position, angles, mask, RayType_Infinite, TraceEntityFilter_DontHitEntity, client);
	TR_GetEndPosition(position);
	
	// Adjust for hull of passed in entity
	if (entity != -1)
	{
		float mins[3], maxs[3];
		GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
		GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
		
		TR_TraceHullFilter(position, position, mins, maxs, mask, TraceEntityFilter_DontHitEntity, client);
		TR_GetEndPosition(position);
	}
	
	// Ignore angle on the x-axis
	angles[0] = 0.0;
	
	return true;
}

void PrintKeyHintText(int client, const char[] format, any...)
{
	char buffer[256];
	SetGlobalTransTarget(client);
	VFormat(buffer, sizeof(buffer), format, 3);
	
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("KeyHintText", client));
	bf.WriteByte(1);	// One message
	bf.WriteString(buffer);
	EndMessage();
}

void V_swap(int &x, int &y)
{
	int temp = x;
	x = y;
	y = temp;
}

bool IsEntityClient(int client)
{
	return 0 < client <= MaxClients;
}

bool IsEntityVehicle(int entity)
{
	char classname[32];
	return IsValidEntity(entity) && GetEntityClassname(entity, classname, sizeof(classname)) && StrEqual(classname, VEHICLE_CLASSNAME);
}

bool IsInAVehicle(int client)
{
	return GetEntPropEnt(client, Prop_Data, "m_hVehicle") != -1;
}

Address GetServerVehicle(int vehicle)
{
	static int offset = -1;
	if (offset == -1)
		FindDataMapInfo(vehicle, "m_pServerVehicle", _, _, offset);
	
	if (offset == -1)
	{
		LogError("Unable to find offset 'm_pServerVehicle'");
		return Address_Null;
	}
	
	return view_as<Address>(GetEntData(vehicle, offset));
}

bool IsOverturned(int vehicle)
{
	float angles[3];
	GetEntPropVector(vehicle, Prop_Data, "m_angAbsRotation", angles);
	
	float up[3];
	GetAngleVectors(angles, NULL_VECTOR, NULL_VECTOR, up);
	
	float upDot = GetVectorDotProduct({ 0.0, 0.0, 1.0 }, up);
	
	// Tweak this number to adjust what's considered "overturned"
	if (upDot < 0.0)
		return true;
	
	return false;
}

// This is pretty much an exact copy of CPropVehicleDriveable::CanEnterVehicle
bool CanEnterVehicle(int client, int vehicle)
{
	// Prevent entering if the vehicle's being drived by a player
	int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	if (driver != -1 && driver != client)
		return false;
	
	if (IsOverturned(vehicle))
		return false;
	
	// Prevent entering if the vehicle's locked, or if it's moving too fast.
	return !GetEntProp(vehicle, Prop_Data, "m_bLocked") && GetEntProp(vehicle, Prop_Data, "m_nSpeed") <= GetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit");
}

void ReadVehicleConfig()
{
	// Clear previously loaded vehicles
	g_AllVehicles.Clear();
	
	// Build path to config file
	char file[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	vehicle_config_path.GetString(file, sizeof(file));
	BuildPath(Path_SM, path, sizeof(path), file);
	
	// Read the vehicle configuration
	KeyValues kv = new KeyValues("Vehicles");
	if (kv.ImportFromFile(path))
	{
		//Read through every Vehicle
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				VehicleConfig config;
				config.ReadConfig(kv);
				g_AllVehicles.PushArray(config);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
		
		LogMessage("Successfully loaded %d vehicles from configuration", g_AllVehicles.Length);
	}
	else
	{
		LogError("Failed to import configuration file: %s", file);
	}
	delete kv;
}

bool GetConfigById(const char[] id, VehicleConfig buffer)
{
	int index = g_AllVehicles.FindString(id);
	if (index != -1)
		return g_AllVehicles.GetArray(index, buffer, sizeof(buffer)) > 0;
	
	return false;
}

bool GetConfigByModel(const char[] model, VehicleConfig buffer)
{
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		if (g_AllVehicles.GetArray(i, buffer, sizeof(buffer)) > 0)
		{
			if (StrEqual(model, buffer.model))
				return true;
		}
	}
	
	return false;
}

bool GetConfigByModelAndVehicleScript(const char[] model, const char[] vehiclescript, VehicleConfig buffer)
{
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		if (g_AllVehicles.GetArray(i, buffer, sizeof(buffer)) > 0)
		{
			if (StrEqual(model, buffer.model) && StrEqual(vehiclescript, buffer.script))
				return true;
		}
	}
	
	return false;
}

bool GetConfigByVehicleEnt(int vehicle, VehicleConfig buffer)
{
	char model[PLATFORM_MAX_PATH], vehiclescript[PLATFORM_MAX_PATH];
	GetEntPropString(vehicle, Prop_Data, "m_ModelName", model, sizeof(model));
	GetEntPropString(vehicle, Prop_Data, "m_vehicleScript", vehiclescript, sizeof(vehiclescript));
	
	return GetConfigByModelAndVehicleScript(model, vehiclescript, buffer);
}

void SetupConVar(const char[] name, const char[] desiredValue)
{
	ConVar convar = FindConVar(name);
	if (convar)
	{
		ConVarData data;
		data.convar = convar;
		strcopy(data.desiredValue, sizeof(data.desiredValue), desiredValue);
		
		// Store the current value and override it
		convar.GetString(data.initialValue, sizeof(data.initialValue));
		convar.SetString(data.desiredValue);
		
		// Register change hook afterwards
		convar.AddChangeHook(ConVarChanged_EnforceValue);
		
		g_ConVars.PushArray(data, sizeof(data));
	}
}

void RestoreConVar(const char[] name)
{
	ConVar convar = FindConVar(name);
	if (convar)
	{
		int index = g_ConVars.FindValue(convar, ConVarData::convar);
		if (index != -1)
		{
			ConVarData data;
			if (g_ConVars.GetArray(index, data, sizeof(data)) > 0)
			{
				// Restore the initial value
				data.convar.RemoveChangeHook(ConVarChanged_EnforceValue);
				data.convar.SetString(data.initialValue);
				
				g_ConVars.Erase(index);
			}
		}
	}
}

void InitializeVehiclePlayerModelsStrings()
{
	g_PlayerModelTeamName[0] = "american";
	g_PlayerModelTeamName[1] = "german";

	g_PlayerModelClassName[0] = "rifleman";
	g_PlayerModelClassName[1] = "assault";
	g_PlayerModelClassName[2] = "support";
	g_PlayerModelClassName[3] = "sniper";
	g_PlayerModelClassName[4] = "mg";
	g_PlayerModelClassName[5] = "rocket";

	g_ModelVehiclePassengerClassName[0] = "driver";
	g_ModelVehiclePassengerClassName[1] = "shooter";

	g_ModelFileExtensions[0] = ".dx80.vtx";
	g_ModelFileExtensions[1] = ".dx90.vtx";
	g_ModelFileExtensions[2] = ".mdl";
	g_ModelFileExtensions[3] = ".phy";
	g_ModelFileExtensions[4] = ".sw.vtx";
	g_ModelFileExtensions[5] = ".vvd";
}

// Sets the player model for vehicle passengers corresponding to his team and class.
void SetEntityModelForVehicle(int entity, int client, char passengerTypeName[16], VehicleConfig vehicleConfig)
{
	int clientTeam = (Player(client).Team - 2);
	int clientClass = GetEntProp(client, Prop_Send, "m_iPlayerClass");
	GetClientModel(client, g_DefaultPlayerModels[clientTeam][clientClass], sizeof(g_DefaultPlayerModels[clientTeam][clientClass]));
	
	char modelName[PLATFORM_MAX_PATH];
	char modelFullName[PLATFORM_MAX_PATH];

	if (vehicleConfig.passengerModelVersion[0] == EOS)
		Format(modelName, sizeof(modelName), VEHICLEPLAYER_MODELNAME_TEMPLATE, g_PlayerModelTeamName[clientTeam], g_PlayerModelClassName[clientClass], vehicleConfig.id, passengerTypeName);
	else
		Format(modelName, sizeof(modelName), VEHICLEPLAYER_MODELNAMEWITHSUFFIX_TEMPLATE, g_PlayerModelTeamName[clientTeam], g_PlayerModelClassName[clientClass], vehicleConfig.id, passengerTypeName, vehicleConfig.passengerModelVersion);
	
	Format(modelFullName, sizeof(modelFullName), "%s.mdl", modelName);
	if (FileExists(modelFullName, true))
		SetEntityModel(entity, modelFullName);
	else
		LogError("Vehicle passenger's model setup failed for client %i (missing model: %s)", client, modelFullName);
}

// Revert player model to his default one. Used when a player exits a vehicle. The default model is retrieved from a global array which is populated by the SetEntityModelForVehicle function.
void RevertClientModelToDefault(int client)
{
	int clientTeam = (Player(client).Team - 2);
	int clientClass;
	clientClass = GetEntProp(client, Prop_Send, "m_iPlayerClass");
	
	if (StrContains(g_DefaultPlayerModels[clientTeam][clientClass],".mdl"))
		SetEntityModel(client, g_DefaultPlayerModels[clientTeam][clientClass]);
}

void ForceClientEyeDirectionInCone(int client, float vehicleClientLocalEyesAngles[3], const float clientDesiredAngles[3], float coneAngle)
{
	float desiredClientEyesDirection[3];
	float vehicleClientEyesDirection[3];
	float vehicleClientEyesUpDirection[3];
	
	GetAngleVectors(clientDesiredAngles, desiredClientEyesDirection, NULL_VECTOR, NULL_VECTOR);
	GetAngleVectors(vehicleClientLocalEyesAngles, vehicleClientEyesDirection, NULL_VECTOR, vehicleClientEyesUpDirection);				
	
	if (!IsVectorInCone(desiredClientEyesDirection, vehicleClientEyesDirection, coneAngle))
	{
		float lerpedClientEyesDirection[3];
		float lerpedClientEyesAngles[3];
		
		float angle = AngleBetweenVectors(vehicleClientEyesDirection, desiredClientEyesDirection);
		angle = RadToDeg(angle);
		VectorsLerp(vehicleClientEyesDirection, desiredClientEyesDirection, (coneAngle / angle), lerpedClientEyesDirection);
		GetVectorAngles(lerpedClientEyesDirection, lerpedClientEyesAngles);
		
		SDKCall_SnapEyeAngles(client, lerpedClientEyesAngles); // Used SnapEyeAngles instead of TeleportEntity because the latter interrupts player commands like weapon firing.
	}
}

// Makes a player enter a vehicle as second passenger.
bool GetShooterInVehicle(int shooter, int vehicle)
{
	float vehicleFeet1Origin[3];
	float vehicleFeet1Angles[3];
	int attachment;
	
	if ((attachment = LookupEntityAttachment(vehicle, "vehicle_shooter_feet")) > 0)
	{
		float shooterViewOffsetForVehicle[3];
		AddVectors(g_VecViewOffsetDefault, { 0.0, 0.0, 12.0 }, shooterViewOffsetForVehicle);
		SetEntPropFloat(shooter, Prop_Send, "m_vecViewOffset[0]", shooterViewOffsetForVehicle[0]);
		SetEntPropFloat(shooter, Prop_Send, "m_vecViewOffset[1]", shooterViewOffsetForVehicle[1]);
		SetEntPropFloat(shooter, Prop_Send, "m_vecViewOffset[2]", shooterViewOffsetForVehicle[2]);
		
		GetEntityAttachment(vehicle, attachment, vehicleFeet1Origin, vehicleFeet1Angles);
		TeleportEntity(shooter, vehicleFeet1Origin);
		SDKCall_SetParent(shooter, vehicle, attachment); // I use here an SDK call to CBaseEntity::SetParent because if i use a SetParent entity input some position issues occur in DoD:S. I use it even on other cases because i can refer the entity with its id number instead of its targetname.

		Player(shooter).VehicleIsInAsShooter = vehicle;
		Vehicle(vehicle).Shooter = shooter;
		Player(shooter).HasVehicleUseDisabled = true;
		CreateTimer(2.0, Timer_RestoreUseOnVehicleForShooter, shooter);
		
		VehicleConfig vehicleConfig;
		GetConfigByVehicleEnt(vehicle, vehicleConfig);
		if (vehicleConfig.is_passenger_visible)
			SetEntityModelForVehicle(shooter, shooter, "shooter", vehicleConfig);
		
		return true;
	}
	else
	{
		return false;
	}
}

// An alternative to the game's CheckExitPoint function
bool CheckExitPoint(float vecStartPosition[3], float vecStartAngles[3], float vecSoldierMins[3], float vecSoldierMaxs[3], float vecFoundExitPoint[3])
{
	float soldierHeight;
	float soldierWidth;
	float vecObstructionCheckPosition[3];
	float vecVehicleUpDirection[3];
	float vecVehicleBackwardDirection[3];
	float vecTraceStartOffset[] = {0.0, 0.0, 0.0};
	float vecTraceStart[3];
	float vecTraceEnd[3];
	Handle trace;
	bool traceDidHit;
	bool exitPointFound = false;
	
	soldierHeight = (vecSoldierMaxs[2] - vecSoldierMins[2]);
	soldierWidth = (vecSoldierMaxs[0] - vecSoldierMins[0]);
	
	vecTraceStartOffset[2] = (soldierHeight / 2);

	GetAngleVectors(vecStartAngles, vecVehicleBackwardDirection, NULL_VECTOR, vecVehicleUpDirection);
	NegateVector(vecVehicleBackwardDirection);
	ScaleVector(vecVehicleUpDirection, (soldierHeight + 8.0));
	ScaleVector(vecVehicleBackwardDirection, (soldierWidth + 8.0));
	
	vecObstructionCheckPosition = vecStartPosition;
	for (int i = 1; i <= 8; i++)
	{
		if (i == 5)
		{
			vecObstructionCheckPosition = vecStartPosition;
			AddVectors(vecObstructionCheckPosition, vecVehicleUpDirection, vecObstructionCheckPosition);
		}
		
		AddVectors(vecObstructionCheckPosition, vecTraceStartOffset, vecTraceStart);
		AddVectors(vecTraceStart, {0.0, 0.0, 1.0}, vecTraceEnd);
		TR_TraceHull(vecTraceStart, vecTraceEnd, vecSoldierMins, vecSoldierMaxs, MASK_PLAYERSOLID);
		traceDidHit = TR_DidHit(INVALID_HANDLE);
		
		if (!(traceDidHit))
		{
			exitPointFound = true;
			vecFoundExitPoint = vecObstructionCheckPosition;
			break;
		}
		else
		{
			AddVectors(vecObstructionCheckPosition, vecVehicleBackwardDirection, vecObstructionCheckPosition);
			CloseHandle(trace);
		}
	}
	
	CloseHandle(trace);
	return exitPointFound;
}

void GetShooterOutFromVehicle(int shooter, bool forced)
{
	if (shooter != -1)
	{
		int vehicle = Player(shooter).VehicleIsInAsShooter;
		
		if (vehicle != -1)
		{	
			float vecVehicleExitOrigin[3];
			float vecVehicleExitAngles[3];
			char attachments[][64] = {"exit2", "exit1"};
			for (int i = 0; i < sizeof(attachments); i++)
			{
				if (GetEntityAttachment(vehicle, LookupEntityAttachment(vehicle, attachments[i]), vecVehicleExitOrigin, vecVehicleExitAngles))
				{
					float exitPoint[3];
					bool IsExitPointFound = CheckExitPoint(vecVehicleExitOrigin, vecVehicleExitAngles, g_playerMins, g_playerMaxs, exitPoint);
					if (IsExitPointFound || forced)
					{
						Player(shooter).HasEyesForced = false;
						AcceptEntityInput(shooter, "ClearParent");
						SetEntPropFloat(shooter, Prop_Send, "m_vecViewOffset[0]", g_VecViewOffsetDefault[0]);
						SetEntPropFloat(shooter, Prop_Send, "m_vecViewOffset[1]", g_VecViewOffsetDefault[1]);
						SetEntPropFloat(shooter, Prop_Send, "m_vecViewOffset[2]", g_VecViewOffsetDefault[2]);

						if (IsExitPointFound)
						{	
							exitPoint[2] = exitPoint[2] + 12.0;
							GetClientAbsAngles(shooter, vecVehicleExitAngles);
							vecVehicleExitAngles[2] = 0.0;
							TeleportEntity(shooter, exitPoint, vecVehicleExitAngles);
						}
						
						Vehicle(Player(shooter).VehicleIsInAsShooter).Shooter = -1;
						Player(shooter).VehicleIsInAsShooter = -1;
						Player(shooter).HasVehicleUseDisabled = false;
						
						VehicleConfig vehicleConfig;
						GetConfigByVehicleEnt(vehicle, vehicleConfig);
						if (vehicleConfig.is_passenger_visible)
							RevertClientModelToDefault(shooter);

						break;		
					}
				}
				else
					LogError("Missing '%s' attachment on vehicle %i", attachments[i], vehicle);
			}
		}
	}
}

void SpawnDamageDealerForVehicle(int vehicle, VehicleConfig vehicleConfig)
{
	if (vehicleConfig.dummyModel[0] != EOS)
	{
		float vehicleOrigin[3];
		float vehicleAngles[3];
		GetEntPropVector(vehicle, Prop_Data, "m_vecOrigin", vehicleOrigin);
		GetEntPropVector(vehicle, Prop_Data, "m_angRotation", vehicleAngles);

		if (Vehicle(vehicle).DamageDealer == -1)
		{
			int newEntity = CreateEntityByName("prop_dynamic");
			if (newEntity != -1)
			{
				if (FileExists(vehicleConfig.dummyModel, true))
				{
					DispatchKeyValue(newEntity, "model", vehicleConfig.dummyModel);
					DispatchKeyValueVector(newEntity, "origin", vehicleOrigin);
					DispatchKeyValueVector(newEntity, "angles", vehicleAngles);
					DispatchKeyValueInt(newEntity, "solid", 0);
					SetEntProp(newEntity, Prop_Data, "m_usSolidFlags", (4+8));

					if (DispatchSpawn(newEntity))
					{
						SetEntityMoveType(newEntity, MOVETYPE_FLY);
						SetVariantString("!activator");
						AcceptEntityInput(newEntity, "SetParent", vehicle); //SDKCall_SetParent(newEntity, vehicle, 0);
						SDKHook(newEntity, SDKHook_StartTouchPost, SDKHookCB_VehicleDamageDealer_StartTouchPost);
						SDKHook(newEntity, SDKHook_TouchPost, SDKHookCB_VehicleDamageDealer_TouchPost);

						Vehicle(vehicle).DamageDealer = newEntity;
					}
					else
					{
						LogError("Damage Dealer %s spawning failed for vehicle %i", vehicleConfig.dummyModel, vehicle);
						RemoveEntity(newEntity);
					}
				}
				else
				{
					LogError("Damage Dealer %s creating failed for vehicle %i. Related model missing.", vehicleConfig.dummyModel, vehicle);
				}
			}
		}
	}
}

void SpawnDummyDriverForVehicle(int thisVehicle, int client)
{
	float dummyPosition[3];
	char attachmentName[] = "vehicle_driver_feet";

	if ((LookupEntityAttachment(thisVehicle, attachmentName)) > 0)
	{
		int dummy = CreateEntityByName("prop_dynamic");
		if (dummy != -1)
		{
			char strClient[2];
			IntToString(client, strClient, sizeof(strClient));
			DispatchKeyValue(dummy, "targetname", strClient); // This is used to store which client this entity will be hidden for; that client is the vehicle driver who hasn't to see his own model.

			GetEntPropVector(thisVehicle, Prop_Send, "m_vecOrigin", dummyPosition);
			DispatchKeyValueVector(dummy, "origin", dummyPosition);
			
			DispatchKeyValue(dummy, "model", "models/editor/playerstart.mdl"); // The model here can be anyone.
			
			SetEntProp(dummy, Prop_Data, "m_CollisionGroup", COLLISION_GROUP_DEBRIS); // This sets the dummy driver to debris collision group so that it collides mostly with bullets.
			DispatchKeyValueInt(dummy, "solid", 2);

			SDKHook(dummy, SDKHook_SetTransmit, SDKHookCB_DummyDriver_SetTransmit);

			if (DispatchSpawn(dummy))
			{
				SDKHook(dummy, SDKHook_OnTakeDamage, SDKHookCB_DummyDriver_OnTakeDamage);

				SetVariantString("!activator");
				AcceptEntityInput(dummy, "SetParent", thisVehicle);
				SetVariantString(attachmentName);
				AcceptEntityInput(dummy, "SetParentAttachment");

				Vehicle(thisVehicle).DummyDriver = dummy;
			}
			else
			{
				LogError("Dummy driver spawn failed for vehicle %i", thisVehicle);
				RemoveEntity(dummy);
			}
		}
		else
			LogError("Dummy driver creation failed for vehicle %i", thisVehicle);
	}
	else
		LogError("Dummy driver creation failed due to attachment retrieving failed for vehicle %i", thisVehicle);
}

void SpawnExplosiveForVehicle(int vehicle)
{
	int explosive = CreateEntityByName("env_explosion");
	if (explosive != -1)
	{
		float explosivePosition[3];

		GetEntPropVector(vehicle, Prop_Send, "m_vecOrigin", explosivePosition);
		DispatchKeyValueVector(explosive, "origin", explosivePosition);
		DispatchKeyValueInt(explosive, "iMagnitude", 200);
		DispatchKeyValue(explosive, "fireballsprite", "sprites/zerogxplode.spr");
		DispatchKeyValue(explosive, "rendermode", "5");
		DispatchKeyValue(explosive, "spawnflags", "66");
		
		if (DispatchSpawn(explosive))
		{
			SetVariantString("!activator");
			AcceptEntityInput(explosive, "SetParent", vehicle);

			char attachmentName[] = "explosion";
			if ((LookupEntityAttachment(vehicle, attachmentName)) > 0)
			{
				SetVariantString(attachmentName);
				AcceptEntityInput(explosive, "SetParentAttachment");
			}

			Vehicle(vehicle).Explosive = explosive;
		}
		
	}
}

// Checks if 'angles' rotation values are comprised in a cone having 'coneAngles' rotation values and
// an amplitude expressed as cos('coneDegree') where 'conDegree' is the amplitude expressed as degrees.
// So, if 'cosConeAngle' is 1.0, the cone will correspond to the forward vector of 'coneAngles'; if 'cosConeAngle' is 0, the cone will have an amplitude of 90 degrees.
bool IsVectorInCone(float vector[3], float vectorCone[3], float coneAngle)
{
	float cosConeAngle;
	cosConeAngle = Cosine(DegToRad(coneAngle));
	
	/*
	float vecAnglesForwardDirection[3];
	GetAngleVectors(angles, vecAnglesForwardDirection, NULL_VECTOR, NULL_VECTOR);
	float vecConeAnglesForwardDirection[3];
	GetAngleVectors(coneAngles, vecConeAnglesForwardDirection, NULL_VECTOR, NULL_VECTOR);
	*/
	
	return (GetVectorDotProduct(vector, vectorCone) > cosConeAngle);
}

void VectorsLerp(float vec1[3], float vec2[3], float alpha, float vecResult[3])
{
	float vecDistance[3];
	
	SubtractVectors(vec2, vec1, vecDistance);
	ScaleVector(vecDistance, alpha);
	AddVectors(vec1, vecDistance, vecResult);
}

float GetVectorMagnitude(float vector[3])
{
	return SquareRoot(Pow(vector[0], 2.0) + Pow(vector[1], 2.0) + Pow(vector[2], 2.0));
}

float AngleBetweenVectors(float vec1[3], float vec2[3])
{	
	
	return ArcCosine(GetVectorDotProduct(vec1, vec2) / (GetVectorMagnitude(vec1) * GetVectorMagnitude(vec2)));
}

void StopGameSoundFromEntity(char gamesound[PLATFORM_MAX_PATH], int entity)
{
	int soundChannel;
	int soundLevel;
	float soundVolume;
	int soundPitch;
	char sampleSound[PLATFORM_MAX_PATH];
	int emittingEntityDetected;

	if (GetGameSoundParams(gamesound, soundChannel, soundLevel, soundVolume, soundPitch, sampleSound, sizeof(sampleSound), emittingEntityDetected))	
		EmitSoundToAll(sampleSound, entity, soundChannel, soundLevel, SND_STOP | SND_STOPLOOPING);
}

void StopBuggedSoundsFromVehicle(int vehicle)
{
	StopGameSoundFromEntity("ATV_engine_idle", vehicle);
	StopGameSoundFromEntity("ATV_engine_start", vehicle);
	StopGameSoundFromEntity("ATV_firstgear", vehicle);
	StopGameSoundFromEntity("ATV_turbo_on", vehicle);
	StopGameSoundFromEntity("ATV_throttleoff_slowspeed", vehicle);
	StopGameSoundFromEntity("ATV_reverse", vehicle);
}

void RequestFrameCallback_LeaveVehicle(int exDriver)
{
	int vehicle = Player(exDriver).VehicleIsInAsDriver;

	Player(exDriver).VehicleIsInAsDriver = -1;
	Player(exDriver).HasEyesForced = false;

	if (Vehicle(vehicle).DummyDriver != -1)
	{
		AcceptEntityInput(Vehicle(vehicle).DummyDriver, "ClearParent");
		RemoveEntity(Vehicle(vehicle).DummyDriver);
		Vehicle(vehicle).DummyDriver = -1;
	}

	if (IsValidEdict(exDriver)) // Needed to avoid an error message in the server log if a player is in the vehicle during server's shutdown
	{
		VehicleConfig vehicleConfig;
		GetConfigByVehicleEnt(vehicle, vehicleConfig);

		if (vehicleConfig.is_passenger_visible)
		{
			SetEntityRenderMode(exDriver, RENDER_NORMAL);
			DispatchKeyValueInt(exDriver, "solid", 2);
			RevertClientModelToDefault(exDriver);
		}

		// Teleport the player who is leaving the vehicle basing on the alternate CheckExitPoint function
		float vehicleExitOrigin[3];
		float vehicleExitAngles[3];
		char attachments[][64] = {"exit1", "exit2"};

		for (int i = 0; i < sizeof(attachments); i++)
		{
			if (GetEntityAttachment(vehicle, LookupEntityAttachment(vehicle, attachments[i]), vehicleExitOrigin, vehicleExitAngles))
			{				
				if (i == 0)
				{
					// Offset exit position by an amout which avoids the player colliding with the vehicle
					float vehicleDirectionLeft[3];
					GetAngleVectors(vehicleExitAngles, NULL_VECTOR, vehicleDirectionLeft, NULL_VECTOR);
					NegateVector(vehicleDirectionLeft);
					ScaleVector(vehicleDirectionLeft, 16.0);
					AddVectors(vehicleExitOrigin, vehicleDirectionLeft, vehicleExitOrigin);
				}

				float exitPoint[3];
				bool IsExitPointFound = CheckExitPoint(vehicleExitOrigin, vehicleExitAngles, g_playerMins, g_playerMaxs, exitPoint);
				if (IsExitPointFound)
				{			
					exitPoint[2] = exitPoint[2] + 12.0;
					vehicleExitAngles[2] = 0.0;
					TeleportEntity(exDriver, exitPoint, vehicleExitAngles, NULL_VECTOR);
					break;
				}
			}
			else
				LogError("Missing '%s' attachment on vehicle %i", attachments[i], vehicle);
		}
		//

		StopBuggedSoundsFromVehicle(vehicle);
		
		CreateTimer(0.5, Timer_LeaveVehicle, exDriver);
	}
}

void Timer_LeaveVehicle(Handle timer, int exDriver)
{
	if (!IsFakeClient(exDriver))
		SendConVarValue(exDriver, FindConVar("sv_client_predict"), "1");
}

//-----------------------------------------------------------------------------
// Natives
//-----------------------------------------------------------------------------

public int NativeCall_VehicleCreate(Handle plugin, int numParams)
{
	VehicleConfig config;
	
	char id[256];
	if (GetNativeString(1, id, sizeof(id)) == SP_ERROR_NONE && GetConfigById(id, config))
	{
		float origin[3], angles[3];
		GetNativeArray(2, origin, sizeof(origin));
		GetNativeArray(3, angles, sizeof(angles));
		int owner = GetNativeCell(4);
		
		int vehicle = CreateVehicle(config, origin, angles, owner);
		if (vehicle != -1)
		{
			return vehicle;
		}
		else
		{
			ThrowNativeError(SP_ERROR_NATIVE, "Failed to create vehicle: %s", id);
		}
	}
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid or unknown vehicle: %s", id);
	}
	
	return -1;
}

public int NativeCall_VehicleOwnerGet(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	return Vehicle(vehicle).Owner;
}

public int NativeCall_VehicleOwnerSet(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int owner = GetNativeCell(2);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	Vehicle(vehicle).Owner = owner;
	
	return 0;
}

public int NativeCall_VehicleGetId(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int maxlength = GetNativeCell(3);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	VehicleConfig config;
	if (GetConfigByVehicleEnt(vehicle, config))
	{
		return SetNativeString(2, config.id, maxlength) == SP_ERROR_NONE;
	}
	
	return false;
}

public int NativeCall_VehicleForcePlayerIn(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int client = GetNativeCell(2);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	if (!IsEntityClient(client))
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if (!IsClientInGame(client))
		ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	int clientInVehicle = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	
	if (clientInVehicle == -1)
	{
		SDKCall_HandlePassengerEntry(GetServerVehicle(vehicle), client, true);
	}
	else if (Vehicle(vehicle).Shooter <= 0)
	{
		GetShooterInVehicle(client, vehicle);
	}
	
	return 0;
}

public int NativeCall_VehicleForcePlayerOut(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	
	if (client == -1 && Vehicle(vehicle).Shooter == -1)
		return 0;
	
	GetShooterOutFromVehicle(Vehicle(vehicle).Shooter, true);
	if (client != -1)
		SDKCall_HandlePassengerExit(GetServerVehicle(vehicle), client);
	
	return 0;
}

public int NativeCall_GetVehicleName(Handle plugin, int numParams)
{
	VehicleConfig config;
	
	char id[256];
	if (GetNativeString(1, id, sizeof(id)) == SP_ERROR_NONE && GetConfigById(id, config))
	{
		int maxlength = GetNativeCell(3);
		int bytes;
		return SetNativeString(2, config.name, maxlength, _, bytes) == SP_ERROR_NONE && bytes > 0;
	}
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid or unknown vehicle: %s", id);
	}
	
	return 0;
}

//-----------------------------------------------------------------------------
// Miscellaneous Callbacks
//-----------------------------------------------------------------------------

public void ConVarChanged_ReloadVehicleConfig(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadVehicleConfig();
}

public void ConVarChanged_EnforceValue(ConVar convar, const char[] oldValue, const char[] newValue)
{
	int index = g_ConVars.FindValue(convar, ConVarData::convar);
	if (index != -1)
	{
		ConVarData data;
		if (g_ConVars.GetArray(index, data, sizeof(data)) > 0)
		{
			if (!StrEqual(newValue, data.desiredValue))
			{
				// Update the internal data with the requested value
				strcopy(data.initialValue, sizeof(data.initialValue), newValue);
				g_ConVars.SetArray(index, data, sizeof(data));
				
				// Enforce our desired value
				convar.SetString(data.desiredValue);
			}
		}
	}
}

public Action Timer_PrintVehicleKeyHint(Handle timer, int vehicleRef)
{
	int vehicle = EntRefToEntIndex(vehicleRef);
	if (vehicle != -1)
	{
		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != -1)
		{
			// Show different key hints based on vehicle
			VehicleConfig config;
			if (GetConfigByVehicleEnt(vehicle, config) && config.key_hint[0] != EOS)
			{
				PrintKeyHintText(client, "%t", config.key_hint);
			}
		}
	}
	
	return Plugin_Continue;
}

public Action Timer_RestoreUseOnVehicleForShooter(Handle timer, int client)
{
	Player(client).HasVehicleUseDisabled = false;
	
	return Plugin_Continue;
}

public Action Timer_EnabledClientEyesForced(Handle timer, int client)
{
	Player(client).HasEyesForced = true;
	
	return Plugin_Continue;
}

public void Timer_VehicleRespawner(Handle timer, int vehicle)
{
	if (IsValidEntity(vehicle))
	{
		if (Vehicle(vehicle).Spawner != -1)
		{
			char vehicleId[64];
			float position[3];
			float angles[3];
			VehicleConfig vehicleConfig;

			VehicleSpawner(Vehicle(vehicle).Spawner).GetVehicleId(vehicleId);
			VehicleSpawner(Vehicle(vehicle).Spawner).GetPosition(position);
			VehicleSpawner(Vehicle(vehicle).Spawner).GetAngles(angles);

			if (GetConfigById(vehicleId, vehicleConfig))
			{	
				int spawner = Vehicle(vehicle).Spawner;
				RemoveEntity(vehicle);
				CreateVehicle(vehicleConfig, position, angles, -1, spawner);
			}
		}
	}
}

public void RequestFrameCallback_DestroyVehicle(int entity)
{
	int index = g_VehicleProperties.FindValue(entity, VehicleProperties::entity);
	if (index != -1)
		g_VehicleProperties.Erase(index);
}

public bool TraceEntityFilter_DontHitEntity(int entity, int mask, any data)
{
	return entity != data;
}

//-----------------------------------------------------------------------------
// Commands
//-----------------------------------------------------------------------------

public Action ConCmd_OpenVehicleMenu(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	DisplayMainVehicleMenu(client);
	
	return Plugin_Handled;
}

public Action ConCmd_CreateVehicle(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	if (args == 0)
	{
		DisplayVehicleCreateMenu(client);
		return Plugin_Handled;
	}
	
	char id[256];
	GetCmdArgString(id, sizeof(id));
	
	VehicleConfig config;
	if (!GetConfigById(id, config))
	{
		ReplyToCommand(client, "%t", "#Command_CreateVehicle_Invalid", id);
		return Plugin_Handled;
	}


	int vehicle = CreateVehicle(config, NULL_VECTOR, NULL_VECTOR, client);
	if (vehicle == -1)
	{
		LogError("Failed to create vehicle: %s", id);
		return Plugin_Handled;
	}
	
	float position[3], angles[3];
	if (GetClientViewPos(client, vehicle, (MASK_SOLID | MASK_WATER), position, angles))
	{
		TeleportEntity(vehicle, position, angles);
	}
	else
	{
		RemoveEntity(vehicle);
		LogError("Failed to teleport vehicle: %s", id);
	}
	
	return Plugin_Handled;
}

public Action ConCmd_RemoveAimTargetVehicle(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	int entity = GetClientAimTarget(client, false);
	if (IsEntityVehicle(entity))
	{
		int owner = Vehicle(entity).Owner;
		if (!IsEntityClient(owner) || CanUserTarget(client, owner))
		{
			RemoveEntity(entity);
			ShowActivity2(client, "[SM] ", "%t", "#Command_RemoveVehicle_Success");
		}
		else
		{
			ReplyToCommand(client, "%t", "Unable to target");
		}
	}
	
	return Plugin_Handled;
}

public Action ConCmd_RemovePlayerVehicles(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_vehicle_remove <#userid|name>");
		return Plugin_Handled;
	}
	
	char arg[MAX_TARGET_LENGTH];
	GetCmdArg(1, arg, sizeof(arg));
	
	char target_name[MAX_TARGET_LENGTH];
	int target_list[MAXPLAYERS], target_count;
	bool tn_is_ml;
	
	if ((target_count = ProcessTargetString(arg, client, target_list, sizeof(target_list), COMMAND_TARGET_NONE, target_name, sizeof(target_name), tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}
	
	int vehicle = -1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		int owner = Vehicle(vehicle).Owner;
		if (!IsEntityClient(owner))
			continue;
		
		for (int i = 0; i < target_count; i++)
		{
			int target = target_list[i];
			if (owner == target)
				RemoveEntity(vehicle);
		}
	}
	
	if (tn_is_ml)
	{
		ShowActivity2(client, "[SM] ", "%t", "#Command_RemovePlayerVehicles_Success", target_name);
	}
	else
	{
		ShowActivity2(client, "[SM] ", "%t", "#Command_RemovePlayerVehicles_Success", "_s", target_name);
	}
	
	return Plugin_Handled;
}

public Action ConCmd_RemoveAllVehicles(int client, int args)
{
	int vehicle = -1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		RemoveEntity(vehicle);
	}
	
	ShowActivity2(client, "[SM] ", "%t", "#Command_RemoveAllVehicles_Success");
	
	return Plugin_Handled;
}

public Action ConCmd_ReloadVehicleConfig(int client, int args)
{
	ReadVehicleConfig();
	
	ShowActivity2(client, "[SM] ", "%t", "#Command_ReloadVehicleConfig_Success");
	
	return Plugin_Handled;
}

// Marks the current player position and angles as the place to automaticcaly spawn a vehicle at match start. The place is stored in a file named "<currentmapname>_vehicle.txt" under the game's "resource" folder.
public Action ConCmd_PlaceVehicleSpawnerHere(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	if (args == 0)
	{
		//DisplayVehicleCreateMenu(client);
		ReplyToCommand(client, "Vehicle id not specified");
		return Plugin_Handled;
	}
	
	char id[256];
	GetCmdArgString(id, sizeof(id));
	
	VehicleConfig config;
	if (!GetConfigById(id, config))
	{
		ReplyToCommand(client, "%t", "#Command_CreateVehicle_Invalid", id);
		return Plugin_Handled;
	}
	
	KeyValues kvVehicleSpawners;
	char currentLevelName[64];
	char fileName[PLATFORM_MAX_PATH];
	GetCurrentMap(currentLevelName, sizeof(currentLevelName));
	Format(fileName, sizeof(fileName), VEHICLESPAWNERS_FILENAME_TEMPLATE, currentLevelName);

	kvVehicleSpawners = CreateKeyValues("VehicleSpawners");

	if (FileExists(fileName, false))
	{
		if (!(FileToKeyValues(kvVehicleSpawners, fileName)))
		{
			ReplyToCommand(client, "File %s loading failed", fileName);
			delete kvVehicleSpawners;
			return Plugin_Handled;
		}
	}

	int currentSectionNumber;
	char sectionName[64];

	if (!(KvGotoFirstSubKey(kvVehicleSpawners)))
	{
		currentSectionNumber = 0;
	}
	else
	{
		do
		{
		}
		while(KvGotoNextKey(kvVehicleSpawners));

		KvGetSectionName(kvVehicleSpawners, sectionName, sizeof(sectionName));
		currentSectionNumber = StringToInt(sectionName);
		if (currentSectionNumber == 0 && !(StrEqual(sectionName, "0")))
		{
			ReplyToCommand(client, "Last spawner ID retrieving failed. It isn't a number. Spawner marking cancelled.", fileName);
			delete kvVehicleSpawners;
			return Plugin_Handled;
		}

		currentSectionNumber++;
	}

	IntToString(currentSectionNumber, sectionName, sizeof(sectionName));
	KvGoBack(kvVehicleSpawners);
	KvJumpToKey(kvVehicleSpawners, sectionName, true);
	KvSetString(kvVehicleSpawners, "id", id);

	float position[3];
	float angles[3];
	GetClientAbsOrigin(client, position);
	GetClientEyeAngles(client, angles);

	KvSetVector(kvVehicleSpawners, "position", position);
	KvSetVector(kvVehicleSpawners, "angles", angles);
	KvRewind(kvVehicleSpawners);
	KeyValuesToFile(kvVehicleSpawners, fileName);
	delete kvVehicleSpawners;

	ReplyToCommand(client, "New spawner successful marked as ID %i", currentSectionNumber);

	return Plugin_Handled;
}

public Action CommandListener_VoiceMenu(int client, const char[] command, int args)
{
	char arg1[2], arg2[2];
	GetCmdArg(1, arg1, sizeof(arg1));
	GetCmdArg(2, arg2, sizeof(arg2));
	
	if (GetEngineVersion() == Engine_TF2)
	{
		if (arg1[0] == '0' && arg2[0] == '0')	// MEDIC!
		{
			Player(client).InUse = true;
		}
	}
	
	return Plugin_Continue;
}

public Action CommandListener_PlayerJoinTeam(int client, const char[] command, int argc)
{
	if (Player(client).VehicleIsInAsDriver != -1 || Player(client).VehicleIsInAsShooter != -1)
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

//-----------------------------------------------------------------------------
// SDKHooks
//-----------------------------------------------------------------------------

public void EventHook_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_ExecRoundStartHookFunction = true; // On my side, it seems that RoundStart and RoundActive events hooks are called more than one time in DoDS. To prevent this, i check this boolean variable inside the hook function; the variable is set to false at the end of the RoundActive hook function.
}

public void EventHook_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
	if (g_ExecRoundStartHookFunction)
	{
		KeyValues kvVehicleSpawners;
		char currentLevelName[64];
		char fileName[PLATFORM_MAX_PATH];
		GetCurrentMap(currentLevelName, sizeof(currentLevelName));
		Format(fileName, sizeof(fileName), VEHICLESPAWNERS_FILENAME_TEMPLATE, currentLevelName);

		if (FileExists(fileName, false))
		{
			kvVehicleSpawners = CreateKeyValues("VehicleSpawners");
			if (FileToKeyValues(kvVehicleSpawners, fileName))
			{
				g_VehicleSpawnerProperties.Clear();

				char previousSectionName[64];
				char currentSectionName[64];
				char vehicleId[64];
				float position[3];
				float angles[3];
				VehicleConfig vehicleConfig;

				if (KvGotoFirstSubKey(kvVehicleSpawners, true))
				{
					do
					{
						KvGetSectionName(kvVehicleSpawners, currentSectionName, sizeof(currentSectionName));

						if (!StrEqual(currentSectionName, previousSectionName))
						{
							KvGetString(kvVehicleSpawners, "id", vehicleId, sizeof(vehicleId));
							KvGetVector(kvVehicleSpawners, "position", position);
							KvGetVector(kvVehicleSpawners, "angles", angles);

							if (GetConfigById(vehicleId, vehicleConfig))
							{
								position[2] = position[2] + 5.0;
								angles[0] = 0.0;
								angles[1] = angles[1] - 90.0;
								angles[2] = 0.0;

								int spawner = StringToInt(currentSectionName);
								if (spawner == 0 && !StrEqual(currentSectionName, "0"))
								{
									spawner = -1;
									LogError("Encountered an invalid spawner ID (\"%s\") during vehicles first spawn. It must be a number. The vehicle specified by this spawner ID will not be respawned if destroyed.", currentSectionName);
								}
								else
								{
									VehicleSpawner.Register(spawner, vehicleId, position, angles);
								}

								CreateVehicle(vehicleConfig, position, angles, -1, spawner);
							}
						}

						strcopy(previousSectionName, sizeof(previousSectionName), currentSectionName);
					}
					while(KvGotoNextKey(kvVehicleSpawners, true));
				}
			}

			delete kvVehicleSpawners;
		}

		g_ExecRoundStartHookFunction = false;
	}
}

public void EventHook_PreRoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	int vehicle = -1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		GetShooterOutFromVehicle(Vehicle(vehicle).Shooter, false);
		int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (driver != -1)
			SDKCall_HandlePassengerExit(GetServerVehicle(vehicle), driver);

		AcceptEntityInput(vehicle, "Lock");
	}
}

public Action SDKHookCB_Client_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{	
	Action returnValue = Plugin_Continue;
	
	// Player got damaged inside vehicle
	if (IsEntityClient(attacker) && (IsInAVehicle(victim) || Player(victim).VehicleIsInAsShooter != -1) && attacker != victim)
	{
		damage *= vehicle_passenger_damage_modifier.FloatValue;
		returnValue = Plugin_Changed;
	}
	
	// Player got hit by a vehicle. In games like DoDS this doesn't happen; for them we have the DamageDealer entity parented to every vehicle.
	if (IsEntityVehicle(inflictor))
	{
		if (Vehicle(inflictor).DamageDealer != -1)
		{
			if (damagetype & DMG_VEHICLE)
			{
				int driver = GetEntPropEnt(inflictor, Prop_Data, "m_hPlayer");
				if (driver != -1 && victim != driver)
				{
					damage *= vehicle_physics_damage_modifier.FloatValue;
					attacker = driver;
					returnValue = Plugin_Changed;
				}
			}
		}
	}

	return returnValue;
}

public void SDKHookCB_PropVehicleDriveable_Think(int vehicle)
{
	int sequence = GetEntProp(vehicle, Prop_Data, "m_nSequence");
	bool sequenceFinished = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bSequenceFinished"));
	bool enterAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bEnterAnimOn"));
	bool exitAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bExitAnimOn"));
	
	SDKCall_StudioFrameAdvance(vehicle);
	
	if ((sequence == 0 || sequenceFinished) && (enterAnimOn || exitAnimOn))
	{
		if (enterAnimOn)
		{
			AcceptEntityInput(vehicle, "TurnOn");
			
			CreateTimer(1.5, Timer_PrintVehicleKeyHint, EntIndexToEntRef(vehicle));
		}
		
		SDKCall_HandleEntryExitFinish(GetServerVehicle(vehicle), exitAnimOn, true);
	}
}

public Action SDKHookCB_PropVehicleDriveable_Use(int vehicle, int activator, int caller, UseType type, float value)
{
	if (IsEntityClient(activator))
	{
		int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (driver != -1 && driver == activator)
		{	
			return Plugin_Handled; // Prevent call to ResetUseKey and HandlePassengerEntry for the driving player
		}

		if (Player(activator).HasVehicleUseDisabled)
			return Plugin_Handled;
		else
		{	
			int shooter = Vehicle(vehicle).Shooter;
			if (driver != -1 && shooter <= 0)
			{
				if (GetShooterInVehicle(activator, vehicle))
				{
					return Plugin_Handled;
				}
			}
			else if (shooter > 0 && shooter == activator)
			{
				GetShooterOutFromVehicle(activator, false);
				
				return Plugin_Handled;
			}
		}

	}
	
	return Plugin_Continue;
}

public Action SDKHookCB_PropVehicleDriveable_OnTakeDamage(int vehicle, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{	
	if (!(Vehicle(vehicle).Destroyed))
	{
		if (damagetype != DMG_BLAST)
		{
			damagetype |= DMG_PREVENT_PHYSICS_FORCE;
			Vehicle(vehicle).Health -= damage * 0.025;
			return Plugin_Changed;
		}
		else
			Vehicle(vehicle).Health -= damage;
	}

	return Plugin_Continue;
}

public void SDKHookCB_PropVehicleDriveable_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
	if (!(Vehicle(victim).Destroyed))
	{
		if (Vehicle(victim).Health <= 0)
		{
			Vehicle(victim).Destroyed = true;

			VehicleConfig vehicleConfig;
			
			if (GetConfigByVehicleEnt(victim, vehicleConfig))
			{
				GetShooterOutFromVehicle(Vehicle(victim).Shooter, false);
				int driver = GetEntPropEnt(victim, Prop_Data, "m_hPlayer");
				if (driver != -1)
					SDKCall_HandlePassengerExit(GetServerVehicle(victim), driver);
					
				EmitGameSoundToAll("Weapon_C4.Explode", Vehicle(victim).Explosive, SND_NOFLAGS);
				AcceptEntityInput(Vehicle(victim).Explosive, "Explode");

				if (vehicleConfig.skins.Length > 1)
				{
					SetVariantInt(vehicleConfig.skins.Get(vehicleConfig.skins.Length - 1));
					AcceptEntityInput(victim, "skin");
				}
				else
				{
					SetVariantInt(1);
					AcceptEntityInput(victim, "skin");
				}

				AcceptEntityInput(victim, "TurnOff");
				StopBuggedSoundsFromVehicle(victim);
				AcceptEntityInput(victim, "Lock");

				CreateTimer(15.0, Timer_VehicleRespawner, victim, TIMER_FLAG_NO_MAPCHANGE);
			}
		}
	}
}

public void SDKHookCB_PropVehicleDriveable_Spawn(int vehicle)
{
	char model[PLATFORM_MAX_PATH], vehiclescript[PLATFORM_MAX_PATH];
	GetEntPropString(vehicle, Prop_Data, "m_ModelName", model, sizeof(model));
	GetEntPropString(vehicle, Prop_Data, "m_vehicleScript", vehiclescript, sizeof(vehiclescript));
	
	VehicleConfig config;
	
	// If no script is set, try to find a matching config entry and set it ourselves
	if (vehiclescript[0] == EOS && GetConfigByModel(model, config))
	{
		vehiclescript = config.script;
		DispatchKeyValue(vehicle, "VehicleScript", config.script);
	}
	
	if (GetConfigByModelAndVehicleScript(model, vehiclescript, config))
	{
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
	}
}

public void SDKHookCB_PropVehicleDriveable_SpawnPost(int vehicle)
{
	// m_pServerVehicle is initialized in Spawn so we hook it in SpawnPost
	DHookVehicle(GetServerVehicle(vehicle));
	
	VehicleConfig config;
	if (GetConfigByVehicleEnt(vehicle, config))
	{
		SetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit", config.lock_speed);

		SpawnDamageDealerForVehicle(vehicle, config);

		int pusher = CreateEntityByName("point_push");
		if (pusher != -1)
		{
			float vehicleOrigin[3];
			GetEntPropVector(vehicle, Prop_Send, "m_vecOrigin", vehicleOrigin);
			AddVectors(vehicleOrigin, {0.0, 0.0, 100.0}, vehicleOrigin);
			DispatchKeyValueVector(pusher, "origin", vehicleOrigin);
			DispatchKeyValueFloat(pusher, "radius", 200.0);
			DispatchKeyValueFloat(pusher, "magnitude", 200.0);
			DispatchKeyValueInt(pusher, "spawnflags", 8);

			if (DispatchSpawn(pusher))
			{
				SDKCall_SetParent(pusher, vehicle, 0);
				AcceptEntityInput(pusher, "Enable");
				Vehicle(vehicle).Pusher = pusher;
			}
			else
			{
				LogError("Pusher %i for vehicle %i spawning failed", pusher, vehicle);
			}
		}
		else
		{
			LogError("Pusher %i for vehicle %i creation failed", pusher, vehicle);
		}

		SpawnExplosiveForVehicle(vehicle);
	}
}

public Action SDKHookCB_DummyDriver_OnTakeDamage(int entity, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{	
	int parent = GetEntPropEnt(entity, Prop_Send, "moveparent");
	
	if (parent != -1)
	{
		if (IsEntityVehicle(parent))
		{
			int driver = GetEntPropEnt(parent, Prop_Send, "m_hPlayer");
			if (driver != -1)
				SDKHooks_TakeDamage(driver, inflictor, attacker, damage * vehicle_passenger_damage_modifier.FloatValue, damagetype, weapon, damageForce, NULL_VECTOR, true);
		}
	}
	
	damage = 0.0;
	
	return Plugin_Changed;
}

public Action SDKHookCB_DummyDriver_SetTransmit(int entity, int client)
{
	char strDriver[2];
	GetEntPropString(entity, Prop_Data, "m_iName", strDriver, sizeof(strDriver));
	int driver = StringToInt(strDriver);

	if (driver != 0 || (driver == 0 && !StrEqual(strDriver, "0")))
	{
		if (driver == client)
			return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void SDKHookCB_VehicleDamageDealer_StartTouchPost(int entity, int other)
{
	if (IsEntityClient(other))
	{
		if ((Player(other).VehicleIsInAsDriver == -1) && (Player(other).VehicleIsInAsShooter == -1))
		{
			int vehicle = GetEntPropEnt(entity, Prop_Send, "moveparent");
			if (vehicle != -1)
			{
				if (IsEntityVehicle(vehicle))
				{	
					float damagePosition[3];
					GetEntPropVector(other, Prop_Send, "m_vecOrigin", damagePosition);

					float vehicleVelocity[3];
					GetEntPropVector(vehicle, Prop_Data, "m_vecSmoothedVelocity", vehicleVelocity);
					float vehicleSpeed = GetVectorLength(vehicleVelocity, false);
					int clientGround = GetEntPropEnt(other, Prop_Send, "m_hGroundEntity");
					if (clientGround != vehicle)
					{
						if (vehicleSpeed >= 200.0)
						{
							int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");

							float damageForce[3];
							damageForce = vehicleVelocity;
							ScaleVector(damageForce, 100.0);
							SDKHooks_TakeDamage(other, vehicle, driver, 150.0, DMG_VEHICLE, -1, damageForce, damagePosition);
						}
					}
				}
			}
		}
	}	
}

public void SDKHookCB_VehicleDamageDealer_TouchPost(int entity, int other)
{
	if (IsEntityClient(other))
	{
		if ((Player(other).VehicleIsInAsDriver == -1) && (Player(other).VehicleIsInAsShooter == -1))
		{
			int clientStuckLast = GetEntProp(other, Prop_Data, "m_StuckLast");

			if (clientStuckLast >= 10)
			{
				int vehicle = GetEntPropEnt(entity, Prop_Send, "moveparent");
				if (vehicle != -1)
				{	
					float vecVehicleExitOrigin[3];
					float vecVehicleExitAngles[3];
					char attachments[][] = {"exit1", "exit2"};
					for (int i = 0; i < sizeof(attachments); i++)
					{
						if (GetEntityAttachment(vehicle, LookupEntityAttachment(vehicle, attachments[i]), vecVehicleExitOrigin, vecVehicleExitAngles))
						{
							float exitPoint[3];
							bool IsExitPointFound = CheckExitPoint(vecVehicleExitOrigin, vecVehicleExitAngles, g_playerMins, g_playerMaxs, exitPoint);
							if (IsExitPointFound)
							{
								exitPoint[2] = exitPoint[2] + 12.0;
								TeleportEntity(other, exitPoint);

								break;
							}
						}
					}
				}
			}
		}
	}
}

//-----------------------------------------------------------------------------
// Event hooks
//-----------------------------------------------------------------------------

public Action EventCallback_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = event.GetInt("userid", -1);

	if (client != -1)
	{
		client = GetClientOfUserId(client);
		
		if (Player(client).VehicleIsInAsShooter > 0)
		{	
			GetShooterOutFromVehicle(client, true);
		}
	}
	else
		LogError("Dead player's user id retrieving failed");
	
	return Plugin_Continue;
}

public Action EventCallback_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = event.GetInt("userid", -1);

	if (client != -1)
	{
		int clientTeam = event.GetInt("team", -1);
		client = GetClientOfUserId(client);
		Player(client).Team = clientTeam;
	}
	
	return Plugin_Continue;
}
//-----------------------------------------------------------------------------
// Menus
//-----------------------------------------------------------------------------

void DisplayMainVehicleMenu(int client)
{
	Menu menu = new Menu(MenuHandler_MainVehicleMenu, MenuAction_Select | MenuAction_DisplayItem | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_Main", client, PLUGIN_VERSION, PLUGIN_AUTHOR, PLUGIN_URL);
	
	if (CheckCommandAccess(client, "sm_vehicle_create", ADMFLAG_GENERIC))
		menu.AddItem("vehicle_create", "#Menu_Item_CreateVehicle");
	
	if (CheckCommandAccess(client, "sm_vehicle_placespawner", ADMFLAG_CONFIG))
		menu.AddItem("vehicle_placespawner", "#Menu_Item_PlaceSpawner");

	if (CheckCommandAccess(client, "sm_vehicle_removeaim", ADMFLAG_GENERIC))
		menu.AddItem("vehicle_removeaim", "#Menu_Item_RemoveAimTargetVehicle");
	
	if (CheckCommandAccess(client, "sm_vehicle_remove", ADMFLAG_GENERIC))
		menu.AddItem("vehicle_remove", "#Menu_Item_RemovePlayerVehicles");
	
	if (CheckCommandAccess(client, "sm_vehicle_removeall", ADMFLAG_BAN))
		menu.AddItem("vehicle_removeall", "#Menu_Item_RemoveAllVehicles");
	
	if (CheckCommandAccess(client, "sm_vehicle_reload", ADMFLAG_CONFIG))
		menu.AddItem("vehicle_reload", "#Menu_Item_ReloadVehicleConfig");
	
	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayVehicleCreateMenu(int client)
{
	Menu menu = new Menu(MenuHandler_CreateVehicle, MenuAction_Select | MenuAction_DisplayItem | MenuAction_Cancel | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_CreateVehicle", client);
	menu.ExitBackButton = true;
	
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		VehicleConfig config;
		if (g_AllVehicles.GetArray(i, config, sizeof(config)) > 0)
			menu.AddItem(config.id, config.id);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayPlaceVehicleSpawnerHere(int client)
{
	Menu menu = new Menu(MenuHandler_PlaceVehicleSpawnerHere, MenuAction_Select | MenuAction_DisplayItem | MenuAction_Cancel | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_CreateVehicle", client);
	menu.ExitBackButton = true;
	
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		VehicleConfig config;
		if (g_AllVehicles.GetArray(i, config, sizeof(config)) > 0)
			menu.AddItem(config.id, config.id);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayRemoveVehicleTargetMenu(int client)
{
	Menu menu = new Menu(MenuHandler_RemovePlayerVehicles, MenuAction_Select | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_RemovePlayerVehicles", client);
	menu.ExitBackButton = CheckCommandAccess(client, "sm_vehicle", ADMFLAG_GENERIC);
	
	AddTargetsToMenu2(menu, client, COMMAND_FILTER_CONNECTED);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MainVehicleMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			if (menu.GetItem(param2, info, sizeof(info)))
			{
				if (StrEqual(info, "vehicle_create"))
				{
					DisplayVehicleCreateMenu(param1);
				}
				else if (StrEqual(info, "vehicle_placespawner"))
				{
					DisplayPlaceVehicleSpawnerHere(param1);
				}
				else if (StrEqual(info, "vehicle_removeaim"))
				{
					FakeClientCommand(param1, "sm_vehicle_removeaim");
					DisplayMainVehicleMenu(param1);
				}
				else if (StrEqual(info, "vehicle_remove"))
				{
					DisplayRemoveVehicleTargetMenu(param1);
				}
				else if (StrEqual(info, "vehicle_removeall"))
				{
					FakeClientCommand(param1, "sm_vehicle_removeall");
					DisplayMainVehicleMenu(param1);
				}
				else if (StrEqual(info, "vehicle_reload"))
				{
					FakeClientCommand(param1, "sm_vehicle_reload");
					DisplayMainVehicleMenu(param1);
				}
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)))
			{
				Format(display, sizeof(display), "%T", display, param1);
				return RedrawMenuItem(display);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

public int MenuHandler_CreateVehicle(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			if (menu.GetItem(param2, info, sizeof(info)))
			{
				FakeClientCommand(param1, "sm_vehicle_create %s", info);
				DisplayVehicleCreateMenu(param1);
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			VehicleConfig config;
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)) && GetConfigById(info, config) && TranslationPhraseExists(config.name))
			{
				Format(display, sizeof(display), "%T", config.name, param1);
				return RedrawMenuItem(display);
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				DisplayMainVehicleMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

public int MenuHandler_PlaceVehicleSpawnerHere(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			if (menu.GetItem(param2, info, sizeof(info)))
			{
				FakeClientCommand(param1, "sm_vehicle_placespawner %s", info);
				DisplayPlaceVehicleSpawnerHere(param1);
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			VehicleConfig config;
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)) && GetConfigById(info, config) && TranslationPhraseExists(config.name))
			{
				Format(display, sizeof(display), "%T", config.name, param1);
				return RedrawMenuItem(display);
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				DisplayMainVehicleMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

public int MenuHandler_RemovePlayerVehicles(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				DisplayMainVehicleMenu(param1);
			}
		}
		case MenuAction_Select:
		{
			char info[32];
			int userid, target;
			
			menu.GetItem(param2, info, sizeof(info));
			userid = StringToInt(info);
			
			if ((target = GetClientOfUserId(userid)) == 0)
			{
				PrintToChat(param1, "[SM] %t", "Player no longer available");
			}
			else if (!CanUserTarget(param1, target))
			{
				PrintToChat(param1, "[SM] %t", "Unable to target");
			}
			else
			{
				FakeClientCommand(param1, "sm_vehicle_remove #%d", userid);
			}
			
			DisplayRemoveVehicleTargetMenu(param1);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

//-----------------------------------------------------------------------------
// DHooks
//-----------------------------------------------------------------------------

void CreateDynamicDetour(GameData gamedata, const char[] name, DHookCallback callbackPre = INVALID_FUNCTION, DHookCallback callbackPost = INVALID_FUNCTION)
{
	DynamicDetour detour = DynamicDetour.FromConf(gamedata, name);
	if (detour)
	{
		if (callbackPre != INVALID_FUNCTION)
			if (!detour.Enable(Hook_Pre, callbackPre))
				LogError("Failed to enable detour setup hundle: %s", name);
		
		if (callbackPost != INVALID_FUNCTION)
			detour.Enable(Hook_Post, callbackPost);
	}
	else
	{
		LogError("Failed to create detour setup handle: %s", name);
	}
}

DynamicHook CreateDynamicHook(GameData gamedata, const char[] name)
{
	DynamicHook hook = DynamicHook.FromConf(gamedata, name);
	if (!hook)
		LogError("Failed to create hook setup handle: %s", name);
	
	return hook;
}

void DHookGamerulesObject()
{
	if (GetEngineVersion() == Engine_TF2)
		if (g_DHookShouldCollide)
			g_DHookShouldCollide.HookGamerules(Hook_Post, DHookCallback_ShouldCollide);
}

void DHookClient(int client)
{
	if (g_DHookGetInVehicle)
		g_DHookGetInVehicle.HookEntity(Hook_Post, client, DHookCallback_GetInVehicle);
	
	if (g_DHookLeaveVehicle)
		g_DHookLeaveVehicle.HookEntity(Hook_Post, client, DHookCallback_LeaveVehicle);

	SDKHook(client, SDKHook_OnTakeDamage, SDKHookCB_Client_OnTakeDamage);
}

void DHookVehicle(Address serverVehicle)
{
	if (g_DHookSetPassenger)
		g_DHookSetPassenger.HookRaw(Hook_Pre, serverVehicle, DHookCallback_SetPassengerPre);

	if (g_DHookIsPassengerVisible)
		g_DHookIsPassengerVisible.HookRaw(Hook_Post, serverVehicle, DHookCallback_IsPassengerVisiblePost);
	
	if (g_DHookHandlePassengerEntry)
		g_DHookHandlePassengerEntry.HookRaw(Hook_Pre, serverVehicle, DHookCallback_HandlePassengerEntryPre);
	
	if (g_DHookGetExitAnimToUse)
		g_DHookGetExitAnimToUse.HookRaw(Hook_Post, serverVehicle, DHookCallback_GetExitAnimToUsePost);
	
	if (g_DHookCheckExitPoint)
		g_DHookCheckExitPoint.HookRaw(Hook_Pre, serverVehicle, DHookCallback_CheckExitPointPre);
}

public MRESReturn DHookCallback_SetupMovePre(DHookParam params)
{
	int client = params.Get(1);
	
	int vehicle = GetEntPropEnt(client, Prop_Send, "m_hVehicle");
	if (vehicle != -1)
	{
		Address ucmd = params.Get(2);
		Address helper = params.Get(3);
		Address move = params.Get(4);
		
		SDKCall_VehicleSetupMove(GetServerVehicle(vehicle), client, ucmd, helper, move);			
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_ShouldCollide(DHookReturn ret, DHookParam params)
{
	int collisionGroup0 = params.Get(1);
	int collisionGroup1 = params.Get(2);
	
	if (collisionGroup0 > collisionGroup1)
	{
		// Swap so that lowest is always first
		V_swap(collisionGroup0, collisionGroup1);
	}
	
	// Prevent vehicles from entering respawn rooms
	if (collisionGroup1 == TFCOLLISION_GROUP_RESPAWNROOMS)
	{
		ret.Value = ret.Value || (collisionGroup0 == COLLISION_GROUP_VEHICLE);
		return MRES_Supercede;
	}
	
	return MRES_Ignored;

}

public MRESReturn DHookCallback_SetPassengerPre(Address serverVehicle, DHookParam params)
{
	int vehicle = SDKCall_GetVehicleEnt(serverVehicle);

	if (!params.IsNull(2))
	{
		SetEntProp(params.Get(2), Prop_Send, "m_bDrawViewmodel", false);
	}
	else
	{
		// Stop any horn sounds when the player leaves the vehicle
		VehicleConfig config;
		if (GetConfigByVehicleEnt(vehicle, config) && config.horn_sound[0] != EOS)
		{
			EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT, SND_STOP | SND_STOPLOOPING);
		}

		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != -1)
		{
			if (IsValidEdict(client)) // Needed to avoid an error message in the server log if a player is in the vehicle during server's shutdown
			{
				Player(client).IsUsingHorn = false;
				SetEntProp(client, Prop_Send, "m_bDrawViewmodel", true);
			}
		}
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_IsPassengerVisiblePost(Address serverVehicle, DHookReturn ret)
{
	VehicleConfig config;
	if (GetConfigByVehicleEnt(SDKCall_GetVehicleEnt(serverVehicle), config))
	{
		ret.Value = config.is_passenger_visible;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_HandlePassengerEntryPre(Address serverVehicle, DHookParam params)
{
	if (!vehicle_enable_entry_exit_anims.BoolValue)
	{
		int client = params.Get(1);
		int vehicle = SDKCall_GetVehicleEnt(serverVehicle);
		
		if (CanEnterVehicle(client, vehicle))	// CPropVehicleDriveable::CanEnterVehicle
		{
			if (SDKCall_CanEnterVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER))	//CBasePlayer::CanEnterVehicle
			{
				Player(client).VehicleIsInAsDriver = vehicle;
				SDKCall_GetInVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER);
				
				float origin[3];
				float angles[3];

				if (GetEngineVersion() != Engine_DODS)
				{
					if (SDKCall_GetAttachmentLocal(vehicle, LookupEntityAttachment(vehicle, "vehicle_driver_eyes"), origin, angles))
						TeleportEntity(client, .angles = angles); // Snap the driver's view where the vehicle is facing
				}		
				else
				{
					if (SDKCall_GetAttachmentLocal(vehicle, LookupEntityAttachment(vehicle, "vehicle_driver_feet"), origin, angles))
					{
						/*
						float vecLeftDirection[3];
						GetAngleVectors(angles, NULL_VECTOR, vecLeftDirection, NULL_VECTOR);
						NegateVector(vecLeftDirection);
						ScaleVector(vecLeftDirection, 5.0);
						AddVectors(origin, vecLeftDirection, origin);
						*/
						TeleportEntity(client, origin, angles); // Snap the driver's view where the vehicle is facing, and snap the driver's position to the driving seat so that the shooter passenger doesn't collide with him causing the vehicle to accelerate

					}
				}
				
				CreateTimer(1.5, Timer_PrintVehicleKeyHint, EntIndexToEntRef(vehicle));
			}
		}
		
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetExitAnimToUsePost(Address serverVehicle, DHookReturn ret)
{
	if (!vehicle_enable_entry_exit_anims.BoolValue)
	{
		ret.Value = ACTIVITY_NOT_AVAILABLE;
		return MRES_Override;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetInVehicle(int client)
{
	int vehicle = Player(client).VehicleIsInAsDriver;
	VehicleConfig vehicleConfig;
	GetConfigByVehicleEnt(vehicle, vehicleConfig);

	if (vehicleConfig.is_passenger_visible)
	{
		SetEntityMoveType(client, MOVETYPE_WALK); // Internal game code changes the MoveType of the player once he is driver. Here it is restored to WALK to get the driver receives reflected damage from his dummy model.

		if (Vehicle(vehicle).DummyDriver == -1)
		{
			SpawnDummyDriverForVehicle(vehicle, client);
		}
		
		if (Vehicle(vehicle).DummyDriver != -1)
		{
			SetEntityRenderMode(client, RENDER_NONE);
			DispatchKeyValueInt(client, "solid", 0);
			SetEntityModelForVehicle(Vehicle(vehicle).DummyDriver, client, "driver", vehicleConfig);
		}
	}
	
	if (!IsFakeClient(client))
		SendConVarValue(client, FindConVar("sv_client_predict"), "0");
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_LeaveVehicle(int client)
{
	RequestFrame(RequestFrameCallback_LeaveVehicle, client);
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_CheckExitPointPre(Address serverVehicle, DHookReturn ret, DHookParam params)
{	
	// Avoid the game's CheckExitPoint function being called so that the custom one can be used.
	ret.Value = false;
	return MRES_Supercede;
}

public MRESReturn DHookCallback_PushEntity(int pusher, DHookParam params)
{	
	MRESReturn returnValue = MRES_Ignored;

	int client = params.Get(1);
	if (IsEntityClient(client))
	{
		int vehicle = GetEntPropEnt(pusher, Prop_Send, "moveparent");
		if (IsEntityVehicle(vehicle))
		{
			float origin[3];
			float mins[3];
			float maxs[3];

			GetEntPropVector(vehicle, Prop_Send, "m_vecOrigin", origin);
			GetEntPropVector(vehicle, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(vehicle, Prop_Send, "m_vecMaxs", maxs);
			ScaleVector(mins, 1.5);
			ScaleVector(maxs, 1.5);

			Handle trace;
			trace = TR_ClipRayHullToEntityEx(origin, origin, mins, maxs, MASK_SOLID, client);
			if (TR_DidHit(trace))
			{
				float vehicleVelocity[3];
				float vehicleSpeed;
				GetEntPropVector(vehicle, Prop_Data, "m_vecSmoothedVelocity", vehicleVelocity);
				vehicleSpeed = GetVectorLength(vehicleVelocity);
				int clientGround = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");

				if (vehicleSpeed <= 1.0 || clientGround == -1)
				{
					returnValue = MRES_Supercede; // Skip push because vehicle doesn't move enough or the player is jumping/falling.
				}
			}
			else
			{
				returnValue = MRES_Supercede; // Skip push because you are outside the range.
			}

			CloseHandle(trace);
		}		
	}

	return returnValue;
}

//-----------------------------------------------------------------------------
// SDK Calls
//-----------------------------------------------------------------------------

Handle PrepSDKCall_VehicleSetupMove(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::SetupMove");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::SetupMove");
	
	return call;
}

Handle PrepSDKCall_CanEnterVehicle(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBasePlayer::CanEnterVehicle");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBasePlayer::CanEnterVehicle");
	
	return call;
}

Handle PrepSDKCall_GetAttachmentLocal(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBaseAnimating::GetAttachmentLocal");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseAnimating::GetAttachmentLocal");
	
	return call;
}

Handle PrepSDKCall_GetVehicleEnt(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::GetVehicleEnt");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::GetVehicleEnt");
	
	return call;
}

Handle PrepSDKCall_HandlePassengerEntry(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandlePassengerEntry");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandlePassengerEntry");
	
	return call;
}

Handle PrepSDKCall_HandlePassengerExit(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandlePassengerExit");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandlePassengerExit");
	
	return call;
}

Handle PrepSDKCall_HandleEntryExitFinish(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandleEntryExitFinish");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandleEntryExitFinish");
	
	return call;
}

Handle PrepSDKCall_StudioFrameAdvance(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseAnimating::StudioFrameAdvance");
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogError("Failed to create SDK call: CBaseAnimating::StudioFrameAdvance");
	
	return call;
}

Handle PrepSDKCall_GetInVehicle(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBasePlayer::GetInVehicle");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogError("Failed to create SDK call: CBasePlayer::GetInVehicle");
	
	return call;
}

Handle PrepSDKCall_SetParent(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseEntity::SetParent");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogError("Failed to create SDK call: CBaseEntity::SetParent");
	
	return call;
}

Handle PrepSDKCall_SnapEyeAngles(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBasePlayer::SnapEyeAngles");
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_Pointer);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogError("Failed to create SDK call: CBasePlayer::SnapEyeAngles");
	
	return call;
}

void SDKCall_VehicleSetupMove(Address serverVehicle, int client, Address ucmd, Address helper, Address move)
{
	if (g_SDKCallVehicleSetupMove)
		SDKCall(g_SDKCallVehicleSetupMove, serverVehicle, client, ucmd, helper, move);
}

bool SDKCall_CanEnterVehicle(int client, Address serverVehicle, PassengerRole role)
{
	if (g_SDKCallCanEnterVehicle)
		return SDKCall(g_SDKCallCanEnterVehicle, client, serverVehicle, role);
	
	return false;
}

bool SDKCall_GetAttachmentLocal(int entity, int attachment, float origin[3], float angles[3])
{
	if (g_SDKCallGetAttachmentLocal)
		return SDKCall(g_SDKCallGetAttachmentLocal, entity, attachment, origin, angles);
	
	return false;
}

int SDKCall_GetVehicleEnt(Address serverVehicle)
{
	if (g_SDKCallGetVehicleEnt)
		return SDKCall(g_SDKCallGetVehicleEnt, serverVehicle);
	
	return -1;
}

void SDKCall_HandlePassengerEntry(Address serverVehicle, int passenger, bool allowEntryOutsideZone)
{
	if (g_SDKCallHandlePassengerEntry)
		SDKCall(g_SDKCallHandlePassengerEntry, serverVehicle, passenger, allowEntryOutsideZone);
}

bool SDKCall_HandlePassengerExit(Address serverVehicle, int passenger)
{
	if (g_SDKCallHandlePassengerExit)
		return SDKCall(g_SDKCallHandlePassengerExit, serverVehicle, passenger);
	
	return false;
}

void SDKCall_HandleEntryExitFinish(Address serverVehicle, bool exitAnimOn, bool resetAnim)
{
	if (g_SDKCallHandleEntryExitFinish)
		SDKCall(g_SDKCallHandleEntryExitFinish, serverVehicle, exitAnimOn, resetAnim);
}

void SDKCall_StudioFrameAdvance(int entity)
{
	if (g_SDKCallStudioFrameAdvance)
		SDKCall(g_SDKCallStudioFrameAdvance, entity);
}

bool SDKCall_GetInVehicle(int client, Address serverVehicle, PassengerRole role)
{
	if (g_SDKCallGetInVehicle)
		return SDKCall(g_SDKCallGetInVehicle, client, serverVehicle, role);
	
	return false;
}

void SDKCall_SetParent(int entity, int parent, int attachment)
{
	if (g_SDKCallSetParent)
		SDKCall(g_SDKCallSetParent, entity, parent, attachment);
}

void SDKCall_SnapEyeAngles(int player, float angles[3])
{
	if (g_SDKCallSnapEyeAngles)
		SDKCall(g_SDKCallSnapEyeAngles, player, angles);
}