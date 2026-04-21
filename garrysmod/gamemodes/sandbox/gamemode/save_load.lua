
if ( SERVER ) then

	local jobs = jobs
	local gmod_save_async_chunks = CreateConVar( "sandbox_save_async_chunks", "0", { FCVAR_ARCHIVE, FCVAR_DONTRECORD }, "Prepare save chunks in a background jobs module before sending." )
	local gmod_save_async_max_payload = CreateConVar( "sandbox_save_async_max_payload", "33554432", { FCVAR_ARCHIVE, FCVAR_DONTRECORD }, "Maximum payload size in bytes accepted by background save chunk jobs (default: 32 MB)." )

	local function SendSaveChunks( ply, chunks, ShowSave )

		local parts = #chunks
		for i = 1, parts do

			local chunk = chunks[ i ]
			if ( !isstring( chunk ) ) then return false end

			local size = string.len( chunk )
			if ( size <= 0 || size > 65535 ) then return false end

			net.Start( "GModSave" )
				net.WriteBool( i == parts )
				net.WriteBool( ShowSave )

				net.WriteUInt( size, 16 )
				net.WriteData( chunk, size )
			net.Send( ply )

		end

		return true

	end

	local function SendCompressedSave( ply, compressed_save, ShowSave )

		local len = string.len( compressed_save )
		local send_size = 60000
		local parts = math.ceil( len / send_size )

		local start = 0
		for i = 1, parts do
			local endbyte = math.min( start + send_size, len )
			local size = endbyte - start

			net.Start( "GModSave" )
				net.WriteBool( i == parts )
				net.WriteBool( ShowSave )

				net.WriteUInt( size, 16 )
				net.WriteData( compressed_save:sub( start + 1, endbyte + 1 ), size )
			net.Send( ply )

			start = endbyte
		end

	end

	--
	-- Pool the shared network string
	--
	util.AddNetworkString( "GModSave" )

	--
	-- Console command to trigger the save serverside (and send the save to the client)
	--
	concommand.Add( "gm_save", function( ply, cmd, args )

		if ( !IsValid( ply ) ) then return end

		-- gmsave.SaveMap is very expensive for big maps/lots of entities. Do not allow random ppl to save the map in multiplayer!
		-- TODO: Actually do proper hooks for this
		if ( !game.SinglePlayer() && !ply:IsAdmin() ) then return end

		if ( ply.m_NextSave && ply.m_NextSave > CurTime() && !game.SinglePlayer() ) then
			ServerLog( tostring( ply ) ..  " tried to save too quickly!\n" )
			return
		end

		ply.m_NextSave = CurTime() + 10

		ServerLog( tostring( ply ) .. " requested a save.\n" )

		local save = gmsave.SaveMap( ply )
		if ( !save ) then return end

		local compressed_save = util.Compress( save )
		if ( !compressed_save ) then compressed_save = save end

		local send_size = 60000

		local ShowSave = false
		if ( args[ 1 ] == "spawnmenu" ) then ShowSave = true end

		if ( gmod_save_async_chunks:GetBool() && jobs && jobs.IsAvailable && jobs.IsAvailable() ) then

			local job_id, job_error = jobs.submit( "chunk_string", compressed_save, function( ok, _, _, result )

				if ( !IsValid( ply ) ) then return end

				if ( !ok || !istable( result ) || !istable( result.chunks ) ) then
					SendCompressedSave( ply, compressed_save, ShowSave )
					return
				end

				local sent_ok = SendSaveChunks( ply, result.chunks, ShowSave )
				if ( !sent_ok ) then
					SendCompressedSave( ply, compressed_save, ShowSave )
				end

			end, {
				chunkSize = send_size,
				maxPayloadBytes = gmod_save_async_max_payload:GetInt()
			} )

			if ( job_id ) then return end
			if ( job_error && job_error.message ) then
				MsgN( "gm_save async chunking failed to start: " .. tostring( job_error.message ) )
			end

		end

		SendCompressedSave( ply, compressed_save, ShowSave )

	end, nil, "", { FCVAR_DONTRECORD } )

	local function LoadGModSave( savedata )

		-- If we loaded the save from main menu and the player entity is not ready yet
		if ( game.SinglePlayer() && !IsValid( Entity( 1 ) ) ) then

			timer.Create( "LoadGModSave_WaitForPlayer", 0.1, 0, function()
				if ( !IsValid( Entity( 1 ) ) ) then return end

				timer.Remove( "LoadGModSave_WaitForPlayer" )
				LoadGModSave( savedata )
			end )

			return

		end

		local ply = nil
		if ( IsValid( Entity( 1 ) ) && ( game.SinglePlayer() || Entity( 1 ):IsListenServerHost() ) ) then ply = Entity( 1 ) end
		if ( !IsValid( ply ) && #player.GetHumans() == 1 ) then ply = player.GetHumans()[ 1 ] end
		if ( game.IsDedicated() ) then ply = nil end -- For dedicated servers, we don't want it to latch to some random player

		gmsave.LoadMap( savedata, ply )

	end

	hook.Add( "LoadGModSave", "LoadGModSave", function( savedata, mapname, maptime )

		savedata = util.Decompress( savedata )

		if ( !isstring( savedata ) ) then
			MsgN( "gm_load: Couldn't load save!" )
			return
		end

		LoadGModSave( savedata )

	end )

else

	local buffer = ""
	net.Receive( "GModSave", function()
		local done = net.ReadBool()
		local showsave = net.ReadBool()

		local length = net.ReadUInt( 16 )
		local data = net.ReadData( length )

		buffer = buffer .. data

		if ( !done ) then return end

		MsgN( "Received save. Size: " .. buffer:len() )

		local uncompressed = util.Decompress( buffer )
		if ( !uncompressed ) then
			MsgN( "Received save - but couldn't decompress!?" )
			buffer = ""
			return
		end

		engine.WriteSave( buffer, game.GetMap() .. " " .. util.DateStamp() )
		buffer = ""

		if ( showsave ) then
			hook.Run( "PostGameSaved" )
		end

	end )

end
