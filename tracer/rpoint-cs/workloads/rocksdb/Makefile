ROCKSDB_ROOT    ?= /mnt/sherlock/rahbera/workloadzoo/rocksdb-install
CHAMPSIM_TRACER ?= /home/rahbera/arishem/champsim/tracer

CXX      = g++
CXXFLAGS = -O2 -std=c++17 -Wall -Wextra -Wno-unused-parameter \
           -I$(ROCKSDB_ROOT)/include \
           -I$(CHAMPSIM_TRACER)
LDFLAGS  = -L$(ROCKSDB_ROOT)/lib -Wl,-rpath,$(ROCKSDB_ROOT)/lib \
           -lrocksdb -lpthread -lsnappy -lz -lbz2 -lzstd -ldl -lm

TARGET = rocksdb_driver
SRCS   = rocksdb_driver.cpp
HDRS   = zipfian.h

all: $(TARGET)

$(TARGET): $(SRCS) $(HDRS)
	$(CXX) $(CXXFLAGS) -o $@ $(SRCS) $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
