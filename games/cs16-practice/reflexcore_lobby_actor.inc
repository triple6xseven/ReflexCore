#include <fakemeta>
#include <vault>

new g_reflex, g_reflex_userid, g_leader_userid;
new Float:g_patrol_yaw, Float:g_last_position[3], Float:g_check_at;
new bool:g_travel_reported;
new Float:g_spawn_origin[3];
// Keep only recent occupied cells. Each entry is local to this actor's current life.
new g_cells[96][3], g_cell_count, g_next_cell, g_cell_transitions;
new g_visible_samples, g_clip_decrements;
new bool:g_hold;
new g_pilot, g_pilot_userid, g_pilot_buttons;
new Float:g_pilot_angles[3], Float:g_pilot_speed, Float:g_pilot_at;
new bool:g_prior_roam, bool:g_prior_hold;

new bool:g_roam, Float:g_route[128][3], g_route_count, g_waypoint = -1;
new Float:g_progress_at, Float:g_best_distance;

new g_site, bool:g_planted;
new g_site_mode, g_memory_limit, g_learning, g_training_position;
new g_defense_node, g_defense_style, g_defense_score[2][2];

new bool:g_position_reached, bool:g_defense_scored;
new g_defender_userid, g_defense_key[2][2][96];

load_defense_memory() {
    new map[40], bsp[64];
    get_mapname(map,charsmax(map));
    formatex(bsp,charsmax(bsp),"maps/%s.bsp",map);
    for (new site=0;site<2;site++) {
        for (new style=0;style<2;style++) {
            formatex(g_defense_key[site][style],95,"reflex_defense_v1_%s_%d_%d_%d",map,file_size(bsp),site,style);
            g_defense_score[site][style]=clamp(get_vaultdata(g_defense_key[site][style]),-8,8);
        }
    }
}

public begin_defense() {
    g_position_reached=false;
    g_defense_scored=false;
    g_defender_userid=g_pilot ? 0 : g_reflex_userid;
    g_planted=true;
    g_defense_style=random_num(0,3)==0 ? random_num(0,1) : _:(g_defense_score[g_site][1]>g_defense_score[g_site][0]);
    new forced=get_pcvar_num(g_training_position);
    if (forced==1 || forced==2) g_defense_style=forced-1;
    g_defense_node=max(0,g_route_count-2-g_defense_style*2);
}

public finish_defense() {
    if (g_pilot || !g_planted || !g_roam || !owned_reflex() || cs_get_user_team(g_reflex)!=CS_TEAM_T) return;
    if (!get_pcvar_num(g_learning)) return;
    if (!g_position_reached || g_defense_scored || g_defender_userid!=g_reflex_userid) return;
    g_defense_scored=true;
    new msg[24];
    read_data(2,msg,charsmax(msg));
    new change=equal(msg,"%!MRAD_terwin") ? 1 : -1;
    g_defense_score[g_site][g_defense_style]=clamp(g_defense_score[g_site][g_defense_style]+change,-8,8);
    new value[8];
    num_to_str(g_defense_score[g_site][g_defense_style],value,charsmax(value));
    set_vaultdata(g_defense_key[g_site][g_defense_style],value);
    server_print("Lobby defense result: site=%d style=%d reward=%d score=%s",g_site,g_defense_style,change,value);
}
load_site_route() {
    g_route_count=0;
    new file = fopen(g_site ? "addons/reflex-lobby/route1.txt" : "addons/reflex-lobby/route0.txt", "rt");
    if (!file) return;
    new line[96], x[24], y[24], z[24];
    while (g_route_count < sizeof(g_route) && fgets(file,line,charsmax(line))) {
        if (parse(line,x,charsmax(x),y,charsmax(y),z,charsmax(z)) != 3) break;
        g_route[g_route_count][0]=str_to_float(x);
        g_route[g_route_count][1]=str_to_float(y);
        g_route[g_route_count++][2]=str_to_float(z);
    }
    fclose(file);
}

bool:site_move(const Float:origin[3], Float:angles[3], &buttons, &Float:speed) {
    if (!g_route_count) return false;
    if (g_waypoint < 0) {
        new tr=create_tr2();
        for (new i=g_route_count-1;i>=0;i--) {
            if (get_distance_f(origin,g_route[i]) > 300.0) continue;
            engfunc(EngFunc_TraceLine,origin,g_route[i],IGNORE_MONSTERS,g_pilot ? g_pilot : g_reflex,tr);
            new Float:clearance;
            get_tr2(tr,TR_flFraction,clearance);
            if (clearance < 0.99) continue;
            g_waypoint=i;
            g_best_distance=99999.0;
            break;
        }
        free_tr2(tr);
        if (g_waypoint < 0) return false;
    }
    new Float:distance=get_distance_f(origin,g_route[g_waypoint]);
    if (distance < 23.0) {
        if (g_waypoint+1 == g_route_count) {speed=0.0; return true;}
        g_waypoint++;
        distance=get_distance_f(origin,g_route[g_waypoint]);
        server_print("Lobby site route waypoint %d/%d",g_waypoint,g_route_count);
        g_best_distance=99999.0;
    }
    if (distance < g_best_distance-3.0) {
        g_best_distance=distance;
        g_progress_at=get_gametime();
    }
    angles[1]=floatatan2(g_route[g_waypoint][1]-origin[1],g_route[g_waypoint][0]-origin[0],degrees);
    angles[0]=0.0;
    speed=distance < 48.0 ? 125.0 : 235.0;
    if (get_gametime()-g_progress_at > 0.5 && (pev(g_pilot ? g_pilot : g_reflex,pev_flags)&FL_ONGROUND)) buttons |= IN_JUMP;
    if (get_gametime()-g_progress_at > 2.0) {g_waypoint=-1;return false;}
    return true;
}
new Float:g_trail[256][3], g_trail_count, g_trail_next, g_buy_attempts;
new Float:g_next_buy;

// A bounded map-local record of patrol headings that repeatedly stalled.
new g_stalls[128][5], g_stall_count, g_stall_next;
new bool:g_stalls_dirty, bool:g_patrolled, g_memory_path[112];

setup_patrol_memory() {
    new map[48], bsp[80];
    get_mapname(map, charsmax(map));
    formatex(bsp, charsmax(bsp), "maps/%s.bsp", map);
    formatex(g_memory_path, charsmax(g_memory_path), "addons/reflex-lobby/patrol-v1-%s-%d.bin", map, file_size(bsp));
    new file = fopen(g_memory_path, "rb");
    if (!file) return;
    while (g_stall_count < sizeof(g_stalls) && fread_blocks(file, g_stalls[g_stall_count], 5, BLOCK_INT) == 5)
        g_stall_count++;
    fclose(file);
    g_stall_next = g_stall_count % sizeof(g_stalls);
    server_print("Lobby restored %d patrol memory entries", g_stall_count);
}

public save_patrol_memory() {
    if (!g_stalls_dirty || !lobby_is_local()) return;
    new file = fopen(g_memory_path, "wb");
    if (!file) return;
    for (new i = 0; i < g_stall_count; i++)
        fwrite_blocks(file, g_stalls[i], 5, BLOCK_INT);
    fclose(file);
    g_stalls_dirty = false;
}

stall_record(const Float:point[3], Float:yaw, change) {
    new key[4];
    for (new i = 0; i < 3; i++) key[i] = cell_coord(point[i]);
    key[3] = ((floatround(yaw / 45.0) % 8) + 8) % 8;
    for (new i = 0; i < g_stall_count; i++) {
        if (g_stalls[i][0] != key[0] || g_stalls[i][1] != key[1] || g_stalls[i][2] != key[2] || g_stalls[i][3] != key[3]) continue;
        new score = clamp(g_stalls[i][4] + change, 0, 4);
        if (score != g_stalls[i][4]) { g_stalls[i][4] = score; g_stalls_dirty = true; }
        return score;
    }
    if (change > 0) {
        for (new i = 0; i < 4; i++) g_stalls[g_stall_next][i] = key[i];
        g_stalls[g_stall_next][4] = change;
        g_stall_next = (g_stall_next + 1) % sizeof(g_stalls);
        if (g_stall_count < sizeof(g_stalls)) g_stall_count++;
        g_stalls_dirty = true;
    }
    return 0;
}

remember_leader(const Float:origin[3]) {
    new last = (g_trail_next + sizeof(g_trail) - 1) % sizeof(g_trail);
    if (g_trail_count && get_distance_f(origin, g_trail[last]) < 48.0) return;
    for (new i = 0; i < 3; i++) g_trail[g_trail_next][i] = origin[i];
    g_trail_next = (g_trail_next + 1) % sizeof(g_trail);
    if (g_trail_count < clamp(get_pcvar_num(g_memory_limit),1,sizeof(g_trail))) g_trail_count++;
}

bool:follow_trail(const Float:origin[3], Float:angles[3]) {
    new tr = create_tr2(), bool:found;
    for (new n = 1; n <= g_trail_count; n++) {
        new index = (g_trail_next + sizeof(g_trail) - n) % sizeof(g_trail);
        new Float:distance=get_distance_f(origin,g_trail[index]);
        if (distance<32.0) break;
        if (distance>384.0) continue;
        engfunc(EngFunc_TraceHull, origin, g_trail[index], IGNORE_MONSTERS, HULL_HUMAN, g_pilot ? g_pilot : g_reflex, tr);
        new Float:fraction;
        get_tr2(tr, TR_flFraction, fraction);
        if (fraction < 0.99 || get_tr2(tr, TR_StartSolid)) {
            if (get_distance_f(origin,g_trail[index])>96.0) continue;
            new Float:raised[3], Float:end[3];
            for (new k=0;k<3;k++) {raised[k]=origin[k];end[k]=g_trail[index][k];}
            raised[2]+=18.0;
            end[2]+=18.0;
            engfunc(EngFunc_TraceHull,origin,raised,IGNORE_MONSTERS,HULL_HUMAN,g_pilot ? g_pilot : g_reflex,tr);
            get_tr2(tr,TR_flFraction,fraction);
            if (fraction<0.99 || get_tr2(tr,TR_StartSolid)) continue;
            engfunc(EngFunc_TraceHull,raised,end,IGNORE_MONSTERS,HULL_HUMAN,g_pilot ? g_pilot : g_reflex,tr);
            get_tr2(tr,TR_flFraction,fraction);
            if (fraction<0.99 || get_tr2(tr,TR_StartSolid)) continue;
        }
        angles[1] = floatatan2(g_trail[index][1]-origin[1], g_trail[index][0]-origin[0], degrees);
        angles[0] = 0.0;
        found = true;
        break;
    }
    free_tr2(tr);
    return found;
}

cell_coord(Float:value) { return floatround(value / 96.0, floatround_floor); }

record_cell(const Float:origin[3])
{
    new cell[3];
    for(new k=0;k<3;k++) cell[k]=cell_coord(origin[k]);
    if(g_cell_count){
        new prev=(g_next_cell+sizeof(g_cells)-1)%sizeof(g_cells);
        if(cell[0]==g_cells[prev][0] && cell[1]==g_cells[prev][1] && cell[2]==g_cells[prev][2]) return;
    }
    for(new k=0;k<3;k++) g_cells[g_next_cell][k]=cell[k];
    g_next_cell=(g_next_cell+1)%sizeof(g_cells);
    if(g_cell_count<sizeof(g_cells)) g_cell_count++;
    g_cell_transitions++;
}

visits(const Float:point[3]){
    new x=cell_coord(point[0]),y=cell_coord(point[1]),z=cell_coord(point[2]),count;
    for(new i=0;i<g_cell_count;i++) if(g_cells[i][0]==x && g_cells[i][1]==y && g_cells[i][2]==z) count++;
    return count;
}


bool:owned_reflex()
{
    return g_reflex > 0 && is_user_connected(g_reflex) && is_user_bot(g_reflex)
        && get_user_userid(g_reflex) == g_reflex_userid;
}

remove_reflex()
{
    if (owned_reflex()) {
        server_cmd("kick #%d", g_reflex_userid);
        server_exec();
    }
    g_reflex = g_reflex_userid = g_leader_userid = 0;
}

bool:join_reflex(team, leader)
{
    new reject[128], bot = engfunc(EngFunc_CreateFakeClient, "ReflexCore");
    if (bot <= 0) return false;
    engfunc(EngFunc_FreeEntPrivateData, bot);
    dllfunc(MetaFunc_CallGameEntity, "player", bot);
    if (!dllfunc(DLLFunc_ClientConnect, bot, "ReflexCore", "127.0.0.1", reject)) return false;
    dllfunc(DLLFunc_ClientPutInServer, bot);
    set_pev(bot, pev_flags, pev(bot, pev_flags) | FL_FAKECLIENT | FL_CLIENT);
    g_reflex = bot;
    g_reflex_userid = get_user_userid(bot);
    g_leader_userid = leader;
    g_hold = false;
    g_roam = false;
    g_waypoint = -1;
    g_buy_attempts = g_trail_count = 0;
    g_next_buy = 0.0;
    new Float:angles[3], value[2];
    num_to_str(team, value, charsmax(value));
    for (new i = 0; i < 4 && get_ent_data(bot,"CBasePlayer","m_iJoiningState") != 4; i++)
        engfunc(EngFunc_RunPlayerMove, bot, angles, 0.0, 0.0, 0.0, 0, 0, 1);
    engclient_cmd(bot, "jointeam", value);
    engclient_cmd(bot, "joinclass", "1");
    for (new i = 0; i < 4 && get_ent_data(bot,"CBasePlayer","m_iJoiningState") != 0; i++)
        engfunc(EngFunc_RunPlayerMove, bot, angles, 0.0, 0.0, 0.0, 0, 0, 1);
    if (_:cs_get_user_team(bot) == team) {
        g_check_at = 0.0;
        return true;
    }
    remove_reflex();
    return false;
}

// Probe standing hull clearance in the current map when no player is visible.
Float:patrol_direction(const Float:origin[3], Float:yaw)
{
    static const Float:turns[] = {0.0,45.0,-45.0,90.0,-90.0,135.0,-135.0,180.0};
    new trace=create_tr2();
    new Float:best=-1000.0, Float:choice=yaw;
    for(new i=0;i<sizeof(turns);i++){
        new Float:heading=yaw+turns[i], Float:end[3], Float:fraction;
        end[0]=origin[0]+floatcos(heading,degrees)*150.0;
        end[1]=origin[1]+floatsin(heading,degrees)*150.0;
        end[2]=origin[2];
        engfunc(EngFunc_TraceHull,origin,end,DONT_IGNORE_MONSTERS,HULL_HUMAN,g_pilot ? g_pilot : g_reflex,trace);
        get_tr2(trace,TR_flFraction,fraction);
        if(fraction<0.3) continue;
        for(new k=0;k<2;k++) end[k]=origin[k]+(end[k]-origin[k])*fraction;
        new Float:score=fraction*4.0-floatmin(float(visits(end)),3.0)-floatabs(turns[i])/360.0;
        score -= float(stall_record(origin, heading, 0));
        if(score>best){best=score;choice=heading;}
    }
    free_tr2(trace);
    return choice;
}

public lobby_tick()
{
    if (g_pilot && (!local_player(g_pilot) || !is_user_alive(g_pilot) || get_user_userid(g_pilot)!=g_pilot_userid)) release_pilot();
    if (!lobby_is_local() || (!g_pilot && !owned_reflex())) return;
    new actor=g_pilot ? g_pilot : g_reflex;
    if (!is_user_alive(actor)) return;
    new CsTeams:team = cs_get_user_team(actor);
    if (team != CS_TEAM_CT && team != CS_TEAM_T) return;
    if (g_buy_attempts < 4 && get_gametime() >= g_next_buy && cs_get_user_buyzone(actor)) {
        new rifle = team == CS_TEAM_T ? CSW_AK47 : CSW_M4A1;
        if (!user_has_weapon(actor, rifle)) {
            amxclient_cmd(actor, team == CS_TEAM_T ? "ak47" : "m4a1");
            if (user_has_weapon(actor, rifle)) {
                amxclient_cmd(actor, "primammo");
                engclient_cmd(actor, team == CS_TEAM_T ? "weapon_ak47" : "weapon_m4a1");
                server_print("Lobby Reflex rifle purchase confirmed");
            }
        }
        new CsArmorType:armor;
        if (cs_get_user_armor(actor,armor)<100 || armor!=CS_ARMOR_VESTHELM) {
            amxclient_cmd(actor,"vesthelm");
            if (cs_get_user_armor(actor,armor)==100 && armor==CS_ARMOR_VESTHELM)
                server_print("Lobby armor and helmet verified");
        }
        g_buy_attempts++;
        g_next_buy=get_gametime()+0.6;
    }
    new Float:eye[3], Float:offset[3], Float:angles[3], Float:dest[3], Float:point[3];
    pev(actor,pev_origin,eye);
    pev(actor,pev_view_ofs,offset);
    for (new k=0;k<3;k++) eye[k]+=offset[k];
    new target, leader, trace=create_tr2();
    new Float:best=99999.0;
    for(new id=1;id<=get_maxplayers();id++){
        if (id==actor || !is_user_alive(id)) continue;
        new CsTeams:other=cs_get_user_team(id);
        if(other!=CS_TEAM_CT && other!=CS_TEAM_T) continue;
        pev(id,pev_origin,point);
        if (other == team && get_user_userid(id) == g_leader_userid && !g_hold && (pev(id, pev_flags) & FL_ONGROUND))
            remember_leader(point);
        point[2]+=14.0;
        engfunc(EngFunc_TraceLine,eye,point,DONT_IGNORE_MONSTERS,actor,trace);
        if(get_tr2(trace,TR_pHit)!=id) continue;
        if(other==team){
            if(get_user_userid(id)==g_leader_userid) leader=id;
            continue;
        }
        new Float:dist=get_distance_f(eye,point);
        if(dist<best){best=dist;target=id;}
    }
    free_tr2(trace);
    new buttons;
    new Float:speed;
    if (g_roam) leader=0;
    new focus=target ? target : leader;
    pev(actor,pev_v_angle,angles);
    if(focus){
        pev(focus,pev_origin,dest);
        dest[2]+=14.0;
        if(!target && get_distance_f(eye,dest)>105.0) speed=180.0;
        for(new j=0;j<3;j++) dest[j]-=eye[j];
        engfunc(EngFunc_VecToAngles,dest,angles);
        angles[0]=angles[0]>180.0 ? 360.0-angles[0] : -angles[0];
        if(target){
            g_visible_samples++;
            new clip,reserve;
            get_user_weapon(actor,clip,reserve);
            if(clip==0 && reserve>0) buttons=IN_RELOAD;
            else if(clip>0) buttons=IN_ATTACK;
        }
    }
    if (focus || g_hold) g_patrolled = false;
    if(!focus && !g_hold){
        new Float:origin[3]; pev(actor,pev_origin,origin);
        if(get_gametime()>=g_check_at){
            record_cell(origin);
            if(g_check_at==0.0){
                g_patrol_yaw=angles[1];
                for(new i=0;i<3;i++) g_spawn_origin[i]=origin[i];
                g_travel_reported=false;
            }else if(g_patrolled){
                new bool:stalled = get_distance_f(origin,g_last_position)<10.0;
                stall_record(g_last_position, g_patrol_yaw, stalled ? 1 : -1);
                if (stalled) g_patrol_yaw+=75.0;
            }
            g_patrol_yaw=patrol_direction(origin,g_patrol_yaw);
            for(new i=0;i<3;i++) g_last_position[i]=origin[i];
            g_check_at=get_gametime()+0.3;
            g_patrolled = true;
            if(!g_travel_reported && get_distance_f(origin,g_spawn_origin)>160.0){
                g_travel_reported=true;
                server_print("Lobby Reflex patrol displacement exceeded 160 units");
            }
        }
        angles[0]=0.0; angles[1]=g_patrol_yaw;
        speed=165.0;
    }
    if (g_roam && !target && !g_planted) {
        new Float:origin[3];
        pev(actor,pev_origin,origin);
        if (site_move(origin,angles,buttons,speed)) g_patrolled=false;
    }
    if (g_roam && g_planted && !target && g_route_count>1) {
        new Float:origin[3];
        pev(actor,pev_origin,origin);
        angles[1]=floatatan2(g_route[g_defense_node][1]-origin[1],g_route[g_defense_node][0]-origin[0],degrees);
        speed=get_distance_f(origin,g_route[g_defense_node])>50.0 ? 175.0 : 0.0;
        if (speed==0.0 && is_user_alive(actor)) g_position_reached=true;
        if(speed>0.0) angles[1]=patrol_direction(origin,angles[1]);
    }
    if (!g_roam && !target && !g_hold && g_trail_count && (!leader || speed > 0.0)) {
        new Float:origin[3];
        pev(actor, pev_origin, origin);
        if (follow_trail(origin, angles)) { speed = 180.0; g_patrolled = false; }
        else if (leader) angles[1] = patrol_direction(origin, angles[1]);
    }
    if (!target && !g_hold && !g_roam && speed>0.0 && g_trail_count && (pev(actor,pev_flags)&FL_ONGROUND)) {
        new Float:velocity[3];
        pev(actor,pev_velocity,velocity);
        if (vector_length(velocity)<15.0) buttons |= IN_JUMP;
    }
    if (!target && !g_hold && speed > 0.0) {
        new Float:end[3];
        end[0] = eye[0] + 64.0 * floatcos(angles[1], degrees);
        end[1] = eye[1] + 64.0 * floatsin(angles[1], degrees);
        end[2] = eye[2];
        new door_trace = create_tr2();
        engfunc(EngFunc_TraceLine, eye, end, DONT_IGNORE_MONSTERS, actor, door_trace);
        new door = get_tr2(door_trace, TR_pHit);
        free_tr2(door_trace);
        if (door > get_maxplayers() && pev_valid(door)) {
            new classname[32];
            pev(door, pev_classname, classname, charsmax(classname));
            if (equal(classname, "func_door") || equal(classname, "func_door_rotating")) buttons |= IN_USE;
        }
    }
    if (g_hold) speed = 0.0;
    new bool:planting = g_roam && !target && team == CS_TEAM_T && user_has_weapon(actor,CSW_C4)
        && (cs_get_user_mapzones(actor) & CS_MAPZONE_BOMBTARGET) != 0;
    if (planting) {
        speed=0.0;
        if (get_user_weapon(actor)!=CSW_C4) engclient_cmd(actor,"weapon_c4");
        buttons=get_user_weapon(actor)==CSW_C4 ? IN_ATTACK : 0;
    } else if (target && get_user_weapon(actor)==CSW_C4) {
        engclient_cmd(actor,"weapon_ak47");
        buttons=0;
    }
    if (g_pilot) {
        for (new i=0;i<3;i++) g_pilot_angles[i]=angles[i];
        g_pilot_at=get_gametime();
        g_pilot_speed=speed;
        g_pilot_buttons=buttons;
        set_pev(actor,pev_angles,angles);
        set_pev(actor,pev_fixangle,1);
        return;
    }
    if(pev(actor,pev_fixangle)==1) set_pev(actor,pev_fixangle,0);
    engfunc(EngFunc_RunPlayerMove,actor,angles,speed,0.0,0.0,planting ? buttons : 0,0,5);
    new before,after,ammo;
    new weapon=get_user_weapon(actor,before,ammo);
    engfunc(EngFunc_RunPlayerMove,actor,angles,speed,0.0,0.0,buttons,0,95);
    if((buttons & IN_ATTACK) && get_user_weapon(actor,after,ammo)==weapon && before>after && after>=0)
        g_clip_decrements+=before-after;
}
reset_navigation() {
    g_waypoint=-1;
    g_check_at=g_next_buy=0.0;
    g_buy_attempts=g_cell_count=g_next_cell=g_trail_count=0;
    g_position_reached=false;
}

release_pilot() {
    if (!g_pilot) return;
    g_pilot=g_pilot_userid=0;
    g_pilot_at=-1.0;
    g_roam=g_prior_roam;
    g_hold=g_prior_hold;
    reset_navigation();
}

public toggle_pilot(id) {
    if (!local_player(id)) return PLUGIN_HANDLED;
    if (id==g_pilot) {
        release_pilot();
        client_print(id,print_chat,"[ReflexCore] Manual control.");
    } else if (!g_pilot && is_user_alive(id)) {
        g_prior_hold=g_hold;
        g_prior_roam=g_roam;
        g_hold=false;
        g_roam=true;
        reset_navigation();
        g_pilot=id;
        g_pilot_userid=get_user_userid(id);
        g_pilot_at=-1.0;
        client_print(id,print_chat,"[ReflexCore] Autopilot on. Press F9 for manual control.");
    }
    return PLUGIN_HANDLED;
}

public pilot_command(id,cmd,seed) {
    if (!g_pilot || id!=g_pilot) return FMRES_IGNORED;
    if (!is_user_alive(id) || get_user_userid(id)!=g_pilot_userid) {release_pilot();return FMRES_IGNORED;}
    if (get_gametime()-g_pilot_at>0.25) return FMRES_IGNORED;
    set_uc(cmd,UC_ViewAngles,g_pilot_angles);
    set_uc(cmd,UC_ForwardMove,g_pilot_speed);
    set_uc(cmd,UC_SideMove,0.0);
    set_uc(cmd,UC_UpMove,0.0);
    set_uc(cmd,UC_Buttons,g_pilot_buttons);
    return FMRES_HANDLED;
}

