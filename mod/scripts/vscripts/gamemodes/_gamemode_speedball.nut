untyped
global function GamemodeSpeedball_Init

struct {
	entity flagBase
	entity flag
	entity flagCarrier
    array<Point> gulagSpawns
	array<entity> gulagPlayers
	array<entity> gulagWaitPlayers
	array<entity> gulaggers
} file

const WEAPONS = [
	"mp_weapon_sniper",
	"mp_weapon_shotgun",
	"mp_weapon_shotgun_pistol",
	"mp_weapon_defender",
	"mp_weapon_autopistol",
	"mp_weapon_wingman"
]

void function GamemodeSpeedball_Init()
{
	PrecacheModel( CTF_FLAG_MODEL )
	PrecacheModel( CTF_FLAG_BASE_MODEL )

	// gamemode settings
	SetRoundBased( true )
	SetRespawnsEnabled( false )
	SetShouldUseRoundWinningKillReplay( true )
	Riff_ForceTitanAvailability( eTitanAvailability.Never )
	Riff_ForceSetEliminationMode( eEliminationMode.Pilots )
	ScoreEvent_SetupEarnMeterValuesForMixedModes()
	InitPoints()
	
	AddSpawnCallbackEditorClass( "script_ref", "info_speedball_flag", CreateFlag )
	
	AddCallback_GameStateEnter( eGameState.Prematch, CreateFlagIfNoFlagSpawnpoint )
	AddCallback_GameStateEnter( eGameState.Playing, ResetFlag )
	AddCallback_OnTouchHealthKit( "item_flag", OnFlagCollected )
	AddCallback_OnPlayerKilled( OnPlayerKilled )
	AddCallback_OnClientDisconnected( GulagOnPlayerDisconnect )
	SetTimeoutWinnerDecisionFunc( TimeoutCheckFlagHolder )
	AddCallback_OnRoundEndCleanup ( ResetFlag )

	ClassicMP_SetCustomIntro( ClassicMP_DefaultNoIntro_Setup, ClassicMP_DefaultNoIntro_GetLength() )
	ClassicMP_ForceDisableEpilogue( true )
}

void function CreateFlag( entity flagSpawn )
{ 
	entity flagBase = CreatePropDynamic( CTF_FLAG_BASE_MODEL, flagSpawn.GetOrigin(), flagSpawn.GetAngles() )
	
	entity flag = CreateEntity( "item_flag" )
	flag.SetValueForModelKey( CTF_FLAG_MODEL )
	flag.MarkAsNonMovingAttachment()
	DispatchSpawn( flag )
	flag.SetModel( CTF_FLAG_MODEL )
	flag.SetOrigin( flagBase.GetOrigin() + < 0, 0, flagBase.GetBoundingMaxs().z + 1 > )
	flag.SetVelocity( < 0, 0, 1 > )
	
	file.flag = flag
	file.flagBase = flagBase
}	

bool function OnFlagCollected( entity player, entity flag )
{
	if ( !IsAlive( player ) || flag.GetParent() != null || player.IsTitan() || player.IsPhaseShifted() ) 
		return false
		
	GiveFlag( player )
	return false // so flag ent doesn't despawn
}

void function OnPlayerKilled( entity victim, entity attacker, var damageInfo )
{
	if ( file.flagCarrier == victim )
		DropFlag()
		
	if ( victim.IsPlayer() && GetGameState() == eGameState.Playing )
		if ( GetPlayerArrayOfTeam_Alive( victim.GetTeam() ).len() == 1 )
			foreach ( entity player in GetPlayerArray() )
				Remote_CallFunction_NonReplay( player, "ServerCallback_SPEEDBALL_LastPlayer", player.GetTeam() != victim.GetTeam() )
    
    GulagOnPlayerKilled(victim, attacker, damageInfo)
}

void function GiveFlag( entity player )
{
	file.flag.SetParent( player, "FLAG" )
	file.flagCarrier = player
	SetGlobalNetEnt( "flagCarrier", player )
	thread DropFlagIfPhased( player )
	
	EmitSoundOnEntityOnlyToPlayer( player, player, "UI_CTF_1P_GrabFlag" )
	foreach ( entity otherPlayer in GetPlayerArray() )
	{
		MessageToPlayer( otherPlayer, eEventNotifications.SPEEDBALL_FlagPickedUp, player )
		
		if ( otherPlayer.GetTeam() == player.GetTeam() )
			EmitSoundOnEntityToTeamExceptPlayer( file.flag, "UI_CTF_3P_TeamGrabFlag", player.GetTeam(), player )
	}
}

void function DropFlagIfPhased( entity player )
{
	player.EndSignal( "StartPhaseShift" )
	player.EndSignal( "OnDestroy" )
	
	OnThreadEnd( function() : ( player ) 
	{
		if ( file.flag.GetParent() == player )
			DropFlag()
	})
	
	while( file.flag.GetParent() == player )
		WaitFrame()
}

void function DropFlag()
{
	file.flag.ClearParent()
	file.flag.SetAngles( < 0, 0, 0 > )
	SetGlobalNetEnt( "flagCarrier", file.flag )
	
	if ( IsValid( file.flagCarrier ) )
		EmitSoundOnEntityOnlyToPlayer( file.flagCarrier, file.flagCarrier, "UI_CTF_1P_FlagDrop" )
	
	foreach ( entity player in GetPlayerArray() )
		MessageToPlayer( player, eEventNotifications.SPEEDBALL_FlagDropped, file.flagCarrier )
	
	file.flagCarrier = null
}

void function CreateFlagIfNoFlagSpawnpoint()
{
	if ( IsValid( file.flag ) )
		return
	
	foreach ( entity hardpoint in GetEntArrayByClass_Expensive( "info_hardpoint" ) )
	{
		if ( hardpoint.kv.hardpointGroup == "B" )
		{
			CreateFlag( hardpoint )
			return
		}
	}
}

void function ResetFlag()
{
	file.flag.ClearParent()
	file.flag.SetAngles( < 0, 0, 0 > )
	file.flag.SetVelocity( < 0, 0, 1 > ) // hack: for some reason flag won't have gravity if i don't do this
	file.flag.SetOrigin( file.flagBase.GetOrigin() + < 0, 0, file.flagBase.GetBoundingMaxs().z * 2 > )
	file.flagCarrier = null
	SetGlobalNetEnt( "flagCarrier", file.flag )
    ResetRound()
}

int function TimeoutCheckFlagHolder()
{
	if ( file.flagCarrier == null )
		return TEAM_UNASSIGNED
		
	return file.flagCarrier.GetTeam()
}

void function GulagOnPlayerKilled( entity victim, entity attacker, var damageInfo )
{
	if ( IsInGulag( victim ) ) {
		// death.
		if (IsValid( attacker ) ) {
			WinGulag( attacker )
		}

		return
	}

	// Is gulag waiting for players
	if (GetOtherTeamArr( file.gulagWaitPlayers, victim ).len() == 0) {
		if ( HasGullagedBefore( victim ) ) return

		file.gulagWaitPlayers.append( victim )

		SendMessage( victim, "Please wait until someone dies to enter gulag")
		printl("Hasnt gullaged before, first player added to list")
		return
	}

	// sent to gulag L
	if ( IsGulagFree() ) {
		printl("Nobody is in gulag")
		int otherIndex = FindNextValid( GetOtherTeamArr( file.gulagWaitPlayers, victim ) )

		if (otherIndex == -1) {
			printl("Other quit, delete him and wait again")
			if ( HasGullagedBefore( victim ) ) return
			file.gulagWaitPlayers.append( victim )
			SendMessage( victim, "Please wait until someone dies to enter gulag")
			return
		}

		entity other = file.gulagWaitPlayers[otherIndex]

		if ( IsAlive( other ) ) {
			printl("other respawned, via fastball respawn, bye")
			file.gulagWaitPlayers.remove( otherIndex )
			SendMessage( other, "")
			return
		}

		printl("actually start gulag,")
		file.gulagWaitPlayers.remove( otherIndex )
		thread StartGulagSequence(victim, other)
	} else {
		if ( HasGullagedBefore( victim ) ) return
		printl("gulag is not free.. wait")
		file.gulagWaitPlayers.append( victim )
		SendMessage( victim, "Please wait until there's a free spot in gulag")
	}
}

void function StartGulagSequence( entity victim, entity other ) {
	file.gulagPlayers.append(victim)
	file.gulagPlayers.append(other)

	printl("Started Gulag")

	SendMessage(victim, "")
	SendMessage(other, "")

	wait 0.1

	victim.SetOrigin( file.gulagSpawns[0].origin )
	victim.SetAngles( file.gulagSpawns[0].angles )
	other.SetOrigin( file.gulagSpawns[1].origin )
	other.SetAngles( file.gulagSpawns[1].angles )
	
	if (!IsAlive(victim)) victim.RespawnPlayer( null )
	if (!IsAlive(other))  other.RespawnPlayer( null )

	TakeAllWeapons(victim)
	TakeAllWeapons(other)

	victim.FreezeControlsOnServer()
	other.FreezeControlsOnServer()

	for (int i = 3; i > 0; i--) {
		SendHudMessage( victim, "Starting in: " + i, -1, 0.2, 255, 0, 0, 0, 0, 1, 0 )
		SendHudMessage( other, "Starting in: " + i, -1, 0.2, 255, 0, 0, 0, 0, 1, 0 )
		wait 1
	}

	if ( !IsValid( victim ) ) {
		if ( !IsValid( other ) ) {
			file.gulagPlayers.clear()
			return
		}

		WinGulag( other )
		other.UnfreezeControlsOnServer()
		return
	}

	if ( !IsValid(other) ) {
		WinGulag( victim )
		victim.UnfreezeControlsOnServer()
		return
	}

	other.UnfreezeControlsOnServer()
	victim.UnfreezeControlsOnServer()

	// Start
	GiveRandomWeapon(victim, other)
}

void function SendMessage(entity player, string x) {
	SendHudMessage( player, x, -1, 0.2, 255, 255, 255, 0, 0, 10000, 0 )
}

void function GiveRandomWeapon(entity player, entity other) {
	string rand = WEAPONS.getrandom()

	player.GiveWeapon(rand)
	other.GiveWeapon(rand)
}

void function WinGulag( entity winner ) {
	GiveLoadoutB( winner )

	// Respawn at a random panel for no spawn camping
	Point imc
	imc.origin = < 679, 4674, 200>
	imc.angles = < 0, -90, 0 >
	Point mil
	mil.origin = < -4, -4350, 144 >
	mil.angles = < 0, 80, 0 >

	if (winner.GetTeam() == TEAM_IMC) {
		winner.SetOrigin(imc.origin)
		winner.SetAngles(imc.angles)
	} else if (winner.GetTeam() == TEAM_MILITIA) {
		winner.SetOrigin(mil.origin)
		winner.SetAngles(mil.angles)
	}

	printl("Gulag winner.")

	if (file.gulagWaitPlayers.len() >= 2) {
		entity p = file.gulagWaitPlayers[0]
		entity p1 = GetOtherTeamArr(file.gulagWaitPlayers, p)[0]

		printl("2 or more players waiting")

		if( IsValid( p ) ) {
			if ( !IsValid( p1 ) ) {
				file.gulagWaitPlayers.remove( file.gulagWaitPlayers.find( p1 ) )
				return
			}

			printl("Started game")
			file.gulagWaitPlayers.remove( 0 )
			file.gulagWaitPlayers.remove( file.gulagWaitPlayers.find( p1 ) )
			thread StartGulagSequence( p, p1 )
		} else {
			file.gulagWaitPlayers.remove( 0 )

			if ( !IsValid( p1 ) ) {
				file.gulagWaitPlayers.remove( file.gulagWaitPlayers.find( p1 ) )
			}
		}
	}
}

bool function ClientCommand_StartGulag(entity player, array<string> args) {
	if (GetPlayerArray().len() != 2) return false

	entity p = GetPlayerArray()[0]
	entity p1 = GetPlayerArray()[1]

	thread StartGulagSequence(p, p1)
	return true
}

void function ResetRound() {
	printl("New round, cleared")
	file.gulagPlayers.clear()
	file.gulagWaitPlayers.clear()
	file.gulaggers.clear()
}

array<entity> function GetOtherTeamArr(array<entity> arr, entity player) {
	array<entity> newArr
	foreach(entity e in arr) {
		if (!IsValid(e)) continue
		if (player.GetTeam() != e.GetTeam()) newArr.append(e)
	}
	return newArr
}

void function InitPoints() {
	Point point1
	Point point2
	point1.origin = <522, -3271.5, 2765.9>
	point1.angles = <0, 90, 0>
	point2.origin = <522, -1910, 2765.9>
	point2.angles = <0, -90, 0> 

	file.gulagSpawns = [point1, point2]
}

int function FindNextValid( array<entity> arr ) {
	for (int i = 0; i < arr.len(); i++) {
		if (IsValid(arr[i])) return i
	}
	
	return -1
}

bool function HasGullagedBefore( entity player ) {
	return Contains(file.gulaggers, player )
}

bool function IsInGulag( entity player ) {
	return Contains( file.gulagPlayers, player )
}

bool function IsGulagFree() {
	return file.gulagPlayers.len() == 0
}

bool function Contains( array<entity> arr, entity player ) {
	return arr.find( player ) != -1
}

void function GiveLoadoutB( entity player ) {
	PilotLoadoutDef loadout

	int loadoutIndex = GetPersistentSpawnLoadoutIndex( player, "pilot" )

	loadout = GetPilotLoadoutFromPersistentData( player, loadoutIndex )

	UpdateDerivedPilotLoadoutData( loadout )

	GivePilotLoadout( player, loadout )
	SetActivePilotLoadout( player )
	SetActivePilotLoadoutIndex( player, loadoutIndex )
}

void function GulagOnPlayerDisconnect( entity player ) {
	if ( IsInGulag( player ) ) {
		int idx = file.gulagPlayers.find( player )
		entity other

		if (idx == 1) {
			other = file.gulagPlayers[0]
		} else {
			other = file.gulagPlayers[1]
		}

		if ( IsValid(other) ) {
			WinGulag( other )
		}
	}
}
