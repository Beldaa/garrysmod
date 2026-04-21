#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <utility>
#include <vector>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

namespace
{
	struct JobRequest
	{
		std::uint64_t id = 0;
		std::string type;
		std::string payload;
		std::size_t chunk_size = 0;
	};

	struct JobResult
	{
		std::uint64_t id = 0;
		bool ok = false;
		std::string result;
		std::string error;
		std::vector<std::string> chunks;
	};

	std::vector<std::thread> g_workers;
	std::queue<JobRequest> g_pending_jobs;
	std::queue<JobResult> g_completed_jobs;
	std::mutex g_pending_mutex;
	std::mutex g_completed_mutex;
	std::condition_variable g_pending_cv;
	std::atomic<std::uint64_t> g_next_job_id { 1 };
	std::atomic<bool> g_shutdown { false };
	std::atomic<bool> g_initialized { false };

	// Maximum number of jobs allowed in the pending queue.
	// Protects against unbounded memory growth from runaway submit loops.
	static constexpr std::size_t MAX_PENDING_JOBS = 4096;

	std::size_t WorkerCount()
	{
		const auto hardware_threads = std::thread::hardware_concurrency();
		if ( hardware_threads <= 1 )
			return 1;

		const auto worker_count = static_cast<std::size_t>( hardware_threads - 1 );
		return worker_count == 0 ? 1 : worker_count;
	}

	JobResult ProcessJob( JobRequest job )
	{
		JobResult output;
		output.id = job.id;

		if ( job.type == "chunk_string" )
		{
			if ( job.chunk_size == 0 || job.chunk_size > 65535 )
			{
				output.error = "chunk_size must be between 1 and 65535";
				return output;
			}

			output.ok = true;
			output.chunks.reserve( ( job.payload.size() / job.chunk_size ) + 1 );

			for ( std::size_t offset = 0; offset < job.payload.size(); offset += job.chunk_size )
			{
				const auto bytes = std::min( job.chunk_size, job.payload.size() - offset );
				output.chunks.emplace_back( job.payload.substr( offset, bytes ) );
			}

			return output;
		}

		output.error = "unsupported job type: " + job.type;
		return output;
	}

	void WorkerMain()
	{
		for ( ;; )
		{
			JobRequest work;

			{
				std::unique_lock<std::mutex> lock( g_pending_mutex );
				g_pending_cv.wait( lock, []() { return g_shutdown.load() || !g_pending_jobs.empty(); } );

				if ( g_shutdown.load() && g_pending_jobs.empty() )
					return;

				work = std::move( g_pending_jobs.front() );
				g_pending_jobs.pop();
			}

			const std::uint64_t work_id = work.id;
			JobResult result;
			try
			{
				result = ProcessJob( std::move( work ) );
			}
			catch ( const std::exception &e )
			{
				result.id = work_id;
				result.ok = false;
				result.error = std::string( "C++ exception: " ) + e.what();
			}
			catch ( ... )
			{
				result.id = work_id;
				result.ok = false;
				result.error = "unknown C++ exception";
			}

			{
				std::lock_guard<std::mutex> lock( g_completed_mutex );
				g_completed_jobs.push( std::move( result ) );
			}
		}
	}

	void EnsureInitialized()
	{
		if ( g_initialized.load() )
			return;

		const auto workers = WorkerCount();
		g_workers.reserve( workers );
		for ( std::size_t i = 0; i < workers; ++i )
		{
			g_workers.emplace_back( &WorkerMain );
		}

		g_initialized.store( true );
	}

	void ShutdownPool()
	{
		if ( !g_initialized.load() )
			return;

		g_shutdown.store( true );
		g_pending_cv.notify_all();

		for ( auto &worker : g_workers )
		{
			if ( worker.joinable() )
				worker.join();
		}

		g_workers.clear();

		{
			std::lock_guard<std::mutex> lock( g_pending_mutex );
			std::queue<JobRequest> empty;
			std::swap( g_pending_jobs, empty );
		}

		{
			std::lock_guard<std::mutex> lock( g_completed_mutex );
			std::queue<JobResult> empty;
			std::swap( g_completed_jobs, empty );
		}

		g_initialized.store( false );
	}

	int LSubmit( lua_State *L )
	{
		EnsureInitialized();

		if ( g_shutdown.load() )
		{
			lua_pushnil( L );
			lua_pushstring( L, "job module is shutting down" );
			return 2;
		}

		const char *job_type = luaL_checkstring( L, 1 );
		std::size_t payload_length = 0;
		const char *payload = luaL_checklstring( L, 2, &payload_length );
		const lua_Integer max_payload_bytes = luaL_optinteger( L, 3, 0 );
		const lua_Integer chunk_size = luaL_optinteger( L, 4, 0 );

		if ( max_payload_bytes > 0 && payload_length > static_cast<std::size_t>( max_payload_bytes ) )
		{
			lua_pushnil( L );
			lua_pushstring( L, "payload is larger than max_payload_bytes" );
			return 2;
		}

		JobRequest request;
		request.type = job_type;
		request.payload.assign( payload, payload_length );
		request.chunk_size = chunk_size > 0 ? static_cast<std::size_t>( chunk_size ) : 0;

		{
			std::lock_guard<std::mutex> lock( g_pending_mutex );

			if ( g_pending_jobs.size() >= MAX_PENDING_JOBS )
			{
				lua_pushnil( L );
				lua_pushstring( L, "pending job queue is full" );
				return 2;
			}

			const std::uint64_t job_id = g_next_job_id.fetch_add( 1 );
			request.id = job_id;
			g_pending_jobs.push( std::move( request ) );

			// Unlock before notify, push id after
			lua_pushnumber( L, static_cast<lua_Number>( job_id ) );
		}
		g_pending_cv.notify_one();

		return 1;
	}

	int LPoll( lua_State *L )
	{
		const lua_Integer max_results = luaL_optinteger( L, 1, 8 );
		const auto result_budget = max_results > 0 ? static_cast<std::size_t>( max_results ) : static_cast<std::size_t>( 0 );

		// Batch drain: acquire the lock once and move up to budget items out
		std::vector<JobResult> batch;
		{
			std::lock_guard<std::mutex> lock( g_completed_mutex );
			batch.reserve( std::min( result_budget, g_completed_jobs.size() ) );
			while ( batch.size() < result_budget && !g_completed_jobs.empty() )
			{
				batch.push_back( std::move( g_completed_jobs.front() ) );
				g_completed_jobs.pop();
			}
		}

		lua_newtable( L );

		for ( std::size_t i = 0; i < batch.size(); ++i )
		{
			const JobResult &result = batch[ i ];

			lua_newtable( L );

			lua_pushnumber( L, static_cast<lua_Number>( result.id ) );
			lua_setfield( L, -2, "id" );

			lua_pushboolean( L, result.ok ? 1 : 0 );
			lua_setfield( L, -2, "ok" );

			if ( !result.result.empty() )
			{
				lua_pushlstring( L, result.result.data(), result.result.size() );
				lua_setfield( L, -2, "result" );
			}

			if ( !result.error.empty() )
			{
				lua_pushlstring( L, result.error.data(), result.error.size() );
				lua_setfield( L, -2, "error" );
			}

			if ( !result.chunks.empty() )
			{
				lua_newtable( L );
				for ( std::size_t chunk_index = 0; chunk_index < result.chunks.size(); ++chunk_index )
				{
					const std::string &chunk = result.chunks[ chunk_index ];
					lua_pushlstring( L, chunk.data(), chunk.size() );
					lua_rawseti( L, -2, static_cast<lua_Integer>( chunk_index + 1 ) );
				}
				lua_setfield( L, -2, "chunks" );
			}

			lua_rawseti( L, -2, static_cast<lua_Integer>( i + 1 ) );
		}

		return 1;
	}

	int LShutdown( lua_State *L )
	{
		ShutdownPool();
		lua_pushboolean( L, 1 );
		return 1;
	}

	int LIsAvailable( lua_State *L )
	{
		lua_pushboolean( L, 1 );
		return 1;
	}

	void CreateModuleTable( lua_State *L )
	{
		lua_newtable( L );

		lua_pushcfunction( L, &LSubmit );
		lua_setfield( L, -2, "Submit" );

		lua_pushcfunction( L, &LPoll );
		lua_setfield( L, -2, "Poll" );

		lua_pushcfunction( L, &LShutdown );
		lua_setfield( L, -2, "Shutdown" );

		lua_pushcfunction( L, &LIsAvailable );
		lua_setfield( L, -2, "IsAvailable" );
	}
}

extern "C" int luaopen_gmod_jobs( lua_State *L )
{
	g_shutdown.store( false );
	EnsureInitialized();
	CreateModuleTable( L );
	return 1;
}

extern "C" int luaopen_jobs( lua_State *L )
{
	return luaopen_gmod_jobs( L );
}
