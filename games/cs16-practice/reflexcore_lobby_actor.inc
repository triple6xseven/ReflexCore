#include <fakemeta>

new g_reflex, g_reflex_userid, g_leader_userid;
new Float:g_patrol_yaw, Float:g_last_position[3], Float:g_check_at;
new bool:g_travel_reported;
new Float:g_spawn_origin[3];
// Keep only recent occupied cells. Each entry is local to this actor's current life.
new g_cells[96][3], g_cell_count, g_next_cell, g_cell_transitions;
new g_visible_samples, g_clip_decrements;

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
        engfunc(EngFunc_TraceHull,origin,end,DONT_IGNORE_MONSTERS,HULL_HUMAN,g_reflex,trace);
        get_tr2(trace,TR_flFraction,fraction);
        if(fraction<0.3) continue;
        for(new k=0;k<2;k++) end[k]=origin[k]+(end[k]-origin[k])*fraction;
        new Float:score=fraction*4.0-floatmin(float(visits(end)),3.0)-floatabs(turns[i])/360.0;
        if(score>best){best=score;choice=heading;}
    }
    free_tr2(trace);
    return choice;
}

public lobby_tick()
{
    if (!lobby_is_local() || !owned_reflex() || !is_user_alive(g_reflex)) return;
    new CsTeams:team = cs_get_user_team(g_reflex);
    if (team != CS_TEAM_CT && team != CS_TEAM_T) return;
    new Float:eye[3], Float:offset[3], Float:angles[3], Float:dest[3], Float:point[3];
    pev(g_reflex,pev_origin,eye);
    pev(g_reflex,pev_view_ofs,offset);
    for (new k=0;k<3;k++) eye[k]+=offset[k];
    new target, leader, trace=create_tr2();
    new Float:best=99999.0;
    for(new id=1;id<=get_maxplayers();id++){
        if (id==g_reflex || !is_user_alive(id)) continue;
        new CsTeams:other=cs_get_user_team(id);
        if(other!=CS_TEAM_CT && other!=CS_TEAM_T) continue;
        pev(id,pev_origin,point);
        point[2]+=14.0;
        engfunc(EngFunc_TraceLine,eye,point,DONT_IGNORE_MONSTERS,g_reflex,trace);
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
    new focus=target ? target : leader;
    pev(g_reflex,pev_v_angle,angles);
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
            get_user_weapon(g_reflex,clip,reserve);
            if(clip==0 && reserve>0) buttons=IN_RELOAD;
            else if(clip>0) buttons=IN_ATTACK;
        }
    }
    if(!focus){
        new Float:origin[3]; pev(g_reflex,pev_origin,origin);
        if(get_gametime()>=g_check_at){
            record_cell(origin);
            if(g_check_at==0.0){
                g_patrol_yaw=angles[1];
                for(new i=0;i<3;i++) g_spawn_origin[i]=origin[i];
                g_travel_reported=false;
            }else if(get_distance_f(origin,g_last_position)<10.0) g_patrol_yaw+=75.0;
            g_patrol_yaw=patrol_direction(origin,g_patrol_yaw);
            for(new i=0;i<3;i++) g_last_position[i]=origin[i];
            g_check_at=get_gametime()+0.3;
            if(!g_travel_reported && get_distance_f(origin,g_spawn_origin)>160.0){
                g_travel_reported=true;
                server_print("Lobby Reflex patrol displacement exceeded 160 units");
            }
        }
        angles[0]=0.0; angles[1]=g_patrol_yaw;
        speed=165.0;
    }
    if(pev(g_reflex,pev_fixangle)==1) set_pev(g_reflex,pev_fixangle,0);
    engfunc(EngFunc_RunPlayerMove,g_reflex,angles,speed,0.0,0.0,0,0,5);
    new before,after,ammo;
    new weapon=get_user_weapon(g_reflex,before,ammo);
    engfunc(EngFunc_RunPlayerMove,g_reflex,angles,speed,0.0,0.0,buttons,0,95);
    if((buttons & IN_ATTACK) && get_user_weapon(g_reflex,after,ammo)==weapon && before>after && after>=0)
        g_clip_decrements+=before-after;
}
