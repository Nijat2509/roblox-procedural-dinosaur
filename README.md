# Procedural Dinosaur NPC — Roblox Studio

A T-Rex NPC built in Roblox Studio that walks a generated route around the map, 
blinks, roars, and reacts to player distance — entirely through procedural 
animation (no .fbx animation files, every pose is computed in code).

## Features
- **Procedural locomotion**: leg, tail, neck and jaw motion computed each frame 
  from a single time value — no pre-baked animations.
- **Spline-based pathfinding**: generates a smooth, collision-free patrol route 
  using Catmull-Rom splines through randomized waypoints.
- **State machine**: Wandering / Resting / Yawning / Sniffing / Roaring, driven 
  by a deterministic clock so it's synced for every player.
- **Player-triggered events**: a UI button (and 'R' key) lets players make the 
  dinosaur roar on demand, with a server-enforced cooldown.
- **Reactive AI**: the server makes the dinosaur roar automatically when a 
  player gets close, independent of the player-triggered roar.
- **Camera feedback**: nearby roars shake the player's camera.

## Tools & Skills
Roblox Studio · Luau (Lua) · Procedural animation · Spline math (Catmull-Rom) · 
Client-server architecture (RemoteEvents) · State machines · 3D geometry/CFrame math

## How to Open
1. Install [Roblox Studio](https://create.roblox.com/).
2. Open a new/empty place.
3. Copy `DinoAnimator.luau` into `ReplicatedStorage` as a **ModuleScript**.
4. Copy `DinoBrain.luau` into `ServerScriptService` as a **Script**.
5. Copy `DinoClient.luau` into `StarterPlayer > StarterPlayerScripts` as a 
   **LocalScript**.
6. Press Play.

## What I Learned
- How to drive 3D character motion with pure math instead of animation 
  clips — sine waves and eased interpolation for gait, breathing and blinking.
- Generating a usable procedural path (Catmull-Rom spline) from random points 
  while rejecting self-intersecting or too-tight routes.
- Keeping client and server state in sync using a single shared "clock" value 
  instead of broadcasting every frame.
- Structuring game logic as client (visuals/input), server (authority/cooldowns) 
  and shared module (pure animation math) — a pattern that carries over to any 
  multiplayer engine.

## Folder Structure
