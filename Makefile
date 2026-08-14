.PHONY: all eiwac eiwa test clean

all: eiwac eiwa

eiwac:
	zig build

eiwa: eiwac
	./bin/eiwac build --backend=llvm -o bin/eiwa cli/src/main.ei

test: eiwac
	zig build test #language tests
	./bin/eiwac test --backend=llvm #compiler tests
	./bin/eiwa test ../eiwa/example/hello #hello integration tests
	./bin/eiwa test ../eiwa/example/arest #arest integration tests

clean:
	rm -rf zig-out .zig-cache bin
