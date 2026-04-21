cmake_minimum_required(VERSION 3.16)

project(gmod_jobs LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Lua REQUIRED)

add_library(gmod_jobs MODULE
	src/gmod_jobs.cpp
)

target_include_directories(gmod_jobs PRIVATE ${LUA_INCLUDE_DIR})
target_link_libraries(gmod_jobs PRIVATE ${LUA_LIBRARIES})

if(WIN32)
	set_target_properties(gmod_jobs PROPERTIES PREFIX "" SUFFIX ".dll" OUTPUT_NAME "gmsv_jobs_win64")
elseif(APPLE)
	set_target_properties(gmod_jobs PROPERTIES PREFIX "" SUFFIX ".dylib" OUTPUT_NAME "gmsv_jobs_osx64")
else()
	set_target_properties(gmod_jobs PROPERTIES PREFIX "" SUFFIX ".dll" OUTPUT_NAME "gmsv_jobs_linux64")
endif()

