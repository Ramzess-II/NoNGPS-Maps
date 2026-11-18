project(nogps_replay_tool)

set(SRC
  main.cpp
)

omim_add_executable(${PROJECT_NAME} ${SRC})

target_link_libraries(${PROJECT_NAME}
  PRIVATE
    nogps_replay
    gflags::gflags
)
