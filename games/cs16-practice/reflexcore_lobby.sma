#include <amxmodx>
#include <cstrike>
#include <fun>
#include <hamsandwich>
#include "reflexcore_lobby_actor.inc"

new g_ammo[33];
new Float:g_lastChange;
public plugin_init()
{
    register_plugin("ReflexCore Local Lobby", "1.0", "ReflexCore");
    register_clcmd("rc_lobby", "show_lobby");
    register_clcmd("rc_lobby_clear", "clear_bots");
    register_clcmd("rc_lobby_ct", "add_ct");
    register_clcmd("rc_lobby_fly", "toggle_fly");
    register_clcmd("rc_lobby_restart", "restart_round");
    register_clcmd("rc_lobby_cheats","allow_cheats");
    register_clcmd("rc_lobby_ammo", "toggle_ammo");
    register_clcmd("rc_lobby_balance", "no_balance");
    register_clcmd("rc_lobby_limits", "no_limits");
    register_clcmd("rc_lobby_long", "long_round");
    register_cvar("rc_lobby_probe_client","0");
    register_srvcmd("rc_lobby_probe","probe_lobby");
    set_task(0.1,"lobby_tick",0,"",0,"b");
    RegisterHam(Ham_Spawn,"player","lobby_spawn",1);
    register_logevent("lobby_round_end",2,"1=Round_End");
    register_event("TeamInfo","team_changed","a");
    register_event("CurWeapon", "supply_ammo", "be", "1=1");
}

bool:lobby_is_local()
{
    if (!is_dedicated_server() || !get_cvar_num("sv_lan"))
        return false;
    new bindip[32];
    get_cvar_string("ip", bindip, charsmax(bindip));
    return equal(bindip, "127.0.0.1");
}

bool:local_player(id)
{
    if (id < 1 || id > get_maxplayers() || !is_user_connected(id) || is_user_bot(id) || !lobby_is_local())
        return false;
    new ip[32];
    get_user_ip(id, ip, charsmax(ip), 1);
    return equal(ip, "127.0.0.1");
}

public show_lobby(id)
{
    if (!local_player(id)) return PLUGIN_HANDLED;
    new menu = menu_create("ReflexCore | Local team play", "choose");
    menu_additem(menu, "Play with ReflexCore on my team");
    menu_additem(menu, "Play against ReflexCore on the other team");
    menu_additem(menu, "Add one CT bot");
    menu_additem(menu, "Remove all bots");
    menu_additem(menu, "Restart round");
    menu_display(id, menu);
    return PLUGIN_HANDLED;
}

public choose(id, menu, item)
{
    menu_destroy(menu);
    if (item == MENU_EXIT || !local_player(id)) return PLUGIN_HANDLED;
    if (item == 2) return add_ct(id);
    if (item == 3) return clear_bots(id);
    if (item == 4) return restart_round(id);
    new CsTeams:team = cs_get_user_team(id);
    if (team != CS_TEAM_T && team != CS_TEAM_CT) {
        client_print(id, print_chat, "[ReflexCore] Join T or CT first.");
        return PLUGIN_HANDLED;
    }
    if (get_gametime() < g_lastChange + 2.0) return PLUGIN_HANDLED;
    g_lastChange = get_gametime();
    new ally = _:team, enemy = 3 - ally;
    server_cmd("yb kickall instant");
    server_exec();
    new side=item==0 ? ally : enemy;
    if(owned_reflex()){
        g_leader_userid=get_user_userid(id);
        if(_:cs_get_user_team(g_reflex)!=side){
            cs_set_user_team(g_reflex,CsTeams:side);
            ExecuteHamB(Ham_CS_RoundRespawn,g_reflex);
        }
    }else if (!join_reflex(side, get_user_userid(id))) {
        client_print(id, print_chat, "[ReflexCore] Could not join the selected team.");
        return PLUGIN_HANDLED;
    }
    if(owned_reflex() && _:cs_get_user_team(g_reflex)==side) server_print("Lobby menu verified Reflex side %d",side);
    if (item == 0) server_cmd("yb add 2 0 %d 1 Lab-Opponent", enemy);
    return PLUGIN_HANDLED;
}

public clear_bots(id) { if (local_player(id)) { remove_reflex(); server_cmd("yb kickall instant"); } return PLUGIN_HANDLED; }
public add_ct(id) { if (local_player(id)) server_cmd("yb add_ct"); return PLUGIN_HANDLED; }
public restart_round(id) { if (local_player(id)) server_cmd("sv_restart 1"); return PLUGIN_HANDLED; }
public no_balance(id) { if (local_player(id)) set_cvar_num("mp_autoteambalance", 0); return PLUGIN_HANDLED; }
public no_limits(id) { if (local_player(id)) set_cvar_num("mp_limitteams", 0); return PLUGIN_HANDLED; }
public allow_cheats(id) { if(local_player(id)) set_cvar_num("sv_cheats",1); return PLUGIN_HANDLED; }
public long_round(id) { if (local_player(id)) set_cvar_float("mp_roundtime", 9.0); return PLUGIN_HANDLED; }
public toggle_fly(id) { if (local_player(id) && is_user_alive(id)) set_user_noclip(id, !get_user_noclip(id)); return PLUGIN_HANDLED; }
public toggle_ammo(id) {
    if (local_player(id)) {
        g_ammo[id] = !g_ammo[id];
        client_print(id, print_chat, "[ReflexCore] Reserve refill: %s", g_ammo[id] ? "on" : "off");
        supply_ammo(id);
    }
    return PLUGIN_HANDLED;
}
public client_putinserver(id) {
    g_ammo[id] = 0;
    if(local_player(id)) {
        server_print("Lobby local human connected");
        new address[32];
        get_user_ip(id,address,charsmax(address),0);
        if(get_cvar_num("rc_lobby_probe_client") && equal(address,"127.0.0.1:27165")){
            new data[1]; data[0]=get_user_userid(id);
            set_task(1.5,"probe_team",10000+id,data,1);
        }
    }
}
public team_changed(){
    new id=read_data(1);
    if(!local_player(id) || owned_reflex()) return;
    new team[16];
    read_data(2,team,charsmax(team));
    if(!equal(team,"CT") && !equal(team,"TERRORIST")) return;
    new data[1]; data[0]=get_user_userid(id);
    if(!task_exists(9000+id)) set_task(0.5,"add_teammate",9000+id,data,1);
}
public add_teammate(data[], task){
    new id=task-9000;
    if(!local_player(id) || get_user_userid(id)!=data[0] || owned_reflex()) return;
    new CsTeams:team=cs_get_user_team(id);
    if(team!=CS_TEAM_CT && team!=CS_TEAM_T) return;
    if(join_reflex(_:team,data[0])) server_cmd("yb add 2 0 %d 1 Lab-Opponent",3-_:team);
}
public supply_ammo(id) {
    if (!g_ammo[id] || !local_player(id) || !is_user_alive(id)) return;
    new w = get_user_weapon(id);
    if (w > 0 && w < 31 && !((1<<w) & ((1<<CSW_KNIFE)|(1<<CSW_C4)|(1<<CSW_HEGRENADE)|(1<<CSW_FLASHBANG)|(1<<CSW_SMOKEGRENADE))))
        cs_set_user_bpammo(id, w, 90);
}

public probe_lobby() {
    if (!lobby_is_local()) return PLUGIN_HANDLED;
    if (!owned_reflex()) join_reflex(1, 0);
    server_cmd("yb add 2 0 2 1 Probe-CT");
    return PLUGIN_HANDLED;
}

public lobby_spawn(id) {
    if(id != g_reflex) return;
    g_check_at=0.0;
    g_next_cell=g_cell_count=g_cell_transitions=g_visible_samples=g_clip_decrements=0;
}
public lobby_round_end(){
    if(owned_reflex()) server_print("Lobby life: patrol_cells_entered=%d visible_enemy_ticks=%d attack_clip_decrements=%d",g_cell_transitions,g_visible_samples,g_clip_decrements);
}

public probe_team(data[],task){
    new id=task-10000;
    if(!local_player(id) || get_user_userid(id)!=data[0]) return;
    engclient_cmd(id,"jointeam","2"); engclient_cmd(id,"joinclass","1");
    set_task(13.0,"probe_menu",11000+id,data,1);
}

public probe_menu(data[],task){
    new id=task-11000;
    if(!local_player(id) || get_user_userid(id)!=data[0]) return;
    amxclient_cmd(id,"rc_lobby");
    new old, menu, page;
    player_menu_info(id,old,menu,page);
    if(menu<0) return;
    server_print("Lobby H command opened the team menu");
    // Exercise the real menu callback for item 2 on the tagged probe client.
    choose(id, menu, 1);
}
