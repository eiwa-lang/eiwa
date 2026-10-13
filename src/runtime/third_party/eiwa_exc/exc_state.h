#ifndef EIWA_EXC_STATE_H
#define EIWA_EXC_STATE_H

// Per-task try-handler state (L7): {stack top, active data, active vtable}
// with a TLS "current" pointer, moved by the scheduler on suspend/resume.
// Blocks are GC-managed (retained: see exc_state.c).
void* eiwa_exc_current_get(void);
void eiwa_exc_current_set(void* st);

void* eiwa_exc_top_get(void);
void eiwa_exc_top_set(void* p);
void* eiwa_exc_active_data_get(void);
void eiwa_exc_active_data_set(void* p);
void* eiwa_exc_active_table_get(void);
void eiwa_exc_active_table_set(void* p);

#endif // EIWA_EXC_STATE_H
