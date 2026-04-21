Garry's Mod
=========

This repo consists of all Lua, text, and config extensions for Garry's Mod. Binary sources are not public, but are derived from the [Source SDK](https://github.com/ValveSoftware/source-sdk-2013).

Next Update
---
Current game discussion as well as update progress can be found on [Discord](https://discord.gg/gmod).

You can test [changes for the next update](https://wiki.facepunch.com/gmod/Update_Preview_Changelog) on the [Garry's Mod Dev Branch](https://wiki.facepunch.com/gmod/Dev_Branch) through Steam.

Pull Requests
---
Pull requests are welcome. 

Please make sure your [line endings are correct](https://help.github.com/articles/dealing-with-line-endings/).

Also try to condense multiple commits down to easily see the changes made, either through [resetting the head](https://stackoverflow.com/questions/5189560/squash-my-last-x-commits-together-using-git/5201642#5201642) or [rebasing the branch](https://stackoverflow.com/questions/5189560/squash-my-last-x-commits-together-using-git/5189600#5189600).

Issues and Requests
---
To report bugs please visit the [Garry's Mod Issue tracker](https://github.com/Facepunch/garrysmod-issues/).

To request features please visit the [Garry's Mod Request tracker](https://github.com/Facepunch/garrysmod-requests/).

Translations
---
You can contribute to the game's translation on the following website:
https://crowdin.com/project/garrysmod

[![Crowdin](https://badges.crowdin.net/garrysmod/localized.svg)](https://crowdin.com/project/garrysmod)

Experimental jobs module scaffold
---
This repository now contains an initial scaffold for a native multithreaded jobs module intended for Garry's Mod binary module builds (`gmsv_jobs_*` and optionally `gmcl_jobs_*`).

### How it works
- Lua-facing API is exposed as `jobs` (see `garrysmod/lua/includes/modules/jobs.lua`).
- The Lua module attempts to load native module `gmod_jobs` and falls back safely when it is unavailable.
- Jobs are submitted asynchronously and completed results are pumped on the main thread from a `Think` hook with a per-tick callback budget (`sv_jobs_callback_budget` / `cl_jobs_callback_budget`).
- Current native scaffold includes a fixed-size thread pool and a sample `chunk_string` job type.

### Important limitations
- Do not call Source engine/Garry's Mod engine APIs off-thread.
- Lua callbacks are never invoked directly from worker threads; callbacks are delivered during main-thread pump.
- Payload size and chunk sizes are validated; failed jobs return structured error information to callbacks.
- Shutdown is handled via `jobs` module shutdown hook (`ShutDown` on server), which calls into native shutdown.

### Build/install scaffold (CMake)
- Scaffold files:
  - `native/jobs/CMakeLists.txt`
  - `native/jobs/src/gmod_jobs.cpp`
- This scaffold uses Lua C API and expects Lua/LuaJIT dev headers/libraries to be available.
- Example build:
  1. `cmake -S native/jobs -B native/jobs/build`
  2. `cmake --build native/jobs/build --config Release`
- Output module naming follows Garry's Mod conventions in CMake (`gmsv_jobs_win64.dll`, `gmsv_jobs_linux64.dll`, `gmsv_jobs_osx64.dylib`).
- Install the built binary into your server/client `garrysmod/lua/bin/` location and load through Lua-side `jobs` module.

### Example Lua usage
```lua
if ( jobs and jobs.IsAvailable and jobs.IsAvailable() ) then
	jobs.submit( "chunk_string", big_payload, function( ok, _, err, result )
		if ( !ok ) then
			print( "[jobs] failed:", err and err.message or "unknown error" )
			return
		end

		print( "[jobs] chunk count:", result and result.chunks and #result.chunks or 0 )
	end, {
		chunkSize = 60000,
		maxPayloadBytes = 32 * 1024 * 1024
	} )
end
```
