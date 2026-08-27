CXX ?= g++
BUILD_DIR ?= build
TARGET := $(BUILD_DIR)/nds_bench

CXXFLAGS ?= -O3 -DNDEBUG
CXXFLAGS += -std=c++17 -Wall -Wextra -Wpedantic -Isrc
LDFLAGS ?=

SOURCES := \
	src/bench/main.cpp \
	src/bench/Benchmark.cpp \
	src/bench/Options.cpp \
	src/core/NullEmulatorBackend.cpp

OBJECTS := $(patsubst %.cpp,$(BUILD_DIR)/%.o,$(SOURCES))

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CXX) $(OBJECTS) $(LDFLAGS) -o $@

$(BUILD_DIR)/%.o: %.cpp
	mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD_DIR)

