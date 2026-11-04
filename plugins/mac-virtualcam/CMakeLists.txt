cmake_minimum_required(VERSION 3.28...3.30)

option(ENABLE_VIRTUALCAM "Build OBS Virtualcam" ON)

if(NOT ENABLE_VIRTUALCAM)
  target_disable_feature(mac-virtualcam "macOS Virtual Camera support")
  return()
endif()

target_enable_feature(mac-virtualcam "macOS Virtual Camera support")

# Neutral device identity for the virtual camera (defaults keep builds
# without presets stock; presets override via CMakePresets.json).
if(NOT VIRTUALCAM_MAC_DEVICE_NAME)
  set(VIRTUALCAM_MAC_DEVICE_NAME "OBS Virtual Camera")
endif()
if(NOT VIRTUALCAM_MAC_PROVIDER_NAME)
  set(VIRTUALCAM_MAC_PROVIDER_NAME "OBS Camera Extension Provider")
endif()
if(NOT VIRTUALCAM_MAC_MANUFACTURER)
  set(VIRTUALCAM_MAC_MANUFACTURER "John Boiles")
endif()
if(NOT VIRTUALCAM_MAC_MODEL)
  set(VIRTUALCAM_MAC_MODEL "obs-virtual-cam-model")
endif()
if(NOT VIRTUALCAM_MAC_SERIAL)
  set(VIRTUALCAM_MAC_SERIAL "0001")
endif()
if(NOT VIRTUALCAM_MAC_DEVICE_UID)
  set(VIRTUALCAM_MAC_DEVICE_UID "obs-virtual-cam-device")
endif()
if(NOT VIRTUALCAM_MAC_ELEMENT_NAME)
  set(VIRTUALCAM_MAC_ELEMENT_NAME "Virtual Camera")
endif()
if(NOT VIRTUALCAM_MAC_PLUGIN_FILE)
  set(VIRTUALCAM_MAC_PLUGIN_FILE "obs-mac-virtualcam")
endif()
if(NOT VIRTUALCAM_DAL_BUNDLE_ID)
  set(VIRTUALCAM_DAL_BUNDLE_ID "com.obsproject.obs-mac-virtualcam")
endif()
if(NOT VIRTUALCAM_EXTENSION_BUNDLE_ID)
  set(VIRTUALCAM_EXTENSION_BUNDLE_ID "com.obsproject.obs-studio.mac-camera-extension")
endif()
if(NOT VIRTUALCAM_MACH_SERVICE)
  set(VIRTUALCAM_MACH_SERVICE "com.obsproject.obs-mac-virtualcam.server")
endif()
if(NOT VIRTUALCAM_MAC_COPYRIGHT)
  string(TIMESTAMP VIRTUALCAM_MAC_COPYRIGHT "(c) 2020-%Y John Boiles, Patrick Heyer, Sebastian Beckmann")
endif()
if(NOT VIRTUALCAM_EXTENSION_USAGE_DESCRIPTION)
  set(VIRTUALCAM_EXTENSION_USAGE_DESCRIPTION
      "This Camera Extension enables virtual camera functionality in OBS Studio.")
endif()

configure_file(src/common/vcam-brand-macos.h.in vcam-brand-macos.h)
configure_file(src/common/VcamBrand.swift.in VcamBrand.swift)
set(VIRTUALCAM_SWIFT_BRAND_FILE "${CMAKE_CURRENT_BINARY_DIR}/VcamBrand.swift")

add_library(obs-mach-protocol INTERFACE)
add_library(OBS::mach-protocol ALIAS obs-mach-protocol)

target_sources(obs-mach-protocol INTERFACE src/common/MachProtocol.h src/common/data/placeholder.png
                                           "${CMAKE_CURRENT_BINARY_DIR}/vcam-brand-macos.h")
target_include_directories(obs-mach-protocol INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/src/common"
                                                       "${CMAKE_CURRENT_BINARY_DIR}")

add_subdirectory(src/obs-plugin)
add_subdirectory(src/dal-plugin)
add_subdirectory(src/camera-extension)
