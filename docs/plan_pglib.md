````markdown
# PostgreSQL Driver for Eiwa

## Goal

Implement the PostgreSQL driver for Eiwa using the native PostgreSQL client library (`libpq`).

The objective is **not** to reimplement the PostgreSQL protocol. Instead, Eiwa should provide an idiomatic wrapper around `libpq` through the language's C interoperability system.

The PostgreSQL driver must implement the generic database contracts provided by `std.db`, making it interchangeable with future database drivers.

This approach provides:

- Mature and well-tested implementation
- SSL support
- Authentication support
- Prepared statements
- COPY support
- LISTEN / NOTIFY
- Future compatibility with new PostgreSQL versions
- Consistent API across multiple database engines

---

# Overall Architecture

```
Application
      │
      ▼
std.db Contracts
      │
      ▼
PostgreSQL Driver
      │
      ▼
libpq Binding (C Interop)
      │
      ▼
libpq
      │
      ▼
PostgreSQL Server
```

The application should depend only on `std.db`.

The PostgreSQL package is one implementation of those contracts.

---

# Modules

```
std/
    db/
        database.eiwa
        connection.eiwa
        statement.eiwa
        result.eiwa
        row.eiwa
        transaction.eiwa
        driver.eiwa
        error.eiwa

postgres/
    postgres.eiwa
    connection.eiwa
    statement.eiwa
    result.eiwa
    row.eiwa
    transaction.eiwa

native/
    postgres.eiwa
```

The `native` module contains only the C bindings.

The `postgres` module implements the generic contracts.

---

# Generic Database Contracts

The standard library should define provider-independent contracts.

Example:

```eiwa
contract Database {

    fun connect(url: String): Connection

}
```

```eiwa
contract Connection {

    fun execute(sql: String, args...): Result

    fun query(sql: String, args...): Result

    fun prepare(sql: String): Statement

    fun transaction(block)

    fun close()

}
```

```eiwa
contract Statement {

    fun execute(args...): Result

    fun query(args...): Result

}
```

```eiwa
contract Result {

    val rowsAffected: Int

    fun iterator(): Iterator<Row>

}
```

```eiwa
contract Row {

    fun int(name: String): Int

    fun string(name: String): String

    fun bool(name: String): Bool

    fun double(name: String): Double

}
```

Every future database driver (MySQL, SQLite, SQL Server, Oracle, etc.) should implement these same contracts.

---

# PostgreSQL-Specific Features

The generic contracts should expose only features common to most SQL databases.

Database-specific capabilities should remain available through PostgreSQL-specific APIs.

Examples:

- LISTEN
- NOTIFY
- COPY
- JSONB
- Arrays
- Large Objects

These features must **not** become part of `std.db`.

---

# Native Binding

Expose only the required `libpq` functions.

Examples:

- PQconnectdb
- PQfinish
- PQexec
- PQexecParams
- PQprepare
- PQexecPrepared
- PQclear
- PQresultStatus
- PQerrorMessage
- PQntuples
- PQnfields
- PQfname
- PQgetvalue
- PQsocket
- PQsendQuery
- PQconsumeInput
- PQisBusy
- PQgetResult
- PQflush

Avoid wrapping business logic inside the binding.

The binding should closely mirror the original C API.

---

# Public API

Connection:

```eiwa
let driver = postgres.driver()

let db = driver.connect(
    "postgres://user:password@localhost/database"
)
```

Execute SQL:

```eiwa
db.execute(
    "CREATE TABLE users (...)"
)
```

Parameterized query:

```eiwa
db.execute(
    "INSERT INTO users(name) VALUES($1)",
    "John"
)
```

Query:

```eiwa
let rows = db.query(
    "SELECT id, name FROM users"
)

for row in rows {
    println(row.int("id"))
}
```

Prepared statement:

```eiwa
let stmt = db.prepare(
    "SELECT * FROM users WHERE id = $1"
)

let row = stmt.query(10)
```

Transaction:

```eiwa
db.transaction {
    ...
}
```

---

# Memory Management

Every native resource must have deterministic cleanup.

Examples:

- PGconn → PQfinish()
- PGresult → PQclear()

Never leak native resources.

---

# Asynchronous Design

The driver must use the asynchronous capabilities already provided by `libpq`.

Do **not** create worker threads.

Do **not** block the current OS thread.

Use the asynchronous `libpq` API whenever waiting for server responses.

Examples:

- PQsendQuery
- PQconsumeInput
- PQisBusy
- PQgetResult
- PQsocket
- PQflush

---

# Scheduler Integration

Eiwa uses **Neco** for fibers.

Neco is responsible only for scheduling fibers.

The PostgreSQL driver must integrate with the Eiwa runtime event loop.

Execution flow:

```
Fiber

↓

PQsendQuery()

↓

PQsocket()

↓

runtime.waitReadable(fd)

↓

yield current fiber

↓

event loop waits

↓

socket becomes readable

↓

resume fiber

↓

PQconsumeInput()

↓

PQgetResult()
```

The driver must never busy-wait.

The driver must never poll in a loop.

Waiting must always be delegated to the runtime.

---

# Runtime Abstraction

The PostgreSQL driver should never directly use platform-specific APIs such as:

- epoll
- kqueue
- IOCP
- io_uring

Instead, it should rely on runtime primitives such as:

```
runtime.waitReadable(fd)

runtime.waitWritable(fd)
```

The runtime is responsible for implementing those operations on each platform.

---

# Responsibilities

The PostgreSQL wrapper is responsible for:

- Implementing `std.db` contracts
- Connection objects
- Statement objects
- Result objects
- Row abstraction
- Error handling
- Parameter conversion
- Resource lifetime
- Idiomatic Eiwa API

The wrapper is **not** responsible for implementing the PostgreSQL protocol.

---

# Non Goals

Do not implement:

- PostgreSQL wire protocol
- SQL parser
- ORM
- Query builder
- Migration framework
- Object mapping
- Connection pool (future feature)

---

# Design Principles

- Generic provider-independent API (`std.db`)
- Thin wrapper over `libpq`
- Zero protocol implementation
- Fiber-friendly
- Fully non-blocking
- Minimal allocations
- Deterministic resource management
- Idiomatic Eiwa API
- Platform independent
- Extensible to future database engines
- Keep database-specific features outside the generic contracts
````
