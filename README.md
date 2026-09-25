```
   _._
 o|- -|o This file is licensed under CC BY-NC-SA 4.0 international license.
  ( l )  To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
    =    Author: jean-marc "jihem" quere 2016
```

## firebird/fbclient
> Lab'Oratoire / Magenta Project - Laboratory of Cognitive and Social Psycholinguistics \
> https://lipunila.sonaliwan.fr - metalab(at)sonaliwan.fr

**fbclient** is a Nim binding for Firebird (available for Linux, macOS and Windows*), written directly on top of the native C API (fbclient). It provides an idiomatic, typed interface with no dependency on ODBC. Its strengths:
- **Easy to use**: connect, then exec, query, getRow, getValue or the rows iterator, with positional ? parameters converted automatically (toFb).
- **Full transaction support**: a default transaction with autocommit, explicit transactions with options (isolation, wait mode, table reservations), savepoints and the withTransaction block.
- Prepared statements: cursors, `executeMany`, execution plan, number of affected rows, etc.

*) If the provided libraries are rejected, retrieve them directly from a local Firebird installation.

Example
```
import firebird/fbclient

let db = connect("localhost:/data/test.fdb", "SYSDBA", "masterkey")
db.withTransaction(tx):
  discard tx.exec("INSERT INTO client (nom) VALUES (?)", "Dupont")
for r in db.rows("SELECT id, nom FROM client WHERE id > ?", 10):
  echo r.get("NOM", string)
```

This repository contains the client sources (in src/firebird), the libraries and an example (demo.nim). You need a Firebird server ([download here](https://www.firebirdsql.org/en/server-packages/)) and must **adjust the connection parameters** (in the environment variables or directly in the example: demo.nim). The client libraries (libfbclient.so, libfbclient.dylib and libfbclient.dll) are loaded from their respective folders (linOS, macOS and winOS). Like the Firebird software itself, they are free and redistributable, including in commercial and proprietary applications (see FIREBIRD.md).

Usage (after `nimble build`):
```
./demo
```

**Firebird** => https://www.firebirdsql.org

Firebird is an **open source relational database management system (RDBMS)**, derived from the InterBase 6.0 code released by Borland in 2000. It is developed by the community under the IPL/IDPL license, which **allows free commercial use**. Its main distinguishing feature is its lightness: a database fits in a single file (often .fdb), installation is minimal and administration is close to zero. It can run as a traditional server (SuperServer, Classic or SuperClassic architectures) or in embedded mode, built directly into an application without a separate server.

Technically, it relies on a multi-generational architecture (MVCC), where readers do not block writers. Transactions are **ACID**, with several isolation levels. Its **SQL is rich and standards-compliant**: stored procedures and triggers in PSQL, window functions, recursive CTEs, sequences, BLOBs and events (POST_EVENT). It is the ideal database for business management applications, line-of-business software and embedded solutions. It is mainly used in Europe within the Delphi ecosystem.

For a truly comfortable experience, I recommend using [DBeaver Community](https://dbeaver.io), which lets you work very comfortably with the usual databases (including duckDB and Firebird). As a database user since the 90s (Microsoft SQL Server, HyperFile/SQL, MySQL/MariaDB, PostgreSQL, Interface/Firebird, ...), only one has never let me down... I think you can guess which one.

### One more thing!
A small gesture that can—hugely—help us out... [Caffeine is important for a team of neurodivergent individuals: ASD, ADHD, GAD, gifted IQ and highly/exceptionally gifted (members of **mensa.fr** and **triplenine.org**).]

[![Buy Me a Coffee](buymeacoffe-eng.png)](https://buymeacoffee.com/sonaliwan.fr)
