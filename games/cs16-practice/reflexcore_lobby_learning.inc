// Shadow learning: observations never enter the active navigation policy.
enum _:RouteSample { CellX, CellY, CellZ, Heading, Team, Rounds, SeenAt }
new g_samples[128][RouteSample], g_sample_count, g_last_round[128];
new g_teacher, g_teacher_uid, g_round_serial=1, g_sample_path[144];
new bool:g_anchor_valid, bool:g_samples_dirty, Float:g_anchor[3], g_anchor_team;

load_human_routes() {
    new map[48], bsp[80];
    get_mapname(map,charsmax(map));
    formatex(bsp,charsmax(bsp),"maps/%s.bsp",map);
    formatex(g_sample_path,charsmax(g_sample_path),"addons/reflex-lobby/human-routes-v1-%s-%d.bin",map,file_size(bsp));
    new file=fopen(g_sample_path,"rb");
    if (!file) return;
    while (g_sample_count<sizeof(g_samples) && fread_blocks(file,g_samples[g_sample_count],RouteSample,BLOCK_INT)==RouteSample)
        g_sample_count++;
    fclose(file);
}

save_human_routes() {
    if (!g_samples_dirty) return;
    new file=fopen(g_sample_path,"wb");
    if (!file) return;
    for (new i=0;i<g_sample_count;i++) fwrite_blocks(file,g_samples[i],RouteSample,BLOCK_INT);
    fclose(file);
    g_samples_dirty=false;
}

public plugin_end() { save_human_routes(); }
public new_learning_round() {
    save_human_routes();
    g_round_serial++;
    g_anchor_valid=false;
}

public sample_human_route() {
    if (!g_teacher_uid) return;
    if (!local_player(g_teacher) || get_user_userid(g_teacher)!=g_teacher_uid) {
        g_teacher_uid=0;
        g_anchor_valid=false;
        save_human_routes();
        return;
    }
    new team=get_user_team(g_teacher);
    if (g_teacher==g_pilot || !is_user_alive(g_teacher) || (team!=1 && team!=2)
        || pev(g_teacher,pev_movetype)!=MOVETYPE_WALK || !(pev(g_teacher,pev_flags)&FL_ONGROUND)) {
        g_anchor_valid=false;
        return;
    }
    new Float:pos[3];
    pev(g_teacher,pev_origin,pos);
    if (g_anchor_valid && team==g_anchor_team) {
        new Float:dx=pos[0]-g_anchor[0], Float:dy=pos[1]-g_anchor[1];
        new Float:d2=dx*dx+dy*dy;
        if (d2<48.0*48.0) return;
        if (d2<=120.0*120.0 && floatabs(pos[2]-g_anchor[2])<=24.0) {
            new row[RouteSample];
            for (new k=0;k<3;k++) row[k]=floatround(g_anchor[k]/96.0,floatround_floor);
            row[Heading]=(floatround(floatatan2(dy,dx,degrees)/45.0)+8)%8;
            row[Team]=team;
            remember_sample(row);
        }
    }
    g_anchor=pos;
    g_anchor_team=team;
    g_anchor_valid=true;
}

remember_sample(row[RouteSample]) {
    new slot=0;
    while (slot<g_sample_count) {
        new k=0;
        while (k<Rounds && g_samples[slot][k]==row[k]) k++;
        if (k==Rounds) break;
        slot++;
    }
    if (slot==g_sample_count) {
        if (slot==sizeof(g_samples)) {
            slot=0;
            for (new i=1;i<g_sample_count;i++)
                if (g_samples[i][SeenAt]<g_samples[slot][SeenAt]) slot=i;
        } else g_sample_count++;
        g_samples[slot]=row;
        g_last_round[slot]=0;
    }
    if (g_last_round[slot]==g_round_serial) return;
    g_last_round[slot]=g_round_serial;
    g_samples[slot][Rounds]++;
    g_samples[slot][SeenAt]=get_systime();
    g_samples_dirty=true;
}

public learning_menu(id) {
    if (!local_player(id)) return PLUGIN_HANDLED;
    new m=menu_create("Route learning | Manual play","learning_choice");
    menu_additem(m,g_teacher_uid ? "Switch to Standard (stop recording)" : "Start Experimental (observe my movement)");
    menu_additem(m,"Learning history");
    menu_display(id,m);
    return PLUGIN_HANDLED;
}

public learning_choice(id,m,item) {
    menu_destroy(m);
    if (!local_player(id) || item<0) return PLUGIN_HANDLED;
    if (item==0) {
        g_teacher=id;
        g_teacher_uid=g_teacher_uid ? 0 : get_user_userid(id);
        g_anchor_valid=false;
        save_human_routes();
        client_print(id,print_chat,g_teacher_uid ? "[ReflexCore] Recording manual routes. F9 pauses observation. Standard play stays active." : "[ReflexCore] Standard mode. Recording stopped.");
    } else {
        new page[1400],len,shown[8],count;
        len=formatex(page,charsmax(page),"Observed directions on this map: %d / 128^nRepeated routes are candidates for review. Automatic activation is off.^n^n",g_sample_count);
        while (count<sizeof(shown) && count<g_sample_count) {
            new best=-1;
            for (new i=0;i<g_sample_count;i++) {
                new j=0;
                while (j<count && shown[j]!=i) j++;
                if (j==count && (best<0 || g_samples[i][SeenAt]>g_samples[best][SeenAt])) best=i;
            }
            shown[count++]=best;
            new stamp[24];
            format_time(stamp,charsmax(stamp),"%m-%d %H:%M",g_samples[best][SeenAt]);
            len+=formatex(page[len],charsmax(page)-len,"%s  %s  cell (%d,%d,%d)  heading %d deg  |  %d round(s)^n",stamp,
                g_samples[best][Team]==1 ? "T" : "CT",g_samples[best][CellX],g_samples[best][CellY],g_samples[best][CellZ],
                g_samples[best][Heading]*45,g_samples[best][Rounds]);
        }
        show_motd(id,page,"Learning history | Latest observations");
    }
    return PLUGIN_HANDLED;
}
