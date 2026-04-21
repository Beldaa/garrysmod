local hook = hook
local pcall = pcall
local timer = timer
local math = math
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local isfunction = isfunction
local isnumber = isnumber
local isstring = isstring
local istable = istable

module( "jobs" )

local native = nil
local pending_callbacks = {}

local callback_budget = nil
if ( SERVER ) then
	callback_budget = CreateConVar( "sv_jobs_callback_budget", "8", { FCVAR_ARCHIVE, FCVAR_DONTRECORD }, "Maximum number of jobs callbacks to deliver each tick." )
else
	callback_budget = CreateClientConVar( "cl_jobs_callback_budget", "8", true, false, "Maximum number of jobs callbacks to deliver each tick." )
end

local function MakeError( code, message )
	return {
		code = code,
		message = message
	}
end

do
	local ok, loaded = pcall( require, "gmod_jobs" )
	if ( ok && istable( loaded ) ) then
		native = loaded
	elseif ( istable( gmod_jobs ) ) then
		native = gmod_jobs
	end
end

function IsAvailable()
	return istable( native ) && isfunction( native.Submit ) && isfunction( native.Poll )
end

function submit( job_type, payload, callback, options )

	if ( !isstring( job_type ) || job_type == "" ) then
		return nil, MakeError( "invalid_job_type", "job_type must be a non-empty string" )
	end

	if ( !isstring( payload ) ) then
		return nil, MakeError( "invalid_payload", "payload must be a string" )
	end

	if ( callback != nil && !isfunction( callback ) ) then
		return nil, MakeError( "invalid_callback", "callback must be a function" )
	end

	if ( !IsAvailable() ) then

		local err = MakeError( "native_unavailable", "Native gmod_jobs module is unavailable" )
		if ( isfunction( callback ) ) then
			timer.Simple( 0, function() callback( false, nil, err ) end )
		end

		return nil, err

	end

	options = options or {}
	local max_payload_bytes = tonumber( options.maxPayloadBytes ) or 0
	local chunk_size = tonumber( options.chunkSize ) or 0

	local job_id, submit_error = native.Submit( job_type, payload, max_payload_bytes, chunk_size )
	if ( !isnumber( job_id ) ) then

		local err = MakeError( "submit_failed", isstring( submit_error ) && submit_error || "Job submission failed" )
		if ( isfunction( callback ) ) then
			timer.Simple( 0, function() callback( false, nil, err ) end )
		end

		return nil, err

	end

	if ( isfunction( callback ) ) then
		pending_callbacks[ job_id ] = callback
	end

	return job_id

end

function pump( max_callbacks )

	if ( !IsAvailable() ) then return 0 end

	local budget = tonumber( max_callbacks ) or callback_budget:GetInt()
	budget = math.max( budget, 0 )
	if ( budget <= 0 ) then return 0 end

	local results = native.Poll( budget )
	if ( !istable( results ) ) then return 0 end

	local delivered = 0
	for _, result in ipairs( results ) do

		local callback = pending_callbacks[ result.id ]
		pending_callbacks[ result.id ] = nil

		if ( isfunction( callback ) ) then
			local ok = result.ok == true
			local err = nil
			if ( !ok ) then
				err = MakeError( "job_failed", isstring( result.error ) && result.error || "Background job failed" )
			end

			callback( ok, result.result, err, result )
			delivered = delivered + 1
		end

	end

	return delivered

end

function pending()
	local count = 0
	for _ in pairs( pending_callbacks ) do
		count = count + 1
	end
	return count
end

hook.Add( "Think", "jobs.Pump", function()
	pump()
end )

if ( SERVER ) then
	hook.Add( "ShutDown", "jobs.Shutdown", function()
		if ( !IsAvailable() || !isfunction( native.Shutdown ) ) then return end
		native.Shutdown()
	end )
end
