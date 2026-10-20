# Game version compatibility

A pass over the changelogs for every BeamNG.drive and BeamMP release,
recording what each one meant for this mod.

[← Back to the README](../README.md)

Tracked against **BeamNG.drive v0.40** and **BeamMP v4.23.1**. The mod talks
to a lot of game surfaces - vehicles, cameras, the input action filter, the
debug drawer, the UI app host, BeamMP's event bridge - so every release gets a
pass over the changelogs.

### BeamNG.drive v0.40

Reviewed against the installed game (build 287428), not only the release notes:
every engine function, hook, input action, vehicle-side command and C++ binding
the mod calls was looked up in the shipped Lua and binaries. One real break was
found and fixed. One admin task: **re-capture the Garage List**.

| v0.40 change | Effect on the mod | Status |
|---|---|---|
| *"When holding the recovery button, the vehicle will initially be reset in-place"* | A held Recover now resets the car twice: in place 0.5 s into the hold, then where the rewind ends on release. Both arrive as `onVehicleResetted`, so **one press spent two resets** of the allowance and reported two to the server. Worse, when the first of the two spent the last reset, the reset keys were switched off with Recover still held, and the release could be refused as an over-allowance reset | **Fixed.** The game brackets a press with `onStartRecovering` / `onStopRecovering`; resets inside one press count once, and the reset keys are only switched off after the release. At most one reset per press is absorbed, and a press that never reports its end expires after 30 s, so a lost hook cannot hand out free resets |
| Physical occupants: every seat gets a `seat_occupant_*` slot holding `occupant_generic` | New slots in every car's parts tree, so **every Garage List signature captured on v0.39 stops matching**. Drivers are told the entry was captured on an older build | **Re-capture the Garage List.** The 89 kg occupant is applied as runtime cargo, not as a part, so a signature captured on v0.40 stays stable |
| New ways out of the car: click your own seat, *Toggle unseated*, switch seats (new `enterSeat`, `toggle_unseated`, `switch_next_seat`, `switch_previous_seat` actions) | Could have let a forced spectator climb out | No change needed: every one of these asks `gameplay_walk.canToggleWalkingMode`, which refuses while `toggleWalkingMode` is filtered, and the spectator lock already filters it |
| Switching vehicle now seats the player in the new car, and a car's inputs are cleared on a seat change or reset | Spectating (tabbing to a rival, the broadcast board) seats you in their car on your client. The seat system only swaps the camera when an occupant camera is already active, and the broadcast camera sets `orbit` | No change needed. The clear keeps the parking brake, and a derby stand-down and a grid hold are frozen anyway |
| Local split-screen multiplayer, per-player input devices | The mod drives player 0: `getPlayerVehicle(0)`, `be:enterVehicle(0, ...)`, `core_camera.setByName(0, ...)`, all unchanged | No change needed |
| UI: the game no longer sends `ChangeState`; `ui_router.navigate` is the way to change screens; `v-bng-panel` removed; `createVueApp` deprecated | The three HUD apps are AngularJS directives. v0.40 still ships Angular 1.5.8 and 43 stock Angular apps, still bridges `guihooks.trigger` to them and still broadcasts `app:resized` with `{ width, height }`. The apps listen only to their own events. The stuck-UI repair after joining uses `ui_router.navigate('play')` and the `routeChangeCancelled` / `onAfterRouteChange` hooks, all still present | No change needed |
| *"Removed some outdated input actions"*, Back and Cancel merged | All 41 action names the mod filters (resets, teleports, driving, node grabber, fun stuff) still exist | No change needed |
| Lua API: `setWindowTitle` removed, `wheels.lua` split, pursuit modules | The mod uses none of them | No change needed |
| Cameras: `dash` renamed `driver`; free cam when the last vehicle is removed | The mod only ever sets `orbit`, and the spectator flow keeps the car | No change needed |
| Node grabber: fixed nodes cleared on teleport | The grid hold is a controller freeze (`core_vehicleBridge` `setFreeze`), not pinned nodes | No change needed |
| Engine bindings | `obj:setGhostEnabled` (still used by the game's own `main.lua`), `setMeshAlpha`, `reloadCollision`, `castRayStatic`, `getSpawnWorldOOBB`, the `debugDrawer` shapes, ImGui `Image` and `ImTextureHandler`, `recovery.recoverInPlace`, `input.event`, `setEngineIgnition`: all present with the same signatures | No change needed |
| *"Custom config files will get the same name as the config again"* | The Garage List reads the name off the config, with the filename as the fallback | No change needed |
| *"Added error logs when gelua commands enqueued by the user interface cannot be processed"* | A failing `bngApi.engineLua` call from the apps now shows in `beamng.log` instead of vanishing | No change needed; one more place to look when a button does nothing |

### BeamMP v4.22.1 to v4.23.1

v4.23.0 and v4.23.1 are the v0.40 builds, and **BeamMP refuses to load on any
other game version** (`compatibleVersion = 40` in its modScript): every driver
has to be on BeamNG v0.40 with BeamMP v4.23.x. There is no new BeamMP-Server
release (still v3.9.4), so the server plugin is untouched.

| Change | Effect on the mod | Status |
|---|---|---|
| `TriggerServerEvent` builds its packet with a string buffer | The wire format for a string payload is the same `E:name:data`. Only a `nil` payload differs, and the mod always sends a string (`''` or JSON) | No change needed |
| Nametags are cached per vehicle (`updateNameTagCache`) | `setPlayerNickSuffix` refreshes the cache for every car the player owns, and a car spawned later is built with the suffix | No change needed |
| Key listeners moved to `MPKeybindsGE`; the vehicle side no longer reads `input.keys` | The mod uses neither | No change needed |
| Unicycle clean-up reads v0.40's per-player `unicycleIds` | The radar skips unicycles by jbeam name, which v0.40 keeps (`unicycle`) | No change needed |
| Session hooks, ownership and the event bridge | `onBeamMPServerLeave` and `onBeamMPPostJoin` still fire; `getVehicles`, `isOwn`, `getPlayerServerID`, `setPlayerNickSuffix` and `AddEventHandler` are unchanged, as are the `ownerID` and `gameVehicleID` fields | No change needed |
| `MPVehicleGE.onServerVehicleSpawned` / `onServerVehicleEdited` | Still not exported, as in v4.22.0, so the spawn-event parts catch stays inert and the Garage List reads parts from the vehicle's own config | No change needed |
| Translations, server browser, chat, login, player list UI | Internal to BeamMP | No change needed |

### BeamMP v4.22.0

| v4.22.0 change | Effect on the mod | Status |
|---|---|---|
| BeamMP renamed its extension hooks with an `onBeamMP*` prefix - `onServerLeave` → `onBeamMPServerLeave`, `runPostJoin` → `onBeamMPPostJoin`, `onLauncherConnected` → `onBeamMPLauncherConnected` | The mod referenced none of them, which was the bug: it never learned that a session had started or ended. Every regulation the server owns is *applied* on the client (reset keys switched off at the input filter, the car frozen on its grid slot, a finished or eliminated driver held in freecam) and lifted by a broadcast - so leaving a server mid-race dropped you into singleplayer with a dead reset key, a frozen car and a camera reasserting freecam every second | Fixed: the mod now handles the session-leave hook and purges everything it was enforcing. Both the new and the old hook name are registered, so it works on v4.22.0 and on v4.21.1 and earlier |
| Same rename on the join side | The extension can be mounted and loaded before BeamMP's network extension is ready, in which case it bound no handlers and sat deaf for the whole session | Fixed: the join hook (both names) re-binds the handlers and asks the server for the live state a beat later, so joining mid-session works without opening the app |
| Handlers are keyed by a *source* and a re-registration from the same source replaces rather than stacks | Only affects how the bridge binds | The source is now passed explicitly instead of being inferred from the call site, so re-binding is idempotent. Older builds ignore the extra argument |
| TCP connection handling and retry logic; batch-based mod loading; UI refresh; avatar null-pointer fix; translation updates | Internal to BeamMP | No change needed |
| `ADM` → `ADMIN` role rename; `ui.multiplayer.*` → `ui.beammp.*` translation keys | The mod uses neither BeamMP roles nor its translation keys | No change needed |

**Ghost qualifying - this entry was wrong, and is now fixed.** It used to read
that BeamMP exposes no vehicle-collision toggle, so ghosted rivals were faded but
stayed solid. The first half was true and the conclusion was not: the mod was
looking in the wrong place. It probed `MPVehicleGE` for `setGhostMode`,
`setGhosts` and `enableGhostMode`, none of which any BeamMP build has ever had,
and took the failure as proof that no toggle existed anywhere.

The toggle is **BeamNG's**, not BeamMP's: `obj:setGhostEnabled(bool)`, a
vehicle-side call reached from GE through `queueLuaCommand` - the same bridge the
grid freeze already used. It is per vehicle, and it leaves world and terrain
collision alone. The engine drives it itself for instability recovery
(`lua/ge/main.lua`), and BeamNG's own multiplayer has `ghostOnReset` /
`ghostOnTp` vehicle globals that are this exact feature.

So ghost qualifying now actually removes collisions rather than only looking as
though it does, and the same mechanism carries [reset
ghosting](REFERENCE.md#reset-ghosting). Because it is per vehicle, every client
must ghost the *same* car, which is why ghost state is broadcast keyed by
**player id** - a vehicle id is a local scene-object id and means something
different on every client.

The lesson worth keeping: a capability probe that finds nothing has only proved
that *those names* are absent. It never established that the capability was
missing, and for two releases the docs recorded the stronger claim.

### BeamNG.drive v0.39.3 (hotfix)

The first hotfix that lands squarely on a surface this mod binds to. It is a
large, **UI-heavy** release: the HUD app host, the layout editor and controller
navigation all moved. Nothing here is a confirmed break, and **no code change
has been made** - but two items below can only be settled in-game, and both
fail *silently* rather than with an error, so they are worth a deliberate look
on the first session after updating.

| v0.39.3 change | Effect on the mod | Status |
|---|---|---|
| *"Implemented a new scalable metrics system for HUD apps and improved layout editor UI"* | The resize grip (drag the bottom-right corner) measures with `getBoundingClientRect()` and raw `clientX/clientY` deltas - **screen** pixels - and writes the result back as an inline `width: Npx` - **layout** pixels. Those two are the same number only while the app host is drawn unscaled. If the new metrics system scales the host with a CSS transform, the panel grows faster or slower than the cursor at any scale ≠ 1, and a size saved to `localStorage` means a different on-screen size than it did when it was stored | **Verify in-game.** Drag the grip and check the corner tracks the pointer. If it drifts, the fix is to divide the delta by the host's scale factor rather than to store visual px. *Reset size* (beside the opacity slider) clears a stored size that no longer fits |
| The same release emits the HUD app window's resize broadcast the mod listens for - `$scope.$on('app:resized')`, used to pull a stored size back inside a window that shrank | If the event name or its `{ width, height }` payload changed with the layout editor rework, the clamp stops running. It fails quietly: nothing errors, the grip just ends up stranded outside the clip edge and the drag reads as doing nothing | **Verify in-game.** Shrink the Phoenix Race Manager (PRM) window in *Pause → System → HUD Apps* and confirm the panel follows it in |
| *"Stripped deprecated or unknown properties from HUD app positions"* | `app.json` sets only `top`, `left`, `width`, `height` - the four standard keys, so there is nothing here to strip | No change needed. It does mean a **user's saved position may be reset** to the app.json default (top-left, 560×560); just drag it back |
| *"In Options > User Interface, enabled manual apply for UI resolution, alignment, scale, and safe zones"* | Makes a UI scale change a discrete event rather than a live drag - which is exactly the moment a stored pixel size would visibly jump, per the first row | Admin note: after changing UI scale, use **Reset size** on the leaderboard/HUD panel |
| *"Added a **Spawn Vehicle** button to the Manage Vehicles card in the pause menu"* | A brand-new path for a driver serving a spectator penalty (finished, or eliminated from a derby) to put themselves back on track - the same class of hole as the v0.39 repair/reset buttons | Already covered - `onVehicleSpawned` deletes an own-vehicle spawn while the spectator lock is held and re-asserts freecam |
| *"HUD apps no longer take over the controller thanks to new UINav capabilities"*; *"UINav no longer allows stuck navigation repeat"* | The app is an AngularJS directive that never opted into UINav, so it does not participate in controller navigation and cannot capture the pad | No change needed, and a net win: a driver's controller now stays with the car while the app is open. The admin panel remains **mouse and keyboard only**, as it already was in practice |
| *"Moved the NPC AI setting to the pause menu Vehicles card"*, AI mode select, *"Added AI actions back to the radial menu"* | Makes it easier for a driver to hand their **own** car to the AI mid-session. The mod polices resets, vehicle configuration and track limits, but has never policed AI driving | Not a regression - the gap predates this release. Recorded as a known hole, not something 0.39.3 broke |
| Lua API: *"Fixed a dealer being not quite my tempo"* | Career-mode vehicle dealer | No change needed. The Lua API section is otherwise empty this release - nothing the GE extension calls moved |
| Modding: *"Fixed a freeze in level/vehicle selector when a zipped mod with a non-UTF-8 encoded filename is installed"* | The zip BeamNG actually mounts is plain ASCII (`RaceManager.zip`) | No change needed |
| Safe Mode on DX11 for ≤4 GB VRAM; D3D12 Intel VRAM advice; terrain cooking; the vehicle, aero and Replay fixes | The mod draws only immediate-mode `debugDrawer` shapes, which are renderer-agnostic, and uses nothing from replay | No change needed |

**One thing to re-check, as after every game update:** the vehicle fixes in this
hotfix touch the Cherrier Ardente, Hirochi SBR4 and Gavril D-Series among
others. Any of those held in the **Garage List** should be **re-captured** - a
jbeam or part change alters the configuration signature without the car
changing, and the driver gets rejected in a setup that is plainly approved.

### BeamNG.drive v0.39.2 (hotfix)

Reviewed, **nothing to change in the code**. The hotfix covers a Mod Manager
update fix, an explicit D3D12 launcher option with better GPU detection, the
VRAM detection threshold dropping 6 GB → 5.5 GB, a Wl40 front-axle fix, and
premature Steam achievement unlocks. None of it touches a surface this mod
binds to: no UI/HUD app hosting, no GE Lua or `guihooks` change, nothing on the
input action filter, `onVehicleResetted`/`objectTeleported`, the debug drawer,
or the cameras.

Two things for admins rather than the code, though:

| v0.39.2 change | Why it matters here | What to do |
|---|---|---|
| *"Fixed update process for users with mods installed"* - the automatic mod-disabling system on major updates **failed to trigger** for some users, and now does | Anyone in that group can come back from the update with the client mod switched off. It is the same end state as the "app doesn't show up" case in the [README](../README.md#troubleshooting), reached by a different route | Check Phoenix Race Manager (PRM) is still listed under **HUD Apps** and enabled in the Mods menu. Whether BeamMP-pushed client mods are caught by this as well is not stated in the changelog - worth a look on the first session after updating |
| Wl40 front-axle fix on the showloader configuration | A jbeam change to a shipped vehicle. The Garage List matches an exact configuration **signature** built from part names, so a part that moved or was renamed invalidates a stored entry and the driver is rejected in a car that is plainly approved | **Re-capture any whitelisted Wl40.** Entries record the game build they were captured on, so a rejection caused by this says so rather than reading as an ordinary "setup not allowed" |

### BeamNG.drive v0.39.1 (hotfix)

Reviewed, nothing to change. The hotfix covers jbeam parts with a missing
`slotType`, D3D12 texture/VRAM/emissive fixes with a D3D11 fallback, a fix for
large mod lists failing to load, restored vehicle spawning under memory
pressure, and a PlayStation controller crash. None of it touches a surface this
mod binds to - it draws only immediate-mode `debugDrawer` shapes and ships no
jbeam.

### BeamNG.drive v0.39

| v0.39 change | Effect on the mod | Status |
|---|---|---|
| *"Renamed UI Apps to HUD Apps"*, UI ported to Vue | The app is an AngularJS directive under `ui/modules/apps/`. Legacy Angular screens are still hosted, and the app uses plain HTML plus core `ng-*` directives only (no Angular Material, no `bng-*` components), so it keeps working - it is now listed under **HUD Apps**. Its `types` categories (`ui.apps.categories.racing`, `.info`) are both still live keys | No change needed |
| *"Changed naming of the custom config files"* - a saved setup's name lives in the vehicle's `info.json` and no longer matches the `.pc` filename | The Garage List labeled cars by the `.pc` filename stem, which now shows a sanitised derivative instead of the setup's real name | Fixed: the name is read off the config itself, with the filename kept as the fallback |
| *"Renamed a bunch of parts on some vehicles"* | The Garage List matches an exact configuration **signature** built from part names. Renamed parts change the signature without the car changing, so lists captured before v0.39 stop matching and drivers are rejected in a car that is plainly approved. Only a re-capture can fix it | Fixed as far as it can be: entries now record the game build they were captured on, and a rejection caused by that skew says so instead of reading as an ordinary "setup not allowed" |
| New Pause-menu **Vehicle Management** flow with its own repair/reset buttons | A reset the input action filter cannot see, so the "reset keys go dead" layer no longer covers every path | Already covered - the `onVehicleResetted` restore catches it and was built for exactly this |
| *"Improved vehicle teleporting detector `objectTeleported()`"* (fewer false negatives on fast vehicles) | The mod teleports the car itself (blocked-reset restore, grid placement, checkpoint respawn) and has to recognize the resulting reset hook as its own echo. A later-arriving echo from a fast car is no longer where it was put | Fixed: the "is this our own teleport" tolerance now scales with the distance the car could actually have covered, instead of a flat 2 m |
| `be:*` accessors called out as a framerate/GC cost, plus a new startup warning for slow extensions | The player's vehicle is read several times per frame | Fixed: uses `getPlayerVehicle(0)` / `getAllVehicles()`, falling back to the old calls on builds without them. The position behind those reads is now sampled **once per frame** and shared, and the gate draw loop caches its geometry, labels and colors instead of rebuilding them every frame for every gate |
| *"`guihooks.trigger` … now communicates only with the main UI HTML"* | Every UI push goes to the main UI app | No change needed |
| Folder-based translations (`locales/translations/<lang>/*.json`) | The mod ships no translation keys of its own; its app name and description are literal strings, which stay supported | No change needed |

The one thing an admin has to do by hand after a BeamNG update: if the
**Garage List** is in use, re-capture it. A game update that renames vehicle
parts invalidates every stored signature, and the server will now tell
rejected drivers that is what happened.
