# Makefile for trace_sanity_check
#
# Self-contained: no ChampSim checkout required. Compressed traces are read
# by piping through the system zstd/xz/gzip/bzip2 binaries, so there are no
# compression library dependencies to satisfy at build time either (several
# of those dev headers are absent on typical hosts).
#
# gnu++17 rather than c++17 because popen/pclose are POSIX, not ISO C++.

CXX      ?= g++
CXXFLAGS ?= -O3 -march=native -flto -DNDEBUG -std=gnu++17 -Wall -Wextra
LDFLAGS  ?=

BIN  := trace_sanity_check
SRCS := trace_sanity_check.cpp

all: $(BIN)

$(BIN): $(SRCS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(BIN)

.PHONY: all clean
