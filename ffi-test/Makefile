# ffi-test/Makefile — 编译 FFI 功能等价测试
#
# 用法：
#   make c-lib          # 编译 C 静态库
#   make compare-c      # 编译 C 参考测试
#   make compare-rust   # 编译 Rust 测试
#   make all            # 编译所有
#   make clean          # 清理

CC ?= gcc
CFLAGS = -O0 -g3 -Wall -Wno-format
INCLUDES = -I../flashdb/inc -I../flashdb/tests -I.

# 库路径
C_LIB_DIR = ../flashdb
RUST_LIB_DIR = ../rust-flashdb/target/release

# 构建目录
BUILD_DIR = build

.PHONY: all c-lib compare-c compare-rust clean

all: compare-c compare-rust

# 编译 C 静态库
c-lib:
	@echo "=== Building C static library ==="
	cd $(C_LIB_DIR) && make clean && make lib
	@mkdir -p $(BUILD_DIR)
	cp $(C_LIB_DIR)/lib/*.a $(BUILD_DIR)/libflashdb_c.a 2>/dev/null || \
	cp $(C_LIB_DIR)/build/*.a $(BUILD_DIR)/libflashdb_c.a 2>/dev/null || \
	(echo "ERROR: C library not found"; exit 1)
	@echo "✅ C library built: $(BUILD_DIR)/libflashdb_c.a"

# 编译 C 参考测试
compare-c: $(BUILD_DIR)/libflashdb_c.a
	@echo "=== Building C reference test ==="
	$(CC) $(CFLAGS) $(INCLUDES) -DFDB_USING_FILE_MODE -DFDB_USING_FILE_POSIX_MODE \
		-DFDB_WRITE_GRAN=1 -DFDB_USING_KVDB -DFDB_USING_TSDB -DFDB_DEBUG_ENABLE \
		compare_tests.c $(BUILD_DIR)/libflashdb_c.a -lpthread -o $(BUILD_DIR)/compare_c
	@echo "✅ C reference built: $(BUILD_DIR)/compare_c"

# 编译 Rust 测试
compare-rust: $(BUILD_DIR)/libflashdb_rust.a
	@echo "=== Building Rust FFI test ==="
	$(CC) $(CFLAGS) $(INCLUDES) -DFDB_USING_FILE_MODE -DFDB_USING_FILE_POSIX_MODE \
		-DFDB_WRITE_GRAN=1 -DFDB_USING_KVDB -DFDB_USING_TSDB -DFDB_DEBUG_ENABLE \
		compare_tests.c $(BUILD_DIR)/libflashdb_rust.a -lpthread -lm -ldl -o $(BUILD_DIR)/compare_rust
	@echo "✅ Rust FFI built: $(BUILD_DIR)/compare_rust"

# 复制 Rust 静态库（由 eval-equivalence.sh 预先复制）
$(BUILD_DIR)/libflashdb_rust.a:
	@if [ ! -f "$@" ]; then \
		echo "ERROR: $(BUILD_DIR)/libflashdb_rust.a not found"; \
		echo "       Run eval-equivalence.sh first to copy from rust-flashdb/target/release/"; \
		exit 1; \
	fi

clean:
	rm -rf $(BUILD_DIR)
