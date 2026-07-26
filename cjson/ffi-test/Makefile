# cjson/ffi-test/Makefile — 编译 FFI 功能等价测试
#
# 用法：
#   make c-lib          # 用 CMake 编译 C 静态库 (libcjson.a)
#   make compare-c      # 编译 C 参考测试
#   make compare-rust   # 编译 Rust 测试
#   make all            # 编译所有
#   make clean          # 清理

ROOT_DIR   := $(shell cd ../.. && pwd)
CJSON_DIR  := $(ROOT_DIR)/cjson/source
BUILD_DIR  := build

CC         ?= cc
CFLAGS     := -O0 -g3 -Wall -Wno-format -I$(CJSON_DIR)

# cJSON 是纯 C89 单线程库，无系统库依赖
SYSLIBS    :=

.PHONY: all c-lib compare-c compare-rust clean

all: compare-c compare-rust

# 用 CMake 编译 C 静态库
c-lib:
	@echo "=== Building C cJSON static library ==="
	@mkdir -p $(BUILD_DIR)
	cd $(CJSON_DIR) && cmake -B build -DENABLE_CJSON_TEST=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
	cmake --build $(CJSON_DIR)/build --config Release
	cp $(CJSON_DIR)/build/libcjson.a $(BUILD_DIR)/libcjson_c.a
	@echo "✅ C library built: $(BUILD_DIR)/libcjson_c.a"

# 编译 C 参考测试
compare-c: c-lib
	@echo "=== Building C reference test ==="
	$(CC) $(CFLAGS) compare_tests.c $(BUILD_DIR)/libcjson_c.a $(SYSLIBS) -o $(BUILD_DIR)/compare_c
	@echo "✅ C reference built: $(BUILD_DIR)/compare_c"

# 编译 Rust FFI 测试
compare-rust: $(BUILD_DIR)/libcjson_rust.a
	@echo "=== Building Rust FFI test ==="
	$(CC) $(CFLAGS) compare_tests.c $(BUILD_DIR)/libcjson_rust.a $(SYSLIBS) -o $(BUILD_DIR)/compare_rust
	@echo "✅ Rust FFI built: $(BUILD_DIR)/compare_rust"

# Rust 静态库（由 equivalence.sh 预先复制）
$(BUILD_DIR)/libcjson_rust.a:
	@if [ ! -f "$@" ]; then \
		echo "ERROR: $(BUILD_DIR)/libcjson_rust.a not found"; \
		echo "       Run equivalence.sh first to copy from rust-cjson/target/release/"; \
		exit 1; \
	fi

clean:
	rm -rf $(BUILD_DIR) $(CJSON_DIR)/build
