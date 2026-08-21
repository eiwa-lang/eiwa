.PHONY: all eiwac eiwa test clean

build: eiwac eiwa

eiwac:
	zig build

eiwa: eiwac
	./bin/eiwac build -o bin/eiwa cli/src/main.ei

test: eiwac
	zig build test #language tests
	./bin/eiwac test #compiler tests
	./bin/eiwa test ../eiwa/example/hello #hello integration tests
	./bin/eiwa test ../eiwa/example/arest #arest integration tests

clean:
	rm -rf zig-out .zig-cache bin
