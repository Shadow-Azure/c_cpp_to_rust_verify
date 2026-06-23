# ffi-compare/Makefile
# 构建 C 基准库 + Rust FFI 库 + 对比测试驱动

ROOT_DIR   := $(shell cd .. && pwd)
C_SRC_DIR  := $(ROOT_DIR)/flashdb/src
C_INC_DIR  := $(ROOT_DIR)/flashdb/inc
RUST_DIR   := $(ROOT_DIR)/rust-flashdb

CC         := cc
C_TEST_DIR := $(ROOT_DIR)/flashdb/tests
CFLAGS     := -O0 -g3 -Wall -Wno-format -I$(C_INC_DIR) -I$(C_TEST_DIR) -I. -DFDB_USING_FILE_MODE -DFDB_USING_FILE_POSIX_MODE -DFDB_WRITE_GRAN=1 -DFDB_USING_KVDB -DFDB_USING_TSDB -DFDB_DEBUG_ENABLE
LDFLAGS    := -lpthread

# C 源文件
C_SRCS     := $(C_SRC_DIR)/fdb.c $(C_SRC_DIR)/fdb_file.c $(C_SRC_DIR)/fdb_kvdb.c \
              $(C_SRC_DIR)/fdb_tsdb.c $(C_SRC_DIR)/fdb_utils.c
C_OBJS     := $(patsubst $(C_SRC_DIR)/%.c,build/c_obj/%.o,$(C_SRCS))

# 输出
C_LIB      := build/libflashdb_c.a
RUST_LIB   := build/libflashdb_rust.a
TEST_BIN   := build/compare_tests

.PHONY: all c-lib rust-lib test clean

all: test

# ---------- C 静态库 ----------
c-lib: $(C_LIB)

build/c_obj:
	mkdir -p build/c_obj

build/c_obj/%.o: $(C_SRC_DIR)/%.c | build/c_obj
	$(CC) $(CFLAGS) -c $< -o $@

$(C_LIB): $(C_OBJS)
	ar rcs $@ $^

# ---------- Rust 静态库 ----------
rust-lib: $(RUST_LIB)

$(RUST_LIB):
	@if [ -d "$(RUST_DIR)" ] && [ -f "$(RUST_DIR)/Cargo.toml" ]; then \
		cd $(RUST_DIR) && cargo build --release 2>&1; \
		cp target/release/libflashdb.a $(ROOT_DIR)/ffi-compare/$(RUST_LIB) 2>/dev/null || \
		cp target/release/libflashdb.rlib $(ROOT_DIR)/ffi-compare/$(RUST_LIB) 2>/dev/null || \
		(echo "ERROR: Rust library not found after build"; exit 1); \
	else \
		echo "ERROR: rust-flashdb/ not found or no Cargo.toml"; \
		exit 1; \
	fi

# ---------- 对比测试 ----------
test: $(TEST_BIN)
	./$(TEST_BIN)

build/compare_tests: compare_tests.c $(C_LIB) $(RUST_LIB)
	$(CC) $(CFLAGS) -o $@ compare_tests.c $(C_LIB) $(RUST_LIB) $(LDFLAGS)

# ---------- 清理 ----------
clean:
	rm -rf build
