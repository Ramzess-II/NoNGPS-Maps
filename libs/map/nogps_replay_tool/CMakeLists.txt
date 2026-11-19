project(nogps_replay_tool)

set(SRC
  main.cpp
  fixed_locale.hpp
)
if (PLATFORM_MAC)
  list(APPEND SRC fixed_locale.mm)
else()
  list(APPEND SRC fixed_locale_std.cpp)
endif()

omim_add_executable(${PROJECT_NAME} ${SRC})

target_link_libraries(${PROJECT_NAME}
  PRIVATE
    nogps_replay
    gflags::gflags
)
