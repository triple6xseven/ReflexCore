#include <amxmodx>
#include <cstrike>
#include <fun>
#include <hamsandwich>
#include "reflexcore_lobby_actor.inc"

new g_ammo[33], g_bhop[33];
new bool:g_watch[33];
new Float:g_lastChange;
public plugin_init()
{
    register_plugin("ReflexCore Local Lobby", "1.0", "ReflexCore");
    register_forward(FM_CmdStart,"pilot_command");
    register_clcmd("rc_pilot","toggle_pilot");
    register_clcmd("rc_lobby", "show_lobby");
    register_clcmd("rc_lobby_bhop", "toggle_bhop");
    register_forward(FM_PlayerPreThink, "held_jump");
    register_clcmd("rc_bot_menu","bot_menu");
    set_task(1.0, "refill_wallets", 0, "", 0, "b");
    register_clcmd("rc_lobby_clear", "clear_bots");
    register_clcmd("rc_lobby_ct", "add_ct");
    register_clcmd("rc_lobby_fly", "toggle_fly");
    register_clcmd("rc_lobby_restart", "restart_round");
    register_clcmd("rc_lobby_cheats","allow_cheats");
    register_clcmd("rc_lobby_ammo", "toggle_ammo");
    register_clcmd("rc_lobby_balance", "no_balance");
    register_clcmd("rc_lobby_limits", "no_limits");
    register_clcmd("rc_lobby_long", "long_round");
    register_cvar("rc_lobby_host","");
    setup_patrol_memory();
    g_site_mode=register_cvar("rc_site_mode","0");
    g_memory_limit=register_cvar("rc_follow_memory","256");
    g_learning=register_cvar("rc_learn_positions","1");
    g_training_position=register_cvar("rc_training_position","0");
    load_defense_memory();
    load_site_route();
    register_logevent("begin_defense",3,"2=Planted_The_Bomb");
    register_event("SendAudio","finish_defense","a","2=%!MRAD_terwin","2=%!MRAD_ctwin");
    set_task(0.3, "update_watchers", 0, "", 0, "b");
    set_task(5.0, "save_patrol_memory", 0, "", 0, "b");
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
    new host[32];
    get_cvar_string("rc_lobby_host", host, charsmax(host));
    return equal(bindip, "127.0.0.1") || (host[0] && equal(bindip, "0.0.0.0"));
}

bool:local_player(id)
{
    if (id < 1 || id > get_maxplayers() || !is_user_connected(id) || is_user_bot(id) || !lobby_is_local())
        return false;
    new ip[32];
    get_user_ip(id, ip, charsmax(ip), 1);
    new host[32];
    get_cvar_string("rc_lobby_host", host, charsmax(host));
    return equal(ip, "127.0.0.1") || (host[0] && equal(ip, host));
}

public show_lobby(id)
{
    if (!local_player(id)) return PLUGIN_HANDLED;
    new menu = menu_create("ReflexCore | Local team play", "choose");
    menu_additem(menu,"Follow me","5");
    menu_additem(menu,"FreeRoam AI","8");
    menu_additem(menu,"Hold position","6");
    menu_additem(menu,"Spectate ReflexCore / stop watching","9");
    menu_additem(menu,"Play on my team","0");
    menu_additem(menu,"Play against me","1");
    menu_additem(menu,"Bot settings (J)","10");
    menu_additem(menu,"Restart round","4");
    menu_display(id, menu);
    return PLUGIN_HANDLED;
}

public choose(id, menu, item)
{
    new info[8], access, callback, name[64];
    if (item >= 0) {
        menu_item_getinfo(menu,item,access,info,charsmax(info),name,charsmax(name),callback);
        item=str_to_num(info);
    }
    menu_destroy(menu);
    if (item == MENU_EXIT || !local_player(id)) return PLUGIN_HANDLED;
    if (item == 10) return bot_menu(id);
    if (item == 2) return add_ct(id);
    if (item == 3) return clear_bots(id);
    if (item == 4) return restart_round(id);
    if (item == 9) {
        if (g_watch[id]) {g_watch[id]=false;return PLUGIN_HANDLED;}
        engclient_cmd(id,"jointeam","6");
        g_watch[id]=cs_get_user_team(id)==CS_TEAM_SPECTATOR;
        if (!g_watch[id]) client_print(id,print_chat,"[ReflexCore] Choose Spectator first, then open H again.");
        return PLUGIN_HANDLED;
    }
    if (item == 8) {
        if (!owned_reflex() || !g_route_count) {client_print(id,print_chat,"[ReflexCore] Waiting for the actor and map route.");return PLUGIN_HANDLED;}
        g_roam=true;
        g_hold=false;
        g_waypoint=-1;
        client_print(id,print_chat,"[ReflexCore] FreeRoam AI enabled.");
        return PLUGIN_HANDLED;
    }
    new CsTeams:team = cs_get_user_team(id);
    if (team != CS_TEAM_T && team != CS_TEAM_CT) {
        client_print(id, print_chat, "[ReflexCore] Join T or CT first.");
        return PLUGIN_HANDLED;
    }
    if (get_gametime() < g_lastChange + 2.0) return PLUGIN_HANDLED;
    if (item == 5 || item == 6) {
        if (!owned_reflex() || cs_get_user_team(g_reflex) != team) {
            client_print(id, print_chat, "[ReflexCore] Put ReflexCore on your team first.");
            return PLUGIN_HANDLED;
        }
        g_leader_userid = get_user_userid(id);
        g_hold = item == 6;
        g_roam = false;
        g_trail_count = 0;
        client_print(id, print_chat, g_hold ? "[ReflexCore] Holding position." : "[ReflexCore] Following you.");
        return PLUGIN_HANDLED;
    }
    g_hold = false;
    g_roam = false;
    g_trail_count = 0;
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
    if (item == 0) server_cmd("yb add %d 0 %d 1 Lab-Opponent", get_cvar_num("yb_difficulty"),enemy);
    return PLUGIN_HANDLED;
}

public clear_bots(id) {
    if (local_player(id)) {
        remove_reflex();
        server_cmd("yb kickall instant");
    }
    return PLUGIN_HANDLED;
}
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
public refill_wallets() {
    if (!lobby_is_local()) return;
    for (new id = 1; id <= get_maxplayers(); id++) {
        if (!local_player(id)) continue;
        new addr[32], host[24], port[8], path[80];
        get_user_ip(id, addr, charsmax(addr));
        strtok(addr, host, charsmax(host), port, charsmax(port), ':');
        formatex(path, charsmax(path), "addons/reflex-lobby/client-%d.live", str_to_num(port));
        new file = fopen(path, "wt");
        if (file) {
            fputs(file, "local-client");
            fclose(file);
        }

    }
    for (new id = 1; id <= get_maxplayers(); id++)
        if (is_user_alive(id) && cs_get_user_money(id) < 16000)
            cs_set_user_money(id, 16000, 0);
}
public toggle_bhop(id) {
    if (local_player(id)) {
        g_bhop[id] = !g_bhop[id];
        client_print(id, print_chat, "[ReflexCore] Hold Space to hop: %s", g_bhop[id] ? "on" : "off");
    }
    return PLUGIN_HANDLED;
}
public held_jump(id) {
    if (g_bhop[id] && is_user_alive(id) && (pev(id, pev_button) & IN_JUMP)
        && (pev(id, pev_flags) & FL_ONGROUND) && pev(id, pev_waterlevel) < 2)
        set_pev(id, pev_oldbuttons, pev(id, pev_oldbuttons) & ~IN_JUMP);
}
public client_putinserver(id) {
    g_watch[id]=false;
    g_bhop[id] = 0;
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
    if(join_reflex(_:team,data[0])) server_cmd("yb add %d 0 %d 1 Lab-Opponent",get_cvar_num("yb_difficulty"),3-_:team);
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
    g_roam=true;
    server_cmd("yb add 2 0 2 1 Probe-CT");
    return PLUGIN_HANDLED;
}

public lobby_spawn(id) {
    if(id != g_reflex) return;
    g_waypoint=-1;
    g_trail_count = g_buy_attempts = 0;
    g_next_buy = 0.0;
    g_check_at=0.0;
    g_next_cell=g_cell_count=g_cell_transitions=g_visible_samples=g_clip_decrements=0;
}
public lobby_round_end(){
    g_planted=false;
    new mode=get_pcvar_num(g_site_mode);
    g_site=mode==0 ? 1-g_site : clamp(mode-1,0,1);
    load_site_route();
    save_patrol_memory();
    g_trail_count = 0;
    if(owned_reflex()) server_print("Lobby life: patrol_cells_entered=%d visible_enemy_ticks=%d attack_clip_decrements=%d",g_cell_transitions,g_visible_samples,g_clip_decrements);
}

public update_watchers() {
    for (new id=1;id<=get_maxplayers();id++) {
        if (!g_watch[id]) continue;
        if (!local_player(id) || cs_get_user_team(id)!=CS_TEAM_SPECTATOR) {g_watch[id]=false;continue;}
        if (!owned_reflex() || !is_user_alive(g_reflex)) continue;
        set_ent_data_entity(id,"CBasePlayer","m_hObserverTarget",g_reflex);
        set_pev(id,pev_iuser1,4);
        set_pev(id,pev_iuser2,g_reflex);
    }
}

public probe_team(data[],task){
    // This probe only acts on the tagged test client.
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
    choose(id, menu, 2);
    if (!g_hold) return;
    show_lobby(id);
    player_menu_info(id,old,menu,page);
    if (menu < 0) return;
    choose(id, menu, 0);
    if (g_hold || g_leader_userid != get_user_userid(id)) return;
    show_lobby(id);
    player_menu_info(id,old,menu,page);
    if (menu < 0) return;
    choose(id, menu, 1);
    if (!g_roam) return;
    server_print("Lobby probe confirmed hold, follow and FreeRoam");
    show_lobby(id);
    player_menu_info(id,old,menu,page);
    if (menu < 0) return;
    // Exercise the real menu callback for item 2 on the tagged probe client.
    choose(id, menu, 5);
}



public bot_menu(id) {
    if (!local_player(id)) return PLUGIN_HANDLED;
    new m=menu_create("Local bot settings","bot_choice");
    menu_additem(m,"Easy opponents");
    menu_additem(m,"Normal opponents");
    menu_additem(m,"Hard opponents");
    menu_additem(m,"Add CT bot");
    menu_additem(m,"Remove all bots");
    menu_display(id,m);
    return PLUGIN_HANDLED;
}
public bot_choice(id,m,item) {
    menu_destroy(m);
    if (!local_player(id) || item<0) return PLUGIN_HANDLED;
    if (item==3) return add_ct(id);
    if (item==4) return clear_bots(id);
    set_cvar_num("yb_difficulty",item*2);
    server_cmd("yb kickall instant");
    if (owned_reflex()) server_cmd("yb add %d 0 %d 1 Lab-Opponent",item*2,3-_:cs_get_user_team(g_reflex));
    return PLUGIN_HANDLED;
}

public client_disconnected(id) { if (id==g_pilot) release_pilot(); }

public plugin_cfg(){g_site=clamp(get_pcvar_num(g_site_mode)-1,0,1);load_site_route();}
