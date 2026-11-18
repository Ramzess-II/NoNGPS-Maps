project(nogps_replay)

set(SRC
  replay.cpp
  replay.hpp
)

omim_add_library(${PROJECT_NAME} ${SRC})

target_link_libraries(${PROJECT_NAME} PUBLIC map)
