cmake_minimum_required(VERSION 3.16)

project(NDS4MiSTer LANGUAGES CXX)

include(CTest)
find_package(Threads REQUIRED)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(NDS4MISTER_USE_MELONDS "Build the benchmark against the vendored melonDS core" ON)
option(NDS4MISTER_ENABLE_LTO_RELEASE "Enable release LTO for the benchmark and melonDS core" OFF)
option(NDS4MISTER_ENABLE_JIT "Enable melonDS JIT on supported host architectures" OFF)
option(NDS4MISTER_CORE_TIMING "Diagnostic: enable intrusive coarse CPU/GPU/audio timing probes inside melonDS" OFF)
option(NDS4MISTER_NO_VIDEO_RENDER "Diagnostic: skip melonDS video renderer output while preserving LCD timing" OFF)
option(NDS4MISTER_NO_2D_RENDER "Diagnostic: skip melonDS 2D scanline and sprite rendering while preserving LCD timing" OFF)
option(NDS4MISTER_NO_3D_RENDER "Diagnostic: skip melonDS 3D frame rendering while preserving LCD timing" OFF)
option(NDS4MISTER_NO_AUDIO_MIX "Diagnostic: skip melonDS audio mixer work while preserving SPU event timing" OFF)
option(NDS4MISTER_FPGA_AUDIO_OFFLOAD
    "Build default-off FPGA-audio offload support with a lightweight SPU status shadow"
    OFF)
option(NDS4MISTER_EXTERNAL_TIME_WINDOW
    "Build the default-off host/simulator external scheduler time-window proof API"
    OFF)

if(NDS4MISTER_FPGA_AUDIO_OFFLOAD AND NDS4MISTER_NO_AUDIO_MIX)
    message(FATAL_ERROR
        "NDS4MISTER_FPGA_AUDIO_OFFLOAD preserves SPU status timing and cannot be combined with NDS4MISTER_NO_AUDIO_MIX")
endif()

add_executable(nds_layer_upload src/replay/LayerUpload.cpp)
target_include_directories(nds_layer_upload PRIVATE src)
target_compile_options(nds_layer_upload PRIVATE -Wall -Wextra -Wpedantic)

add_executable(nds_compact_upload src/replay/CompactFrameUpload.cpp)
target_include_directories(nds_compact_upload PRIVATE src)
target_compile_options(nds_compact_upload PRIVATE -Wall -Wextra -Wpedantic)

add_executable(nds_compact_receiver src/replay/CompactFrameReceiver.cpp)
target_include_directories(nds_compact_receiver PRIVATE src)
target_compile_options(nds_compact_receiver PRIVATE -Wall -Wextra -Wpedantic)

add_executable(nds_compact_frame_dump src/replay/CompactFrameDump.cpp)
target_include_directories(nds_compact_frame_dump PRIVATE src)
target_compile_options(nds_compact_frame_dump PRIVATE -Wall -Wextra -Wpedantic)

add_executable(nds_hps_oracle_sampler src/replay/HpsOracleSampler.cpp)
target_compile_options(nds_hps_oracle_sampler PRIVATE -Wall -Wextra -Wpedantic)

add_executable(nds_physical_memory_snapshot
    src/replay/PhysicalMemorySnapshot.cpp)
target_compile_options(nds_physical_memory_snapshot PRIVATE
    -Wall -Wextra -Wpedantic)

if(NDS4MISTER_USE_MELONDS)
    set(BUILD_QT_SDL OFF CACHE BOOL "" FORCE)
    set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
    set(ENABLE_GDBSTUB OFF CACHE BOOL "" FORCE)
    set(ENABLE_JIT ${NDS4MISTER_ENABLE_JIT} CACHE BOOL "" FORCE)
    set(ENABLE_LTO_RELEASE ${NDS4MISTER_ENABLE_LTO_RELEASE} CACHE BOOL "" FORCE)
    add_subdirectory(third_party/melonDS EXCLUDE_FROM_ALL)
    target_compile_definitions(core PUBLIC NDS4MISTER_CORE_TIMING=$<BOOL:${NDS4MISTER_CORE_TIMING}>)
    target_compile_definitions(core PUBLIC NDS4MISTER_NO_VIDEO_RENDER=$<BOOL:${NDS4MISTER_NO_VIDEO_RENDER}>)
    target_compile_definitions(core PUBLIC NDS4MISTER_NO_2D_RENDER=$<BOOL:${NDS4MISTER_NO_2D_RENDER}>)
    target_compile_definitions(core PUBLIC NDS4MISTER_NO_3D_RENDER=$<BOOL:${NDS4MISTER_NO_3D_RENDER}>)
    target_compile_definitions(core PUBLIC NDS4MISTER_NO_AUDIO_MIX=$<BOOL:${NDS4MISTER_NO_AUDIO_MIX}>)
    target_compile_definitions(core PUBLIC
        NDS4MISTER_FPGA_AUDIO_OFFLOAD=$<BOOL:${NDS4MISTER_FPGA_AUDIO_OFFLOAD}>)
    target_compile_definitions(core PUBLIC
        NDS4MISTER_EXTERNAL_TIME_WINDOW=$<BOOL:${NDS4MISTER_EXTERNAL_TIME_WINDOW}>)
endif()

add_library(nds_headless_save STATIC
    src/melonds/HeadlessSaveManager.cpp)
target_include_directories(nds_headless_save PUBLIC src)
target_compile_options(nds_headless_save PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(nds_headless_save PUBLIC Threads::Threads)

if(BUILD_TESTING)
    add_executable(nds_headless_save_test
        src/replay/HeadlessSaveManagerTest.cpp)
    target_include_directories(nds_headless_save_test PRIVATE src)
    target_compile_options(nds_headless_save_test PRIVATE
        -Wall -Wextra -Wpedantic)
    target_link_libraries(nds_headless_save_test PRIVATE nds_headless_save)
    add_test(NAME nds_headless_save_lifecycle
        COMMAND nds_headless_save_test)

    if(NDS4MISTER_USE_MELONDS)
        add_executable(nds_save_chip_test
            src/replay/NdsSaveChipTest.cpp
            src/melonds/HeadlessPlatform.cpp)
        target_include_directories(nds_save_chip_test PRIVATE
            src third_party/melonDS/src)
        target_compile_options(nds_save_chip_test PRIVATE
            -Wall -Wextra -Wpedantic)
        target_link_libraries(nds_save_chip_test PRIVATE
            core nds_headless_save ${CMAKE_DL_LIBS})
        add_test(NAME nds_save_chip_semantics
            COMMAND nds_save_chip_test)
    endif()
endif()

add_executable(nds_bench
    src/bench/main.cpp
    src/bench/Benchmark.cpp
    src/bench/Options.cpp
    src/core/NullEmulatorBackend.cpp
)

target_include_directories(nds_bench PRIVATE src)

target_compile_options(nds_bench PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

if(NDS4MISTER_USE_MELONDS)
    target_sources(nds_bench PRIVATE
        src/melonds/HeadlessPlatform.cpp
        src/melonds/MelonDsBackend.cpp
    )
    target_compile_definitions(nds_bench PRIVATE NDS4MISTER_USE_MELONDS)
    target_link_libraries(nds_bench PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_gpu_replay
        src/replay/Replay3D.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp
    )
    target_include_directories(nds_gpu_replay PRIVATE src third_party/melonDS/src)
    target_link_libraries(nds_gpu_replay PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_hybrid_3d_service
        src/replay/Hybrid3DService.cpp
        src/replay/Hybrid3DFramePacket.cpp
        src/replay/ArmVideoShadow.cpp
        src/replay/ArmCrashDump.cpp
        src/replay/FpgaCrashMonitor.cpp
        src/melonds/HeadlessPlatform.cpp
    )
    target_include_directories(nds_hybrid_3d_service PRIVATE
        src third_party/melonDS/src)
    target_compile_options(nds_hybrid_3d_service PRIVATE
        -Wall -Wextra -Wpedantic)
    # The vendored melonDS directory enables release IPO for libcore, but that
    # directory-scoped setting does not reach this executable. Keep the service
    # side of the hot replay/render boundary in the same LTO program so the ARM
    # linker can optimize across the static-library call edge as intended.
    set_property(TARGET nds_hybrid_3d_service PROPERTY
        INTERPROCEDURAL_OPTIMIZATION_RELEASE
        ${NDS4MISTER_ENABLE_LTO_RELEASE})
    target_link_libraries(nds_hybrid_3d_service PRIVATE
        core ${CMAKE_DL_LIBS})

    add_executable(hps_gpu_ring_test src/replay/RingTest.cpp)
    target_include_directories(hps_gpu_ring_test PRIVATE src)

    add_executable(hgs_live_encoder_test src/replay/LiveEncoderTest.cpp)
    target_include_directories(hgs_live_encoder_test PRIVATE src third_party/melonDS/src)

    add_executable(arm_video_shadow_test
        src/replay/ArmVideoShadow.cpp
        src/replay/ArmVideoShadowTest.cpp)
    target_include_directories(arm_video_shadow_test PRIVATE
        src third_party/melonDS/src)
    target_compile_options(arm_video_shadow_test PRIVATE
        -Wall -Wextra -Wpedantic)

    add_executable(arm_video_event_test
        src/replay/ArmVideoEventTest.cpp)
    target_include_directories(arm_video_event_test PRIVATE src)
    target_compile_options(arm_video_event_test PRIVATE
        -Wall -Wextra -Wpedantic)

    add_executable(hgs_live_file_test src/replay/LiveFileTest.cpp)
    target_include_directories(hgs_live_file_test PRIVATE src third_party/melonDS/src)

    add_executable(nds_live_hgs_test
        src/replay/LiveProducerTest.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_live_hgs_test PRIVATE src third_party/melonDS/src)
    target_link_libraries(nds_live_hgs_test PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_layer_capture
        src/replay/LayerCapture.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_layer_capture PRIVATE src third_party/melonDS/src)
    target_link_libraries(nds_layer_capture PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_display_capture_oracle_test
        src/replay/DisplayCaptureOracleTest.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_display_capture_oracle_test PRIVATE
        src third_party/melonDS/src)
    target_compile_options(nds_display_capture_oracle_test PRIVATE
        -Wall -Wextra -Wpedantic)
    target_link_libraries(nds_display_capture_oracle_test PRIVATE
        core ${CMAKE_DL_LIBS})
    if(BUILD_TESTING)
        add_test(NAME nds_display_capture_oracle
            COMMAND nds_display_capture_oracle_test)
    endif()

    add_executable(nds_touch_oracle_probe
        src/replay/TouchOracleProbe.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_touch_oracle_probe PRIVATE
        src third_party/melonDS/src)
    target_compile_options(nds_touch_oracle_probe PRIVATE
        -Wall -Wextra -Wpedantic)
    target_link_libraries(nds_touch_oracle_probe PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_live_layer_publish
        src/replay/LiveLayerPublish.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_live_layer_publish PRIVATE src third_party/melonDS/src)
    target_link_libraries(nds_live_layer_publish PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_live_compact_stream
        src/replay/LiveCompactStream.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_live_compact_stream PRIVATE src third_party/melonDS/src)
    target_link_libraries(nds_live_compact_stream PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_hps_oracle_responder
        src/replay/HpsOracleResponder.cpp
        src/replay/ConsumedCreditAckDdrProducer.cpp
        src/replay/ConsumedCreditAckMappedDdrMemory.cpp
        src/replay/ExternalTimeWindowDdrProducer.cpp
        src/replay/ExternalTimeWindowDdrBridge.cpp
        src/replay/ExternalTimeWindowLwControl.cpp
        src/replay/ExternalTimeWindowRuntime.cpp
        src/replay/SoundPersistentEpoch.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_hps_oracle_responder PRIVATE src third_party/melonDS/src)
    target_compile_options(nds_hps_oracle_responder PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(nds_hps_oracle_responder PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_boot_image_probe
        src/replay/BootImageProbe.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_boot_image_probe PRIVATE src third_party/melonDS/src)
    target_compile_options(nds_boot_image_probe PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(nds_boot_image_probe PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    add_executable(nds_external_timing_test
        src/replay/ExternalTimingTest.cpp
        src/melonds/MelonDsBackend.cpp
        src/melonds/HeadlessPlatform.cpp)
    target_include_directories(nds_external_timing_test PRIVATE src third_party/melonDS/src)
    target_compile_options(nds_external_timing_test PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(nds_external_timing_test PRIVATE
        core nds_headless_save ${CMAKE_DL_LIBS})

    if(NDS4MISTER_EXTERNAL_TIME_WINDOW)
        add_executable(nds_external_time_window_test
            src/replay/ExternalTimeWindowTest.cpp
            src/melonds/MelonDsBackend.cpp
            src/melonds/HeadlessPlatform.cpp)
        target_include_directories(nds_external_time_window_test PRIVATE
            src third_party/melonDS/src)
        target_compile_options(nds_external_time_window_test PRIVATE
            -Wall -Wextra -Wpedantic)
        target_link_libraries(nds_external_time_window_test PRIVATE
            core nds_headless_save ${CMAKE_DL_LIBS})
    endif()

    if(NDS4MISTER_FPGA_AUDIO_OFFLOAD)
        add_executable(nds_fpga_audio_offload_test
            src/replay/FpgaAudioOffloadTest.cpp
            src/melonds/HeadlessPlatform.cpp)
        target_include_directories(nds_fpga_audio_offload_test PRIVATE
            src third_party/melonDS/src)
        target_compile_options(nds_fpga_audio_offload_test PRIVATE
            -Wall -Wextra -Wpedantic)
        target_link_libraries(nds_fpga_audio_offload_test PRIVATE
            core ${CMAKE_DL_LIBS})
    endif()
endif()
