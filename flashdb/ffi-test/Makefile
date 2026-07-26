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
INCLUDES = -I../flashdb/inc -I.

# FlashDB 源文件
FDB_SRC_DIR = ../flashdb/src
FDB_SRCS = $(FDB_SRC_DIR)/fdb.c \
           $(FDB_SRC_DIR)/fdb_file.c \
           $(FDB_SRC_DIR)/fdb_kvdb.c \
           $(FDB_SRC_DIR)/fdb_tsdb.c \
           $(FDB_SRC_DIR)/fdb_utils.c

# 构建目录
BUILD_DIR = build

.PHONY: all c-lib compare-c compare-rust clean

all: compare-c compare-rust

# 编译 C 静态库（直接编译源文件）
c-lib:
	@echo "=== Building C static library ==="
	@mkdir -p $(BUILD_DIR)
	@# 编译每个源文件
	@for src in $(FDB_SRCS); do \
		echo "  Compiling $$src..."; \
		$(CC) $(CFLAGS) $(INCLUDES) \
			-DFDB_USING_FILE_MODE -DFDB_USING_FILE_POSIX_MODE \
			-DFDB_WRITE_GRAN=1 -DFDB_USING_KVDB -DFDB_USING_TSDB \
			-DFDB_DEBUG_ENABLE \
			-c $$src -o $(BUILD_DIR)/$$(basename $$src .c).o || exit 1; \
	done
	@# 创建静态库
	ar rcs $(BUILD_DIR)/libflashdb_c.a $(BUILD_DIR)/*.o
	@echo "✅ C library built: $(BUILD_DIR)/libflashdb_c.a"

# 编译 C 参考测试
compare-c: c-lib
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
