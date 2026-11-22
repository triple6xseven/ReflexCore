#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <csx>
#include <fakemeta>

#define RC_TICK 6701
#define RC_SUBJECT "ReflexCore"
#define RC_PASSIVE_CT "ReflexCore Passive Fixture"
#define RC_SCHEMA "reflexcore_cs16_practice_v1"

new g_enabled, g_max_clients, g_subject, g_userid, g_sequence;
new bool:g_planted, bool:g_t_won, bool:g_initialized;
new bool:g_warned_slow;
new g_passive_ct, g_passive_userid;
new g_map[49], g_directory[192], g_command[224], g_state[224], g_staging[224];
new g_status[16] = "ready";

public plugin_init()
{
    register_plugin("ReflexCore CS16 Practice", "1.0", "ReflexCore");
    g_enabled = register_cvar("rc_practice_enabled", "0");
    g_max_clients = get_maxplayers();
    get_mapname(g_map, charsmax(g_map));
    get_datadir(g_directory, charsmax(g_directory));
    add(g_directory, charsmax(g_directory), "/reflexcore");
    formatex(g_command, charsmax(g_command), "%s/command.txt", g_directory);
    formatex(g_state, charsmax(g_state), "%s/state.txt", g_directory);
    formatex(g_staging, charsmax(g_staging), "%s/state.next", g_directory);
    register_event("HLTV", "new_round", "a", "1=0", "2=0");
    register_event("SendAudio", "terrorist_win", "a", "2=%!MRAD_terwin");
    set_task(0.10, "practice_tick", RC_TICK, "", 0, "b");
}

bool:authorized()
{
    if (!get_pcvar_num(g_enabled) || !is_dedicated_server() || get_cvar_num("sv_lan") != 1)
        return false;

    new ip[32], configured[32];
    get_user_ip(0, ip, charsmax(ip), 1);
    get_cvar_string("ip", configured, charsmax(configured));
    if (!equal(ip, "127.0.0.1") || !equal(configured, "127.0.0.1"))
        return false;

    for (new i = 1; i <= g_max_clients; i++)
    {
        if (is_user_connected(i) && !is_user_bot(i))
            return false;
    }
    return true;
}

bool:owns_subject()
{
    return g_subject > 0 && is_user_connected(g_subject) && is_user_bot(g_subject)
        && get_user_userid(g_subject) == g_userid;
}

bool:t_has_c4()
{
    return owns_subject() && is_user_alive(g_subject) && cs_get_user_team(g_subject) == CS_TEAM_T
        && cs_get_user_plant(g_subject) != 0 && (pev(g_subject, pev_weapons) & (1 << CSW_C4)) != 0;
}

bool:inside_plant_zone()
{
    return t_has_c4() && (cs_get_user_mapzones(g_subject) & CS_MAPZONE_BOMBTARGET) != 0;
}

bool:c4_equipped()
{
    // Fake clients do not necessarily receive the HUD CurWeapon message.
    new weapon = get_ent_data_entity(g_subject, "CBasePlayer", "m_pActiveItem");
    return pev_valid(weapon) == 2 && cs_get_weapon_id(weapon) == CSW_C4;
}

public new_round()
{
    g_planted = false;
    g_t_won = false;
    g_warned_slow = false;
}

public bomb_planted(planter)
{
    if (planter == g_subject && owns_subject())
        g_planted = true;
}

public terrorist_win()
{
    if (owns_subject())
        g_t_won = true;
}

public practice_tick()
{
    if (!authorized())
    {
        if (g_initialized)
        {
            // Invalidate the mailbox so another operator cannot accidentally reuse its last command.
            if (file_exists(g_command)) delete_file(g_command);
            copy(g_status, charsmax(g_status), "unavailable");
            publish_state();
            g_initialized = false;
        }
        return;
    }

    if (!g_initialized)
    {
        if (!dir_exists(g_directory) && mkdir(g_directory) != 0)
            return;
        if (file_exists(g_command)) delete_file(g_command);
        g_initialized = true;
        copy(g_status, charsmax(g_status), "ready");
    }

    if (file_exists(g_command))
        read_command();
    publish_state();
}

bool:is_number(const token[], bool:fraction)
{
    new index, digits, points;
    if (fraction && (token[0] == '-' || token[0] == '+'))
        index++;
    for (; token[index] != 0; index++)
    {
        if (index > 12)
            return false;
        if (token[index] == '.' && fraction && points == 0)
        {
            points++;
            continue;
        }
        if (token[index] < '0' || token[index] > '9')
            return false;
        digits++;
    }
    return digits > 0;
}

read_command()
{
    new line[256], extra[2], parts[7][16];
    new bytes = file_size(g_command, 0), file;
    if (bytes > 0 && bytes < sizeof(line))
    {
        file = fopen(g_command, "rt");
        if (file)
        {
            fgets(file, line, charsmax(line));
            if (fgets(file, extra, charsmax(extra)) != 0)
                line[0] = 0;
            fclose(file);
        }
    }
    if (!delete_file(g_command))
        return;

    if (parse(line, parts[0], 15, parts[1], 15, parts[2], 15, parts[3], 15,
        parts[4], 15, parts[5], 15, parts[6], 15, extra, 1) != 7)
        return;
    for (new i = 0; i < 7; i++)
    {
        if (!is_number(parts[i], i >= 2 && i <= 4))
            return;
    }

    // Sequence is monotonic across the process lifetime. Bound integers before converting them.
    if (strlen(parts[0]) > 9 || strlen(parts[1]) > 1 || strlen(parts[5]) > 1 || strlen(parts[6]) > 3)
        return;
    new sequence = str_to_num(parts[0]);
    if (sequence <= g_sequence)
        return;

    g_sequence = sequence;
    new operation = str_to_num(parts[1]);
    new Float:yaw = str_to_float(parts[2]);
    new Float:forward_speed = str_to_float(parts[3]);
    new Float:side_speed = str_to_float(parts[4]);
    new buttons = str_to_num(parts[5]);
    new millis = str_to_num(parts[6]);
    if (floatabs(yaw) > 360.0 || floatabs(forward_speed) > 250.0 || floatabs(side_speed) > 250.0
        || buttons & ~(IN_ATTACK | IN_JUMP | IN_DUCK) || millis > 100)
    {
        copy(g_status, charsmax(g_status), "rejected");
        return;
    }
    if (operation != 2 && (yaw != 0.0 || forward_speed != 0.0 || side_speed != 0.0 || buttons || millis))
    {
        copy(g_status, charsmax(g_status), "rejected");
        return;
    }

    switch (operation)
    {
        case 1:
        {
            if (owns_subject() || add_subject())
                copy(g_status, charsmax(g_status), "added");
            else
                copy(g_status, charsmax(g_status), "unavailable");
        }
        case 2:
        {
            if (move_subject(yaw, forward_speed, side_speed, buttons, millis))
                copy(g_status, charsmax(g_status), "moved");
            else
                copy(g_status, charsmax(g_status), "rejected");
        }
        case 3:
        {
            if (owns_subject() && is_user_alive(g_subject))
            {
                new Float:angles[3];
                pev(g_subject, pev_v_angle, angles);
                engfunc(EngFunc_RunPlayerMove, g_subject, angles, 0.0, 0.0, 0.0, 0, 0, 1);
            }
            copy(g_status, charsmax(g_status), "stopped");
        }
        case 4:
        {
            if (inside_plant_zone())
            {
                engclient_cmd(g_subject, "weapon_c4");
                copy(g_status, charsmax(g_status), "equipped");
            }
            else
                copy(g_status, charsmax(g_status), "rejected");
        }
        case 5:
        {
            if (owns_subject() && cs_get_user_team(g_subject) == CS_TEAM_T)
            {
                server_cmd("sv_restart 1");
                copy(g_status, charsmax(g_status), "restarting");
            }
            else
                copy(g_status, charsmax(g_status), "rejected");
        }
        case 6:
        {
            // A stationary fixture opponent activates normal two-team round rules.
            // It has no AI driver and receives no movement commands.
            if (g_passive_ct <= 0 || !is_user_connected(g_passive_ct)
                || get_user_userid(g_passive_ct) != g_passive_userid)
            {
                g_passive_ct = add_fake_client(RC_PASSIVE_CT, "2");
                g_passive_userid = g_passive_ct > 0 ? get_user_userid(g_passive_ct) : 0;
            }
            copy(g_status, charsmax(g_status), g_passive_userid > 0 ? "passive_ct" : "unavailable");
        }
        default: copy(g_status, charsmax(g_status), "rejected");
    }
}

bool:add_subject()
{
    g_subject = add_fake_client(RC_SUBJECT, "1");
    g_userid = g_subject > 0 ? get_user_userid(g_subject) : 0;
    return owns_subject();
}

add_fake_client(const name[], const team[])
{
    new reject[128], actor = engfunc(EngFunc_CreateFakeClient, name);
    if (actor < 1 || actor > g_max_clients)
        return 0;

    engfunc(EngFunc_FreeEntPrivateData, actor);
    dllfunc(MetaFunc_CallGameEntity, "player", actor);
    if (!dllfunc(DLLFunc_ClientConnect, actor, name, "127.0.0.1", reject))
        return 0;
    dllfunc(DLLFunc_ClientPutInServer, actor);
    set_pev(actor, pev_flags, pev(actor, pev_flags) | FL_FAKECLIENT | FL_CLIENT);
    set_pev(actor, pev_spawnflags, pev(actor, pev_spawnflags) | FL_FAKECLIENT);
    if (!is_user_connected(actor) || !is_user_bot(actor) || get_user_userid(actor) <= 0)
        return 0;

    engclient_cmd(actor, "jointeam", team);
    engclient_cmd(actor, "joinclass", "1");
    return actor;
}

bool:move_subject(Float:yaw, Float:forward_speed, Float:side_speed, buttons, millis)
{
    if (!owns_subject() || !is_user_alive(g_subject) || cs_get_user_team(g_subject) != CS_TEAM_T || millis < 1)
        return false;
    if ((buttons & IN_ATTACK) && (!inside_plant_zone() || !c4_equipped()))
        return false;
    new Float:max_speed;
    pev(g_subject, pev_maxspeed, max_speed);
    if (!g_warned_slow && (forward_speed || side_speed) && max_speed <= 1.0)
    {
        server_print("ReflexCore practice: engine limited movement (maximum speed %.2f).", max_speed);
        g_warned_slow = true;
    }
    new Float:angles[3];
    angles[1] = yaw;
    engfunc(EngFunc_RunPlayerMove, g_subject, angles, forward_speed, side_speed, 0.0, buttons, 0, millis);
    return true;
}

publish_state()
{
    new userid, alive, team, c4, zone, armed, ct_bots;
    new Float:point[3], Float:angles[3];
    if (owns_subject() && !equal(g_status, "unavailable"))
    {
        userid = g_userid;
        alive = is_user_alive(g_subject);
        team = _:cs_get_user_team(g_subject);
        c4 = t_has_c4();
        zone = inside_plant_zone();
        armed = alive && c4_equipped();
        pev(g_subject, pev_origin, point);
        pev(g_subject, pev_v_angle, angles);
    }
    for (new i = 1; i <= g_max_clients; i++)
    {
        if (i != g_subject && is_user_connected(i) && is_user_bot(i) && cs_get_user_team(i) == CS_TEAM_CT)
            ct_bots++;
    }

    new file = fopen(g_staging, "wt");
    if (!file)
        return;
    fprintf(file, "%s %s %d %.6f %d %d %d %.6f %.6f %.6f %.6f %d %d %d %d %d %d %s^n",
        RC_SCHEMA, g_map, g_sequence, get_gametime(), userid, alive, team, point[0], point[1], point[2],
        angles[1], c4, zone, armed, g_planted, g_t_won, ct_bots, g_status);
    fclose(file);
    // AMXX's rename_file cannot overwrite a destination on Windows.
    if (file_exists(g_state) && !delete_file(g_state))
        return;
    rename_file(g_staging, g_state, 1);
}
