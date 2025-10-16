cmake_minimum_required(VERSION 3.10)
project(JogoAdivinheMoeda C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_executable(server server.c)

if (CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(server PRIVATE -Wall -Wextra -Wpedantic)
endif()

find_package(Threads REQUIRED)
target_link_libraries(server PRIVATE Threads::Threads)
