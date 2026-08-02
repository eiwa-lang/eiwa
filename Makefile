.PHONY: all eiwac eiwa test clean

all: eiwac eiwa

eiwac:
	zig build

eiwa: eiwac
	./bin/eiwac build --backend=c -o bin/eiwa cli/src/main.ei

test: eiwac
	zig build test
	./bin/eiwac test --backend=c

clean:
	rm -rf zig-out .zig-cache bin
