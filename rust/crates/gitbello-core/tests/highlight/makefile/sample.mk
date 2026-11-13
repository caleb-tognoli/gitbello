# Comment
CC ?= gcc
CFLAGS := -O2 -Wall
SRCS = $(wildcard src/*.c)
OBJS += $(patsubst %.c,%.o,$(SRCS))
export PATH := $(HOME)/bin:$(PATH)

.PHONY: all clean

all: build/app

build/app: $(OBJS) | build
	@echo "Linking $@ from $^"
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	-$(CC) -c $< -o $@ # trailing

ifeq ($(OS),Windows_NT)
    EXE := .exe
else
    EXE :=
endif

include config.mk
clean: ; rm -rf build $(OBJS)
