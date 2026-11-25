# Local team play on Dust II

In Studio, open **CS 1.6 & Control** and choose **Play with a teammate**. Start the local server. **Copy join command** gives you the console command for an already running game. **Open second game window** launches the private replay client on a different client port. On Windows the tested two-window setup uses an existing Sandboxie Plus DefaultBox. Its first launch may display a Sandboxie dialog. This uses the existing game folders.

Join T or CT. The first local player to choose a team gets a ReflexCore teammate and one YaPB opponent. Press **H** to change sides, remove bots, add a CT or restart the round. Stop the server from the lobby or close its window. The server runs only on 127.0.0.1:27164. Each client uses its own controls. Each client can connect to the same loopback address. Only the focused game receives normal keyboard input.

Reflex runs as a server-side fake client. Its policy follows a visible teammate, probes standing-player clearance to patrol when alone, and uses normal GoldSrc commands on visible opponents. Its team and visibility evidence comes from the game. Patrol favors clear directions leading to less recently visited cells. A 96-entry ring is reset on spawn. There is no saved route or global path planner. YaPB supplies a separate opponent using its bundled Dust II graph. We pin the [upstream Windows archive](https://github.com/yapb/yapb/releases/tag/4.4.957) and verify both archive and DLL. First launch needs access to GitHub and the AMX Mod X compiler from the configured practice lab. The launcher selects lobby-only Metamod and AMXX plugin lists.

## Keys

**Install keys for my game** takes the selected hl.exe. The launcher places reflexcore-lobby.cfg beside the game config and appends one exec line to userconfig.cfg, backing up an existing userconfig before the first edit. To apply to a running game use **Copy join command**. To undo, restore the backup or remove the exec line and restore your preferred bindings from your previous config.

- H opens the local team menu.
- Z buys a Desert Eagle, X buys an HE grenade, C buys armor and helmet, F buys an AWP, N buys a Scout, and V buys the team's AK-47 or M4A1.
- Keypad 1 enables local server cheats, 2 toggles reserve ammunition refill, 3 toggles personal noclip, 4 disables team balancing and 5 removes the team limit.
- Keypad 6 removes bots, 7 adds a CT bot, 8 sets a nine-minute round, and 9 restarts the round. Buy commands follow the game's normal purchase rules.

## Reproduce

Run these individually with the lab free. ProbeClient uses the operator's configured second client as the test client and closes the instance it creates. During that probe only, the lobby asks this client to join CT. The server log must show the human and Reflex on CT and YaPB on T. The probe opens the actual H menu through the registered command, then calls its selection handler for the opposite-team item. Physical key presses are outside this probe.

~~~powershell
.\tools\ReflexCore-CS16Lobby.ps1 -ProbeClient
.\tools\ReflexCore-CS16Lobby.ps1 -ProbeRound
.\tools\ReflexCore-CS16Lobby.ps1 -UiSmoke
~~~

ProbeRound starts Reflex as T against YaPB on CT with a one-minute round clock. It requires an actual server result after round start. The stationary lab and its scripted route are separate tools.


## Current evidence and next milestone

The second client reached the loopback server while the existing client stayed open. The dedicated server logged a human on CT, Reflex on CT, and YaPB on T. Studio and the lobby passed their Windows UI smoke tests.

Two one-minute autonomous rounds ended with `Target_Saved` for CT. In the round with visit history, Reflex traveled more than 160 units and registered 97 patrol cell transitions. A cell can be counted more than once. The server recorded zero visible-enemy ticks, clip decrements, damage events and kills for Reflex. This establishes that the round ran and the actor moved, with first contact as the current blocker.

Keep this lobby and YaPB opponent as the acceptance entry point. Next, connect a local Dust II navigation graph to the Reflex actor, route from the actual spawn, and replan on stalled movement. Compare contact rate and time to first contact against this patrol on the same recorded starts. Log the first location with verified line of sight, then measure discharges, damage and survival in later trials. Keep the visual replay benchmark separate and add manually labeled active-play frames before estimating detector recall.
