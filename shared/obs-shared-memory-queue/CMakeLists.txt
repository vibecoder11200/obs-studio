cmake_minimum_required(VERSION 3.28...3.30)

# Shared virtual-camera identifiers: the writer plugin and the DirectShow
# filter module (both architectures) must agree on the same section and file
# names, so they are configured once into a generated header.
if(NOT VIRTUALCAM_QUEUE_NAME)
  set(VIRTUALCAM_QUEUE_NAME "C920VideoQueue" CACHE STRING "Shared-memory section name used by the virtual camera video queue")
endif()
if(NOT VIRTUALCAM_CONFIG_FILE)
  set(VIRTUALCAM_CONFIG_FILE "c920-cam.txt" CACHE STRING "Config file used by the virtual camera to persist the last resolution")
endif()

if(NOT TARGET OBS::tiny-nv12-scale)
  add_subdirectory("${CMAKE_SOURCE_DIR}/shared/obs-tiny-nv12-scale" obs-tiny-nv12-scale)
endif()

add_library(obs-shared-memory-queue INTERFACE)
add_library(OBS::shared-memory-queue ALIAS obs-shared-memory-queue)

configure_file(virtualcam-names.h.in virtualcam-names.h)
target_sources(
  obs-shared-memory-queue
  INTERFACE
    shared-memory-queue.c
    shared-memory-queue.h
    "${CMAKE_CURRENT_BINARY_DIR}/virtualcam-names.h"
)
target_include_directories(obs-shared-memory-queue INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(obs-shared-memory-queue INTERFACE OBS::tiny-nv12-scale)
