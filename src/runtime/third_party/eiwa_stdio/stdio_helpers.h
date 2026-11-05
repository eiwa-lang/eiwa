#ifndef EIWA_STDIO_HELPERS_H
#define EIWA_STDIO_HELPERS_H

// Accessor for the process standard input stream. An Eiwa `lib` block can
// only declare callable C functions, but `stdin` is not one: it is a macro
// (or data symbol) expanding to a `FILE*`, so emitting a `call stdin` would
// be UB. This trampoline is the only glue needed — `fgets`/`fread` are real
// functions and are linked directly in the `lib` block, no wrappers.
void* eiwa_stdin(void);

#endif // EIWA_STDIO_HELPERS_H
