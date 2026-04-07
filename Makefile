# ================================================================
#  Makefile  –  CyberLang Compiler
#  Usage:
#    make            build the compiler (./cyberlang)
#    make run        compile test.cyber → output.c → output binary
#    make clean      remove ALL generated files
# ================================================================

CC      = gcc
CFLAGS  = -Wall -Wno-unused-function
LEXLIB  ?= -lfl
TARGET  = cyberlang
TEST    = test2.cyber
OUT_C   = output.c
OUT_BIN = output
exec = *.exe


# ---- Default target ----
all: $(TARGET)

# ---- 1. Bison  →  cyberlang.tab.c + cyberlang.tab.h ----
cyberlang.tab.c cyberlang.tab.h: cyberlang.y
	bison -d cyberlang.y

# ---- 2. Flex   →  lex.yy.c ----
lex.yy.c: cyberlang.l cyberlang.tab.h
	flex cyberlang.l

# ---- 3. GCC    →  compiler binary ----
$(TARGET): cyberlang.tab.c lex.yy.c
	$(CC) $(CFLAGS) -o $(TARGET) cyberlang.tab.c lex.yy.c $(LEXLIB)

# ---- Run: generate output.c, compile it, run it ----
run: $(TARGET)
	./$(TARGET) $(TEST)
	@echo "--- Generated C (output.c) ---"
	cat $(OUT_C)
	@echo "--- Compiling output.c ---"
	$(CC) $(CFLAGS) -o $(OUT_BIN) $(OUT_C)
	@echo "--- Running output binary ---"
	./$(OUT_BIN)

# ---- Clean ALL generated artefacts ----
clean:
	rm -f $(TARGET) cyberlang.tab.c cyberlang.tab.h lex.yy.c \
	      $(OUT_C) $(OUT_BIN) $(exec)

.PHONY: all run clean