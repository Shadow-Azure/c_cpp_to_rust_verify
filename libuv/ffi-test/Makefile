# libuv/ffi-test/Makefile — 编译 FFI 功能等价测试
#
# 用法：
#   make c-lib          # 用 CMake 编译 C 静态库 (libuv.a)
#   make compare-c      # 编译 C 参考测试
#   make compare-rust   # 编译 Rust 测试
#   make all            # 编译所有
#   make clean          # 清理

ROOT_DIR   := $(shell cd ../.. && pwd)
LIBUV_DIR  := $(ROOT_DIR)/libuv/source
BUILD_DIR  := build

CC         ?= cc
CFLAGS     := -O0 -g3 -Wall -Wno-format -I$(LIBUV_DIR)/include

# libuv 系统依赖（Linux）
SYSLIBS    := -lpthread -ldl -lrt

.PHONY: all c-lib compare-c compare-rust clean

all: compare-c compare-rust

# 用 CMake 编译 C 静态库
c-lib:
	@echo "=== Building C libuv static library ==="
	@mkdir -p $(BUILD_DIR)
	cd $(LIBUV_DIR) && cmake -B build -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release
	cmake --build $(LIBUV_DIR)/build --config Release
	cp $(LIBUV_DIR)/build/libuv.a $(BUILD_DIR)/libuv_c.a
	@echo "✅ C library built: $(BUILD_DIR)/libuv_c.a"

# 编译 C 参考测试
compare-c: c-lib
	@echo "=== Building C reference test ==="
	$(CC) $(CFLAGS) compare_tests.c $(BUILD_DIR)/libuv_c.a $(SYSLIBS) -o $(BUILD_DIR)/compare_c
	@echo "✅ C reference built: $(BUILD_DIR)/compare_c"

# 编译 Rust FFI 测试
compare-rust: $(BUILD_DIR)/libuv_rust.a
	@echo "=== Building Rust FFI test ==="
	$(CC) $(CFLAGS) compare_tests.c $(BUILD_DIR)/libuv_rust.a $(SYSLIBS) -o $(BUILD_DIR)/compare_rust
	@echo "✅ Rust FFI built: $(BUILD_DIR)/compare_rust"

# Rust 静态库（由 equivalence.sh 预先复制）
$(BUILD_DIR)/libuv_rust.a:
	@if [ ! -f "$@" ]; then \
		echo "ERROR: $(BUILD_DIR)/libuv_rust.a not found"; \
		echo "       Run equivalence.sh first to copy from rust-libuv/target/release/"; \
		exit 1; \
	fi

clean:
	rm -rf $(BUILD_DIR) $(LIBUV_DIR)/build
