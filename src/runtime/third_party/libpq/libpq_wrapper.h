// libpq_wrapper.h — Thin C glue between Eiwa's runtime and libpq.
// TODO: should we have a wrapper for postgres?
//
// The only responsibility here is to adapt types that cannot be expressed
// directly in Eiwa's `lib` blocks:
//   - Converting a collections_List_String to char** for PQexecParams.
//
// All other libpq functions are called directly from Eiwa via @Alias.
//
// Include order: this header must be included AFTER eiwa_runtime.h so that
// core_String and the monomorphized array types are already defined.

#ifndef EIWA_LIBPQ_WRAPPER_H
#define EIWA_LIBPQ_WRAPPER_H

#include <libpq-fe.h>
#include <alloca.h>

// Forward declarations for the types the compiler will have generated.
// The actual definitions come from the monomorphized code in temp_out.c —
// this header only needs the layout, not the full definition.
typedef struct {
    const void* _type_desc;
    const char* ptr;
    int         length;
} EiwaPqString;

typedef struct {
    EiwaPqString** data;
    size_t         length;
    size_t         capacity;
} EiwaPqStringArray;

// collections_List_String layout (the items field is the first non-descriptor field)
typedef struct {
    const void*       _type_desc;
    EiwaPqStringArray* items;
} EiwaPqListString;

// Execute a parameterized query using a collections_List_String as params.
//
// conn       — PGconn* (opaque to Eiwa)
// command    — null-terminated SQL string (core_String.ptr)
// params_lst — collections_List_String* (may be NULL or have 0 items)
//
// Returns a PGresult* that the caller must pass to PQclear() after reading.
static inline PGresult *eiwa_pq_exec_params(
    PGconn             *conn,
    const char         *command,
    EiwaPqListString   *params_lst)
{
    int nparams = 0;
    const char **param_values = NULL;

    if (params_lst != NULL && params_lst->items != NULL && params_lst->items->length > 0) {
        nparams = (int)params_lst->items->length;
        // Stack-allocate the pointer array — avoids GC pressure for short queries.
        param_values = (const char **)alloca((size_t)nparams * sizeof(char *));
        for (int i = 0; i < nparams; i++) {
            EiwaPqString *s = params_lst->items->data[i];
            param_values[i] = (s != NULL) ? s->ptr : NULL;
        }
    }

    return PQexecParams(
        conn,
        command,
        nparams,
        NULL,   // paramTypes — let server infer
        param_values,
        NULL,   // paramLengths — text mode, use strlen
        NULL,   // paramFormats — all text
        0       // resultFormat — text
    );
}

// Execute a prepared statement using a collections_List_String as params.
static inline PGresult *eiwa_pq_exec_prepared(
    PGconn             *conn,
    const char         *stmtName,
    EiwaPqListString   *params_lst)
{
    int nparams = 0;
    const char **param_values = NULL;

    if (params_lst != NULL && params_lst->items != NULL && params_lst->items->length > 0) {
        nparams = (int)params_lst->items->length;
        param_values = (const char **)alloca((size_t)nparams * sizeof(char *));
        for (int i = 0; i < nparams; i++) {
            EiwaPqString *s = params_lst->items->data[i];
            param_values[i] = (s != NULL) ? s->ptr : NULL;
        }
    }

    return PQexecPrepared(
        conn,
        stmtName,
        nparams,
        param_values,
        NULL,   // paramLengths — text mode, use strlen
        NULL,   // paramFormats — all text
        0       // resultFormat — text
    );
}

// Convenience: execute a no-param query (wraps PQexec).
static inline PGresult *eiwa_pq_exec(PGconn *conn, const char *command) {
    return PQexec(conn, command);
}

// Get a field value as a null-terminated C string.
// Returns empty string if the value is NULL in the result set.
static inline const char *eiwa_pq_getvalue(PGresult *res, int row, int col) {
    if (PQgetisnull(res, row, col)) return "";
    return PQgetvalue(res, row, col);
}

// Number of rows affected by a non-SELECT command (INSERT, UPDATE, DELETE).
static inline int eiwa_pq_rows_affected(PGresult *res) {
    const char *str = PQcmdTuples(res);
    if (!str || str[0] == '\0') return 0;
    return atoi(str);
}

// Column index by name (-1 if not found).
static inline int eiwa_pq_field_index(PGresult *res, const char *name) {
    return PQfnumber(res, name);
}

#endif // EIWA_LIBPQ_WRAPPER_H
