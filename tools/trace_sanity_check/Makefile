# Makefile for trace_sanity_check
#
# Reuses champsim/src/trace_reader.cc as the decompression backend so we
# get byte-for-byte parity with the simulator. CHAMPSIM_HOME points at
# the champsim repo (default: ../../../champsim, matching the layout of
# this infra repo as a sibling of champsim).
#
# Honours ZSTD_HOME the same way trace_cutter's Makefile does, in case
# the user is linking against a custom zstd build.

CHAMPSIM_HOME ?= ../../../champsim
ZSTD_HOME     ?=

CXX      ?= g++
CXXFLAGS ?= -O3 -march=native -flto -DNDEBUG -std=c++17 -Wall -Wextra
LDFLAGS  ?=

CXXFLAGS += -I$(CHAMPSIM_HOME)/inc

ifneq ($(strip $(ZSTD_HOME)),)
  CXXFLAGS += -I$(ZSTD_HOME)/include
  LDFLAGS  += -L$(ZSTD_HOME)/lib -Wl,-rpath,$(ZSTD_HOME)/lib
endif

LDLIBS := -lz -llzma -lzstd

BIN  := trace_sanity_check
SRCS := trace_sanity_check.cpp $(CHAMPSIM_HOME)/src/trace_reader.cc

all: $(BIN)

$(BIN): $(SRCS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

clean:
	rm -f $(BIN)

.PHONY: all clean
