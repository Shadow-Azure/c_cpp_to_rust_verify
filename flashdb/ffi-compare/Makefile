# ffi-compare/Makefile
# Build C reference static lib + Rust static lib, then compile the SAME driver
# (compare_tests.c) twice — once against each library — producing two binaries.
# The eval harness runs both and diffs their stdout (two-binary comparison).

ROOT_DIR   := $(shell cd .. && pwd)
C_SRC_DIR  := $(ROOT_DIR)/flashdb/src
C_INC_DIR  := $(ROOT_DIR)/flashdb/inc
RUST_DIR   := $(ROOT_DIR)/rust-flashdb

CC         := cc
C_TEST_DIR := $(ROOT_DIR)/flashdb/tests
# Force-include drv_log.h so FlashDB's FDB_PRINT log goes to stderr (not
# stdout), keeping stdout reserved for the deterministic CASE lines the
# equivalence diff compares.
CFLAGS     := -O0 -g3 -Wall -Wno-format -include drv_log.h -I$(C_INC_DIR) -I$(C_TEST_DIR) -I. -DFDB_USING_FILE_MODE -DFDB_USING_FILE_POSIX_MODE -DFDB_WRITE_GRAN=1 -DFDB_USING_KVDB -DFDB_USING_TSDB -DFDB_DEBUG_ENABLE
LDFLAGS    := -lpthread

# C source files
C_SRCS     := $(C_SRC_DIR)/fdb.c $(C_SRC_DIR)/fdb_file.c $(C_SRC_DIR)/fdb_kvdb.c \
              $(C_SRC_DIR)/fdb_tsdb.c $(C_SRC_DIR)/fdb_utils.c
C_OBJS     := $(patsubst $(C_SRC_DIR)/%.c,build/c_obj/%.o,$(C_SRCS))

# Output artifacts
C_LIB      := build/libflashdb_c.a
RUST_LIB   := build/libflashdb_rust.a
COMPARE_C  := build/compare_c
COMPARE_R  := build/compare_rust

.PHONY: all c-lib rust-lib compare-c compare-rust clean

all: compare-c compare-rust

# ---------- C static library ----------
c-lib: $(C_LIB)

build/c_obj:
	mkdir -p build/c_obj

build/c_obj/%.o: $(C_SRC_DIR)/%.c | build/c_obj
	$(CC) $(CFLAGS) -c $< -o $@

$(C_LIB): $(C_OBJS)
	ar rcs $@ $^

# ---------- Rust static library ----------
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

# ---------- Two-binary comparison ----------
# The SAME compare_tests.c is linked against each library independently.
# No symbol collision: each binary contains exactly one implementation.
compare-c: $(COMPARE_C)
compare-rust: $(COMPARE_R)

$(COMPARE_C): compare_tests.c $(C_LIB)
	$(CC) $(CFLAGS) -o $@ compare_tests.c $(C_LIB) $(LDFLAGS)

$(COMPARE_R): compare_tests.c $(RUST_LIB)
	$(CC) $(CFLAGS) -o $@ compare_tests.c $(RUST_LIB) $(LDFLAGS)

# ---------- Clean ----------
clean:
	rm -rf build
