# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#    __ _       ___ _ _            _
#  / _| |__    / __\ (_) ___ _ __ | |_
#  | |_| '_ \ / /  | | |/ _ \ '_ \| __|
#  |  _| |_) / /___| | |  __/ | | | |_
#  |_| |_.__/\____/|_|_|\___|_| |_|\__|
#  Firebird client for Nim
#  > need firebird libfbclient dynamic library.
#
# - database connection / creation / deletion (full DPB options);
# - default transaction with auto-commit, or explicit transactions
#   (isolation levels, read-only, lock wait/timeout,
#   table reservation, savepoints, two-phase commit);
# - prepared statements with positional parameters (`?`) of all types;
# - reading of all Firebird SQL types (including BOOLEAN, and INT128,
#   DECFLOAT, TIME/TIMESTAMP WITH TIME ZONE converted to text server-side);
# - text and binary BLOBs (automatic loading or segmented streams);
# - execution plan, number of affected rows, statement type;
# - database information, ping, cancellation, POST_EVENT events;
# - detailed errors (GDS code, SQLCODE, SQLSTATE, messages).
#
# Example :
#
#   import firebird
#   let db = connect("localhost:/data/test.fdb", "SYSDBA", "masterkey")
#   defer: db.close()
#   db.exec("INSERT INTO t (id, nom) VALUES (?, ?)", 1, "Alice")
#   for row in db.rows("SELECT id, nom FROM t WHERE id > ?", 0):
#     echo row["ID"].asInt, " ", row["NOM"].asString

import std/[strutils, tables, options, times]
import fblibapi

export fblibapi, options

# Errors

type
  FbError* = object of CatchableError
    # Errors Error returned by the server or the client library.
    gdsCode*: int            ## first ISC error code (e.g. 335544665).
    sqlCode*: int            ## SQLCODE historical (e.g. -803).
    sqlState*: string        ## SQLSTATE 5 characters (e.g. "23000").
    messages*: seq[string]   ## messages détaillés.

  FbConversionError* = object of ValueError
    # Unable to convert a value: NULL, incompatible type...

proc newFbError(msg: string): ref FbError =
  result = newException(FbError, msg)

proc raiseFb(sv: var StatusVector, context: string) {.noreturn.} =
  var e = newException(FbError, "")
  e.gdsCode = int(sv[1])
  e.sqlCode = int(isc_sqlcode(addr sv[0]))
  var state: array[8, char]
  fb_sqlstate(cast[cstring](addr state[0]), addr sv[0])
  e.sqlState = $cast[cstring](addr state[0])
  var p = addr sv[0]
  var buf: array[1024, char]
  while true:
    let n = fb_interpret(cast[cstring](addr buf[0]), cuint(buf.len), addr p)
    if n <= 0: break
    e.messages.add $cast[cstring](addr buf[0])
  e.msg = (if context.len > 0: context & " : " else: "") & e.messages.join("\n")
  if e.sqlState.len > 0:
    e.msg.add " [SQLSTATE " & e.sqlState & "]"
  raise e

template check(sv: StatusVector, context = "") =
  if sv[0] == 1 and sv[1] != 0:
    raiseFb(sv, context)

# Values

type
  FbDate* = object
    year*, month*, day*: int

  FbTime* = object
    hour*, minute*, second*: int
    fraction*: int           # ten-thousandths of a second (0..9999).

  FbTimestamp* = object
    date*: FbDate
    time*: FbTime

  FbValueKind* = enum
    fkNull, fkBool, fkInt, fkDecimal, fkFloat, fkString, fkBinary,
    fkDate, fkTime, fkTimestamp, fkBlobId

  FbValue* = object
    # SQL value (parameter or result column).
    case kind*: FbValueKind
    of fkNull: discard
    of fkBool: boolVal*: bool
    of fkInt: intVal*: int64
    of fkDecimal:
      decVal*: int64         ## value = decVal × 10^decScale.
      decScale*: int         ## scale (≤ 0), e.g. -2 <=> NUMERIC(15,2).
    of fkFloat: floatVal*: float64
    of fkString, fkBinary: strVal*: string
    of fkDate: dateVal*: FbDate
    of fkTime: timeVal*: FbTime
    of fkTimestamp: tsVal*: FbTimestamp
    of fkBlobId: blobId*: IscQuad

const fbNull* = FbValue(kind: fkNull)

# Calendar

const iscEpochOffset = 40587   # days between 1858-11-17 and 1970-01-01.

proc daysFromCivil(y0, m, d: int): int =
  let y = if m <= 2: y0 - 1 else: y0
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc civilFromDays(z0: int): (int, int, int) =
  let z = z0 + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  let year = if m <= 2: y + 1 else: y
  (year, m, d)

proc encodeDate*(d: FbDate): IscDate =
  IscDate(daysFromCivil(d.year, d.month, d.day) + iscEpochOffset)

proc decodeDate*(x: IscDate): FbDate =
  let (y, m, d) = civilFromDays(int(x) - iscEpochOffset)
  FbDate(year: y, month: m, day: d)

proc encodeTime*(t: FbTime): IscTime =
  IscTime(((t.hour * 60 + t.minute) * 60 + t.second) * 10000 + t.fraction)

proc decodeTime*(x: IscTime): FbTime =
  var v = int(x)
  result.fraction = v mod 10000
  v = v div 10000
  result.second = v mod 60
  v = v div 60
  result.minute = v mod 60
  result.hour = v div 60

proc fbDate*(year, month, day: int): FbDate =
  FbDate(year: year, month: month, day: day)

proc fbTime*(hour, minute, second: int, fraction = 0): FbTime =
  FbTime(hour: hour, minute: minute, second: second, fraction: fraction)

proc fbTimestamp*(year, month, day: int, hour = 0, minute = 0, second = 0,
                  fraction = 0): FbTimestamp =
  FbTimestamp(date: fbDate(year, month, day),
              time: fbTime(hour, minute, second, fraction))

proc `$`*(d: FbDate): string =
  intToStr(d.year, 4) & "-" & intToStr(d.month, 2) & "-" & intToStr(d.day, 2)

proc `$`*(t: FbTime): string =
  result = intToStr(t.hour, 2) & ":" & intToStr(t.minute, 2) & ":" & intToStr(t.second, 2)
  if t.fraction != 0:
    result.add "." & intToStr(t.fraction, 4)

proc `$`*(ts: FbTimestamp): string = $ts.date & " " & $ts.time

proc toDateTime*(ts: FbTimestamp, zone: Timezone = local()): DateTime =
  # Interprets a Firebird timestamp (without time zone) in the given time zone.
  dateTime(ts.date.year, Month(ts.date.month), MonthdayRange(ts.date.day),
           HourRange(ts.time.hour), MinuteRange(ts.time.minute),
           SecondRange(ts.time.second), NanosecondRange(ts.time.fraction * 100_000),
           zone)

proc toFbTimestamp*(dt: DateTime): FbTimestamp =
  fbTimestamp(dt.year, ord(dt.month), dt.monthday, dt.hour, dt.minute,
              dt.second, dt.nanosecond div 100_000)

# Decimals

proc pow10(n: int): int64 =
  result = 1
  for _ in 1..n: result *= 10

proc decimalToString*(v: int64, scale: int): string =
  # Exact textual representation of a NUMERIC/DECIMAL.
  if scale >= 0:
    return $v & repeat('0', scale)
  let neg = v < 0
  let u = if neg: uint64(not v) + 1 else: uint64(v)
  var s = $u
  let sc = -scale
  if s.len <= sc:
    s = repeat('0', sc - s.len + 1) & s
  result = s[0 ..< s.len - sc] & "." & s[s.len - sc .. ^1]
  if neg: result = "-" & result

proc decimal*(value: int64, scale: int): FbValue =
  # Constructs a decimal: `decimal(12345, -2)` represents 123.45.
  FbValue(kind: fkDecimal, decVal: value, decScale: scale)

proc parseDecimal*(s: string): FbValue =
  # Parses "123.45" as an exact decimal (scale = number of decimal places).
  let t = s.strip()
  let dot = t.find('.')
  if dot < 0:
    return FbValue(kind: fkInt, intVal: parseBiggestInt(t))
  let intPart = t[0 ..< dot]
  let frac = t[dot + 1 .. ^1]
  let digits = (if intPart in ["", "-", "+"]: intPart & "0" else: intPart) & frac
  decimal(parseBiggestInt(digits), -frac.len)

# Constructors (Nim -> FbValue conversion)

proc toFb*(x: FbValue): FbValue = x
proc toFb*(x: typeof(nil)): FbValue = fbNull
proc toFb*(x: bool): FbValue = FbValue(kind: fkBool, boolVal: x)
proc toFb*(x: SomeInteger): FbValue = FbValue(kind: fkInt, intVal: int64(x))
proc toFb*(x: SomeFloat): FbValue = FbValue(kind: fkFloat, floatVal: float64(x))
proc toFb*(x: string): FbValue = FbValue(kind: fkString, strVal: x)
proc toFb*(x: openArray[byte]): FbValue =
  var s = newString(x.len)
  if x.len > 0: copyMem(addr s[0], unsafeAddr x[0], x.len)
  FbValue(kind: fkBinary, strVal: s)
proc toFb*(x: FbDate): FbValue = FbValue(kind: fkDate, dateVal: x)
proc toFb*(x: FbTime): FbValue = FbValue(kind: fkTime, timeVal: x)
proc toFb*(x: FbTimestamp): FbValue = FbValue(kind: fkTimestamp, tsVal: x)
proc toFb*(x: DateTime): FbValue = FbValue(kind: fkTimestamp, tsVal: toFbTimestamp(x))
proc toFb*(x: IscQuad): FbValue = FbValue(kind: fkBlobId, blobId: x)
proc toFb*[T](x: Option[T]): FbValue =
  if x.isSome: toFb(x.get) else: fbNull

proc binaryValue*(data: string): FbValue =
  # Binary value (BLOB SUB_TYPE 0, CHAR(n) CHARACTER SET OCTETS).
  FbValue(kind: fkBinary, strVal: data)

proc strOrBin(s: sink string, binary: bool): FbValue =
  if binary: FbValue(kind: fkBinary, strVal: s)
  else: FbValue(kind: fkString, strVal: s)

proc intOrDec(v: int64, scale: int): FbValue =
  if scale < 0: FbValue(kind: fkDecimal, decVal: v, decScale: scale)
  elif scale > 0: FbValue(kind: fkInt, intVal: v * pow10(scale))
  else: FbValue(kind: fkInt, intVal: v)

# Accessors (FbValue -> Nim)

proc isNull*(v: FbValue): bool {.inline.} = v.kind == fkNull

proc `$`*(v: FbValue): string =
  case v.kind
  of fkNull: "NULL"
  of fkBool: $v.boolVal
  of fkInt: $v.intVal
  of fkDecimal: decimalToString(v.decVal, v.decScale)
  of fkFloat: $v.floatVal
  of fkString, fkBinary: v.strVal
  of fkDate: $v.dateVal
  of fkTime: $v.timeVal
  of fkTimestamp: $v.tsVal
  of fkBlobId: "BLOB(" & $v.blobId.gds_quad_high & ":" & $v.blobId.gds_quad_low & ")"

proc convErr(v: FbValue, target: string): ref FbConversionError =
  if v.kind == fkNull:
    newException(FbConversionError, "NULL value (conversion to " & target & " impossible)")
  else:
    newException(FbConversionError, "conversion of " & $v.kind & " into " & target & " impossible")

proc asInt64*(v: FbValue): int64 =
  case v.kind
  of fkBool: int64(ord(v.boolVal))
  of fkInt: v.intVal
  of fkDecimal: v.decVal div pow10(-v.decScale)
  of fkFloat: int64(v.floatVal)
  of fkString:
    let s = v.strVal.strip()
    if '.' in s or 'e' in s or 'E' in s: int64(parseFloat(s)) else: parseBiggestInt(s)
  else: raise convErr(v, "integer")

proc asInt*(v: FbValue): int = int(v.asInt64)

proc asFloat*(v: FbValue): float64 =
  case v.kind
  of fkBool: float64(ord(v.boolVal))
  of fkInt: float64(v.intVal)
  of fkDecimal: float64(v.decVal) / float64(pow10(-v.decScale))
  of fkFloat: v.floatVal
  of fkString: parseFloat(v.strVal.strip())
  else: raise convErr(v, "float")

proc asBool*(v: FbValue): bool =
  case v.kind
  of fkBool: v.boolVal
  of fkInt: v.intVal != 0
  of fkDecimal: v.decVal != 0
  of fkFloat: v.floatVal != 0.0
  of fkString:
    case v.strVal.strip().toLowerAscii
    of "true", "t", "1", "y", "yes", "o", "oui": true
    of "false", "f", "0", "n", "no", "non", "": false
    else: raise convErr(v, "boolean")
  else: raise convErr(v, "boolean")

proc asString*(v: FbValue): string =
  if v.kind == fkNull: raise convErr(v, "string")
  $v

proc asBytes*(v: FbValue): seq[byte] =
  if v.kind notin {fkString, fkBinary}: raise convErr(v, "bytes")
  result = newSeq[byte](v.strVal.len)
  if result.len > 0: copyMem(addr result[0], unsafeAddr v.strVal[0], result.len)

proc asDate*(v: FbValue): FbDate =
  case v.kind
  of fkDate: v.dateVal
  of fkTimestamp: v.tsVal.date
  of fkString:
    let p = v.strVal.strip()[0 ..< 10].split('-')
    fbDate(parseInt(p[0]), parseInt(p[1]), parseInt(p[2]))
  else: raise convErr(v, "date")

proc asTime*(v: FbValue): FbTime =
  case v.kind
  of fkTime: v.timeVal
  of fkTimestamp: v.tsVal.time
  else: raise convErr(v, "time")

proc asTimestamp*(v: FbValue): FbTimestamp =
  case v.kind
  of fkTimestamp: v.tsVal
  of fkDate: FbTimestamp(date: v.dateVal)
  else: raise convErr(v, "timestamp")

proc asDateTime*(v: FbValue, zone: Timezone = local()): DateTime =
  v.asTimestamp.toDateTime(zone)

proc get*(v: FbValue, T: typedesc): T =
  # Conversion générique : `v.get(int)`, `v.get(Option[string])`…
  when T is FbValue: v
  elif T is Option:
    var r: T
    if not v.isNull: r = some(v.get(typeof(r.get)))
    r
  elif T is bool: v.asBool
  elif T is SomeInteger: T(v.asInt64)
  elif T is SomeFloat: T(v.asFloat)
  elif T is string: v.asString
  elif T is seq[byte]: v.asBytes
  elif T is FbDate: v.asDate
  elif T is FbTime: v.asTime
  elif T is FbTimestamp: v.asTimestamp
  elif T is DateTime: v.asDateTime
  elif T is IscQuad:
    if v.kind != fkBlobId: raise convErr(v, "BLOB identifier")
    v.blobId
  else:
    {.error: "firebird.get : unsupported type".}

# Metadata and lines

type
  ColumnInfo* = object
    name*: string        # field name.
    alias*: string       # column label (alias).
    relation*: string    # table name.
    owner*: string
    sqlType*: int        # SQL type (without the nullability bit).
    subType*: int        # subtype (BLOB) or character set (text).
    scale*: int
    length*: int         # length (in bytes).
    nullable*: bool

  StatementKind* = enum
    skUnknown, skSelect, skInsert, skUpdate, skDelete, skDDL, skGetSegment,
    skPutSegment, skExecProcedure, skStartTrans, skCommit, skRollback,
    skSelectForUpdate, skSetGenerator, skSavepoint

  RowMeta = ref object
    names: seq[string]
    index: Table[string, int]

  Row* = object
    values*: seq[FbValue]
    meta: RowMeta

proc sqlTypeName*(c: ColumnInfo): string =
  # Human-readable SQL name of a column type.
  case c.sqlType
  of SQL_TEXT: "CHAR(" & $c.length & ")"
  of SQL_VARYING: "VARCHAR(" & $c.length & ")"
  of SQL_SHORT: (if c.scale < 0: "NUMERIC(4," & $(-c.scale) & ")" else: "SMALLINT")
  of SQL_LONG: (if c.scale < 0: "NUMERIC(9," & $(-c.scale) & ")" else: "INTEGER")
  of SQL_INT64: (if c.scale < 0: "NUMERIC(18," & $(-c.scale) & ")" else: "BIGINT")
  of SQL_INT128: (if c.scale < 0: "NUMERIC(38," & $(-c.scale) & ")" else: "INT128")
  of SQL_FLOAT: "FLOAT"
  of SQL_DOUBLE, SQL_D_FLOAT: "DOUBLE PRECISION"
  of SQL_TYPE_DATE: "DATE"
  of SQL_TYPE_TIME: "TIME"
  of SQL_TIMESTAMP: "TIMESTAMP"
  of SQL_TIME_TZ, SQL_TIME_TZ_EX: "TIME WITH TIME ZONE"
  of SQL_TIMESTAMP_TZ, SQL_TIMESTAMP_TZ_EX: "TIMESTAMP WITH TIME ZONE"
  of SQL_BLOB: "BLOB SUB_TYPE " & $c.subType
  of SQL_ARRAY: "ARRAY"
  of SQL_BOOLEAN: "BOOLEAN"
  of SQL_DEC16: "DECFLOAT(16)"
  of SQL_DEC34: "DECFLOAT(34)"
  of SQL_NULL: "NULL"
  else: "TYPE(" & $c.sqlType & ")"

proc len*(r: Row): int = r.values.len
proc `[]`*(r: Row, i: int): FbValue = r.values[i]

proc `[]`*(r: Row, name: string): FbValue =
  # Access by column name (case-insensitive).
  let k = name.toUpperAscii
  if r.meta == nil or k notin r.meta.index:
    raise newException(KeyError, "unknown column : " & name)
  r.values[r.meta.index[k]]

proc contains*(r: Row, name: string): bool =
  r.meta != nil and name.toUpperAscii in r.meta.index

proc columnNames*(r: Row): seq[string] =
  if r.meta != nil: r.meta.names else: @[]

iterator pairs*(r: Row): (string, FbValue) =
  for i, v in r.values:
    yield (r.meta.names[i], v)

proc get*(r: Row, i: int, T: typedesc): T = r.values[i].get(T)
proc get*(r: Row, name: string, T: typedesc): T = r[name].get(T)

proc to*[T: object](r: Row, t: typedesc[T]): T =
  # Populates a Nim object whose fields are named after the columns.
  for name, field in fieldPairs(result):
    let k = name.toUpperAscii
    if r.meta != nil and k in r.meta.index:
      field = r.values[r.meta.index[k]].get(typeof(field))

proc `$`*(r: Row): string =
  result = "("
  for i, v in r.values:
    if i > 0: result.add ", "
    result.add r.meta.names[i] & ": " & $v
  result.add ")"

# Login and transaction options

type
  IsolationLevel* = enum
    ilConcurrency                    # SNAPSHOT.
    ilConsistency                    # SNAPSHOT TABLE STABILITY.
    ilReadCommitted                  # READ COMMITTED RECORD_VERSION.
    ilReadCommittedNoRecVersion      # READ COMMITTED NO RECORD_VERSION.
    ilReadCommittedReadConsistency   # READ COMMITTED READ CONSISTENCY (FB 4+).

  TableLockMode* = enum
    tlSharedRead, tlSharedWrite, tlProtectedRead, tlProtectedWrite,
    tlExclusiveRead, tlExclusiveWrite

  TableReservation* = object
    table*: string
    mode*: TableLockMode

  TransactionOptions* = object
    isolation*: IsolationLevel = ilReadCommitted
    readOnly*: bool
    wait*: bool = true
    lockTimeout*: int          # seconds (with `wait`), 0 = wait indefinitely.
    noAutoUndo*: bool
    ignoreLimbo*: bool
    autoCommit*: bool          # isc_tpb_autocommit (server side).
    reservations*: seq[TableReservation]

  ConnectOptions* = object
    database*: string              # "host[/port]:path", alias or local path.
    user*: string                  # empty = ISC_USER variable,
    password*: string              # empty = ISC_PASSWORD variable,
    role*: string
    charset*: string = "UTF8"
    dialect*: int = 3
    connectTimeout*: int           # secondes.
    numBuffers*: int               # page cache size for this connection.
    sessionTimeZone*: string       # FB 4+ (e.g. "Europe/Paris")
    setBind*: string               # FB 4+ (e.g. "DECFLOAT TO LEGACY;INT128 TO BIGINT")
    processName*: string
    authPlugins*: string           # e.g. "Srp256,Srp,Legacy_Auth"
    config*: string                # connection-specific firebird.conf parameters.
    noGarbageCollect*: bool
    noDbTriggers*: bool
    utf8Filename*: bool
    autoCommit*: bool = true       # automatically validates the transaction by default.
    fetchBlobs*: bool = true       # automatically loads BLOB content.
    trimChar*: bool = true         # removes padding spaces from CHAR(n).
    txOptions*: TransactionOptions # Default transaction options.

proc addByte(b: var string, x: int) {.inline.} = b.add chr(x and 0xFF)

proc addLE32(b: var string, v: int) =
  for k in 0..3: b.addByte(v shr (8 * k))

proc addStrItem(b: var string, item: int, s: string) =
  if s.len > 255:
    raise newFbError("parameter too long (item " & $item & ", 255 bytes max)")
  b.addByte item
  b.addByte s.len
  b.add s

proc addIntItem(b: var string, item: int, v: int) =
  b.addByte item
  b.addByte 4
  b.addLE32 v

proc buildDpb(o: ConnectOptions): string =
  result.addByte isc_dpb_version1
  if o.user.len > 0: result.addStrItem(isc_dpb_user_name, o.user)
  if o.password.len > 0: result.addStrItem(isc_dpb_password, o.password)
  if o.role.len > 0: result.addStrItem(isc_dpb_sql_role_name, o.role)
  if o.charset.len > 0: result.addStrItem(isc_dpb_lc_ctype, o.charset)
  result.addIntItem(isc_dpb_sql_dialect, o.dialect)
  if o.connectTimeout > 0: result.addIntItem(isc_dpb_connect_timeout, o.connectTimeout)
  if o.numBuffers > 0: result.addIntItem(isc_dpb_num_buffers, o.numBuffers)
  if o.sessionTimeZone.len > 0: result.addStrItem(isc_dpb_session_time_zone, o.sessionTimeZone)
  if o.setBind.len > 0: result.addStrItem(isc_dpb_set_bind, o.setBind)
  if o.processName.len > 0: result.addStrItem(isc_dpb_process_name, o.processName)
  if o.authPlugins.len > 0: result.addStrItem(isc_dpb_auth_plugin_list, o.authPlugins)
  if o.config.len > 0: result.addStrItem(isc_dpb_config, o.config)
  if o.noGarbageCollect: result.addStrItem(isc_dpb_no_garbage_collect, "")
  if o.noDbTriggers: result.addIntItem(isc_dpb_no_db_triggers, 1)
  if o.utf8Filename: result.addStrItem(isc_dpb_utf8_filename, "")

proc buildTpb(o: TransactionOptions): string =
  result.addByte isc_tpb_version3
  case o.isolation
  of ilConcurrency: result.addByte isc_tpb_concurrency
  of ilConsistency: result.addByte isc_tpb_consistency
  of ilReadCommitted:
    result.addByte isc_tpb_read_committed
    result.addByte isc_tpb_rec_version
  of ilReadCommittedNoRecVersion:
    result.addByte isc_tpb_read_committed
    result.addByte isc_tpb_no_rec_version
  of ilReadCommittedReadConsistency:
    result.addByte isc_tpb_read_committed
    result.addByte isc_tpb_read_consistency
  result.addByte(if o.readOnly: isc_tpb_read else: isc_tpb_write)
  if o.wait:
    result.addByte isc_tpb_wait
    if o.lockTimeout > 0: result.addIntItem(isc_tpb_lock_timeout, o.lockTimeout)
  else:
    result.addByte isc_tpb_nowait
  if o.noAutoUndo: result.addByte isc_tpb_no_auto_undo
  if o.ignoreLimbo: result.addByte isc_tpb_ignore_limbo
  if o.autoCommit: result.addByte isc_tpb_autocommit
  for r in o.reservations:
    let write = r.mode in {tlSharedWrite, tlProtectedWrite, tlExclusiveWrite}
    let lockMode =
      case r.mode
      of tlSharedRead, tlSharedWrite: isc_tpb_shared
      of tlProtectedRead, tlProtectedWrite: isc_tpb_protected
      of tlExclusiveRead, tlExclusiveWrite: isc_tpb_exclusive
    result.addStrItem(if write: isc_tpb_lock_write else: isc_tpb_lock_read, r.table)
    result.addByte lockMode

# Utilitaires internes

template offset(p: pointer, n: int): pointer = cast[pointer](cast[uint](p) + uint(n))
template load(T: typedesc, p: pointer): untyped = cast[ptr T](p)[]
template store(p: pointer, v: typed) = cast[ptr typeof(v)](p)[] = v

proc leInt(buf: string, pos, len: int): int64 =
  # Signed little-endian integer ("VAX" format for information blocks).
  if len <= 0 or pos + len > buf.len: return 0
  var r: uint64
  for k in 0 ..< min(len, 8):
    r = r or (uint64(uint8(buf[pos + k])) shl (8 * k))
  if len < 8 and (uint8(buf[pos + len - 1]) and 0x80) != 0:
    r = r or (not 0'u64 shl (8 * len))
  cast[int64](r)

proc sqlLen(sql: string): cushort =
  if sql.len > 65535: 0.cushort else: cushort(sql.len)   # 0 = NUL-terminated string.

proc quoteIdent*(ident: string): string =
  # SQL identifier enclosed in double quotes (case-sensitive).
  "\"" & ident.replace("\"", "\"\"") & "\""

proc quoteString*(s: string): string =
  # SQL literal enclosed in single quotes.
  "'" & s.replace("'", "''") & "'"

proc checkIdent(name: string) =
  if name.len == 0 or not name.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}):
    raise newFbError("Invalid identifier : " & name)

# Login and transactions

type
  # Native resources of a connection: destroyed (detached) automatically.
  ConnNative = object
    db: DbHandle
    defTr: TrHandle

  ConnectionObj = object
    native: ConnNative
    database*: string
    dialect*: int
    charset*: string
    autoCommit*: bool
    fetchBlobs*: bool
    trimChar*: bool
    txOptions*: TransactionOptions

  Connection* = ref ConnectionObj

  # Native resources of a transaction: rolled back automatically if still active.
  TrNative = object
    conn: Connection          # keeps the connection alive until the rollback
    handle: TrHandle
    isDefault: bool

  TransactionObj = object
    conn*: Connection
    native: TrNative
    options*: TransactionOptions

  Transaction* = ref TransactionObj

# Prevent accidental copies that would double-close the handle
proc `=copy`(dest: var ConnNative, src: ConnNative) {.error.}
proc `=copy`(dest: var TrNative, src: TrNative) {.error.}

proc `=destroy`(n: ConnNative) =
  if not isNull(n.db):
    var sv: StatusVector
    var tr = n.defTr
    var db = n.db
    if not isNull(tr):
      discard isc_rollback_transaction(addr sv[0], addr tr)
    discard isc_detach_database(addr sv[0], addr db)

proc `=destroy`(n: TrNative) =
  if not n.isDefault and not isNull(n.handle) and
     n.conn != nil and not isNull(n.conn.native.db):
    var sv: StatusVector
    var h = n.handle
    discard isc_rollback_transaction(addr sv[0], addr h)
  # The ref's destructor has no inferred effects: assert it cannot raise.
  {.cast(raises: []).}:
    `=destroy`(n.conn)

proc attached*(c: Connection): bool = c != nil and not isNull(c.native.db)

proc checkOpen(c: Connection) =
  if not c.attached: raise newFbError("Connection closed")

proc newConnection*(o: ConnectOptions): Connection =
  new(result)
  result.database = o.database
  result.dialect = o.dialect
  result.charset = o.charset
  result.autoCommit = o.autoCommit
  result.fetchBlobs = o.fetchBlobs
  result.trimChar = o.trimChar
  result.txOptions = o.txOptions

proc connect*(opts: ConnectOptions): Connection =
  # Opens a connection based on comprehensive options.
  result = newConnection(opts)
  let dpb = buildDpb(opts)
  var sv: StatusVector
  discard isc_attach_database(addr sv[0], cshort(opts.database.len), opts.database.cstring,
                              addr result.native.db, cshort(dpb.len), cast[pointer](dpb.cstring))
  check sv, "connection to " & opts.database

proc connect*(database: string, user = "", password = "", role = "",
              charset = "UTF8", dialect = 3): Connection =
  # Opens a connection (simplified form).
  connect(ConnectOptions(database: database, user: user, password: password,
                         role: role, charset: charset, dialect: dialect))

proc createDatabase*(opts: ConnectOptions, pageSize = 8192,
                     defaultCharset = "UTF8"): Connection =
  # Creates a new database and returns an open connection to it.
  result = newConnection(opts)
  var dpb = buildDpb(opts)
  dpb.addIntItem(isc_dpb_page_size, pageSize)
  dpb.addIntItem(isc_dpb_set_db_sql_dialect, opts.dialect)
  if defaultCharset.len > 0: dpb.addStrItem(isc_dpb_set_db_charset, defaultCharset)
  var sv: StatusVector
  discard isc_create_database(addr sv[0], cushort(opts.database.len), opts.database.cstring,
                              addr result.native.db, cushort(dpb.len), cast[pointer](dpb.cstring), 0)
  check sv, "création de " & opts.database

# Transactions

proc hptr(t: Transaction): ptr TrHandle =
  if t.native.isDefault: addr t.conn.native.defTr else: addr t.native.handle

proc active*(t: Transaction): bool = not isNull(t.hptr[])

proc startTr(c: Connection, h: ptr TrHandle, opts: TransactionOptions) =
  c.checkOpen()
  let tpb = buildTpb(opts)
  var sv: StatusVector
  discard isc_start_transaction(addr sv[0], h, 1, addr c.native.db, cint(tpb.len),
                                cast[pointer](tpb.cstring))
  check sv, "démarrage de transaction"

proc ensureActive(t: Transaction) =
  t.conn.checkOpen()
  if not t.active:
    if t.native.isDefault: t.conn.startTr(t.hptr, t.conn.txOptions)
    else: raise newFbError("transaction terminée")

proc startTransaction*(c: Connection, opts = TransactionOptions()): Transaction =
  # Starts an explicit transaction, independent of the default transaction.
  new(result)
  result.conn = c
  result.native.conn = c
  result.options = opts
  c.startTr(addr result.native.handle, opts)

proc defaultTransaction*(c: Connection): Transaction =
  # Reference to the default transaction (started on demand).
  new(result)
  result.conn = c
  result.native.conn = c
  result.native.isDefault = true
  result.options = c.txOptions

template trOp(t: Transaction, what: string, fn: untyped) =
  if t.active:
    var sv: StatusVector
    discard fn(addr sv[0], t.hptr)
    check sv, what

proc commit*(t: Transaction) =
  # Validates and completes the transaction (no effect if inactive).
  t.trOp("validation", isc_commit_transaction)

proc rollback*(t: Transaction) =
  # Cancels and terminates the transaction (no effect if inactive).
  t.trOp("annulation", isc_rollback_transaction)

proc commitRetaining*(t: Transaction) =
  # Valid while preserving the context (open cursors).
  t.trOp("validation (retaining)", isc_commit_retaining)

proc rollbackRetaining*(t: Transaction) =
  # Cancels while preserving the context.
  t.trOp("annulation (retaining)", isc_rollback_retaining)

proc prepareCommit*(t: Transaction, message = "") =
  # First phase of a two-phase commit (2PC).
  if not t.active: raise newFbError("transaction terminée")
  var sv: StatusVector
  if message.len > 0:
    discard isc_prepare_transaction2(addr sv[0], t.hptr, cushort(message.len),
                                     cast[pointer](message.cstring))
  else:
    discard isc_prepare_transaction(addr sv[0], t.hptr)
  check sv, "préparation 2PC"

proc safeRollback(t: Transaction) =
  try:
    t.rollback()
  except FbError:
    discard

proc id*(t: Transaction): int64 =
  # Server-side transaction number.
  if not t.active: raise newFbError("transaction completed")
  var req = $chr(isc_info_tra_id) & $chr(isc_info_end)
  var buf = newString(32)
  var sv: StatusVector
  discard isc_transaction_info(addr sv[0], t.hptr, cshort(req.len), addr req[0],
                               cshort(buf.len), addr buf[0])
  check sv, "isc_transaction_info"
  if uint8(buf[0]).int == isc_info_tra_id:
    result = leInt(buf, 3, int(leInt(buf, 1, 2)))

proc execImmediate*(t: Transaction, sql: string) =
  # Executes a statement directly, without parameters or results.
  t.ensureActive()
  var sv: StatusVector
  discard isc_dsql_execute_immediate(addr sv[0], addr t.conn.native.db, t.hptr, sqlLen(sql),
                                     sql.cstring, cushort(t.conn.dialect), nil)
  check sv, "immediate execution"

proc savepoint*(t: Transaction, name: string) =
  # Create a save point.
  checkIdent(name)
  t.execImmediate("SAVEPOINT " & name)

proc releaseSavepoint*(t: Transaction, name: string) =
  checkIdent(name)
  t.execImmediate("RELEASE SAVEPOINT " & name)

proc rollbackToSavepoint*(t: Transaction, name: string) =
  # Cancels the changes made since the save point.
  checkIdent(name)
  t.execImmediate("ROLLBACK TO SAVEPOINT " & name)

# Default transaction at the connection level

proc inTransaction*(c: Connection): bool = not isNull(c.native.defTr)
proc commit*(c: Connection) = c.defaultTransaction.commit()
proc rollback*(c: Connection) = c.defaultTransaction.rollback()
proc commitRetaining*(c: Connection) = c.defaultTransaction.commitRetaining()
proc rollbackRetaining*(c: Connection) = c.defaultTransaction.rollbackRetaining()
proc safeRollback(c: Connection) = c.defaultTransaction.safeRollback()

template autoTx(c: Connection, body: untyped) =
  try:
    body
    if c.autoCommit: c.commit()
  except CatchableError:
    if c.autoCommit: c.safeRollback()
    raise

template withTransaction*(c: Connection, tx: untyped, opts: TransactionOptions,
                          body: untyped) =
  # Executes `body` within an explicit transaction, committed on success, rolled back on exception.
  let tx = c.startTransaction(opts)
  try:
    body
    tx.commit()
  except CatchableError:
    tx.safeRollback()
    raise

template withTransaction*(c: Connection, tx: untyped, body: untyped) =
  withTransaction(c, tx, TransactionOptions(), body)

proc execImmediate*(c: Connection, sql: string) =
  c.autoTx: c.defaultTransaction.execImmediate(sql)

proc close*(c: Connection) =
  # Rolls back the default transaction if it is active, then disconnects.
  if not c.attached: return
  var sv: StatusVector
  if not isNull(c.native.defTr):
    discard isc_rollback_transaction(addr sv[0], addr c.native.defTr)
    c.native.defTr = default(TrHandle)
  discard isc_detach_database(addr sv[0], addr c.native.db)
  check sv, "déconnexion"
  c.native.db = default(DbHandle)

proc dropDatabase*(c: Connection) =
  # Deletes the database (the connection is then closed).
  c.checkOpen()
  var sv: StatusVector
  if not isNull(c.native.defTr):
    discard isc_rollback_transaction(addr sv[0], addr c.native.defTr)
    c.native.defTr = default(TrHandle)
  discard isc_drop_database(addr sv[0], addr c.native.db)
  check sv, "suppression de la base"
  c.native.db = default(DbHandle)

proc ping*(c: Connection) =
  # Checks that the connection is still alive (raises FbError otherwise).
  c.checkOpen()
  var sv: StatusVector
  discard fb_ping(addr sv[0], addr c.native.db)
  check sv, "ping"

proc cancelOperation*(c: Connection, option = fb_cancel_raise) =
  # Cancels the pending request on the connection (to be called from another thread).
  var sv: StatusVector
  discard fb_cancel_operation(addr sv[0], addr c.native.db, cushort(option))
  check sv, "annulation d'opération"

# BLOB

type
  BlobObj* = object
    tx: Transaction
    handle: BlobHandle
    id*: IscQuad
    eof: bool

  Blob* = ref BlobObj

# Prevent accidental copies that would double-close the handle
proc `=copy`(dest: var BlobObj, src: BlobObj) {.error.}

proc `=destroy`(b: BlobObj) =
  if not isNull(b.handle) and b.tx != nil and b.tx.conn.attached:
    var sv: StatusVector
    var h = b.handle
    discard isc_close_blob(addr sv[0], addr h)
  # The ref's destructor has no inferred effects: assert it cannot raise.
  {.cast(raises: []).}:
    `=destroy`(b.tx)

proc openBlob*(t: Transaction, id: IscQuad): Blob =
  # Opens an existing BLOB for reading.
  t.ensureActive()
  new(result)
  result.tx = t
  result.id = id
  var sv: StatusVector
  discard isc_open_blob2(addr sv[0], addr t.conn.native.db, t.hptr, addr result.handle,
                         addr result.id, 0, nil)
  check sv, "ouverture de BLOB"

proc createBlob*(t: Transaction): Blob =
  # Creates a new BLOB for writing; its identifier (`id`) can subsequently
  # be passed as a parameter (`toFb(blob.id)`) after `close`.
  t.ensureActive()
  new(result)
  result.tx = t
  var sv: StatusVector
  discard isc_create_blob2(addr sv[0], addr t.conn.native.db, t.hptr, addr result.handle,
                           addr result.id, 0, nil)
  check sv, "création de BLOB"

proc atEnd*(b: Blob): bool = b.eof

proc read*(b: Blob, size = 65536): string =
  # Reads up to `size` bytes; returns "" at the end of the BLOB.
  result = newString(size)
  var total = 0
  var sv: StatusVector
  while total < size and not b.eof:
    var got: cushort
    let want = min(size - total, 32768)
    let rc = isc_get_segment(addr sv[0], addr b.handle, addr got, cushort(want),
                             addr result[total])
    if rc == 0 or rc == isc_segment:
      total += int(got)
    elif rc == isc_segstr_eof:
      b.eof = true
    else:
      check sv, "lecture de BLOB"
  result.setLen(total)

proc readAll*(b: Blob): string =
  while not b.eof:
    result.add b.read(65536)

proc write*(b: Blob, data: string) =
  var sv: StatusVector
  var pos = 0
  while pos < data.len:
    let n = min(32768, data.len - pos)
    discard isc_put_segment(addr sv[0], addr b.handle, cushort(n),
                            offset(cast[pointer](data.cstring), pos))
    check sv, "écriture de BLOB"
    pos += n

proc close*(b: Blob) =
  if isNull(b.handle): return
  var sv: StatusVector
  discard isc_close_blob(addr sv[0], addr b.handle)
  check sv, "fermeture de BLOB"
  b.handle = default(BlobHandle)

proc cancel*(b: Blob) =
  # Abandons a BLOB currently being created.
  if isNull(b.handle): return
  var sv: StatusVector
  discard isc_cancel_blob(addr sv[0], addr b.handle)
  b.handle = default(BlobHandle)

proc length*(b: Blob): int64 =
  # Total size of the BLOB in bytes.
  var req = $chr(isc_info_blob_total_length) & $chr(isc_info_end)
  var buf = newString(32)
  var sv: StatusVector
  discard isc_blob_info(addr sv[0], addr b.handle, cshort(req.len), addr req[0],
                        cshort(buf.len), addr buf[0])
  check sv, "isc_blob_info"
  if uint8(buf[0]).int == isc_info_blob_total_length:
    result = leInt(buf, 3, int(leInt(buf, 1, 2)))

proc readBlob*(t: Transaction, id: IscQuad): string =
  # Reads an entire BLOB based on its identifier.
  let b = t.openBlob(id)
  try: result = b.readAll()
  finally: b.close()

proc writeBlob*(t: Transaction, data: string): IscQuad =
  # Creates a BLOB containing `data` and returns its identifier.
  let b = t.createBlob()
  try:
    b.write(data)
    b.close()
  except CatchableError:
    b.cancel()
    raise
  b.id

# Prepared statements

type
  # Native resources of a statement: freed automatically.
  StmtNative = object
    conn: Connection          # keeps the connection alive until the stmt is freed
    handle: StmtHandle
    outDa, inDa: ptr XSQLDA
    outBufs, inBufs: seq[pointer]

  StatementObj = object
    conn*: Connection
    native: StmtNative
    sql*: string
    kind*: StatementKind
    columns*: seq[ColumnInfo]   # result columns (original types).
    params*: seq[ColumnInfo]    # expected parameters.
    meta: RowMeta
    cursorOpen: bool
    singleton: bool
    pending: Option[Row]
    cursorTx: Transaction

  Statement* = ref StatementObj

# Prevent accidental copies that would double-close the handle
proc `=copy`(dest: var StmtNative, src: StmtNative) {.error.}

proc freeNative(n: StmtNative) =
  # DSQL_drop also closes any open cursor on the server side.
  if not isNull(n.handle) and n.conn.attached:
    var sv: StatusVector
    var h = n.handle
    discard isc_dsql_free_statement(addr sv[0], addr h, DSQL_drop)
  for p in n.outBufs: dealloc(p)
  for p in n.inBufs: dealloc(p)
  if n.outDa != nil: dealloc(n.outDa)
  if n.inDa != nil: dealloc(n.inDa)

proc `=destroy`(n: StmtNative) =
  freeNative(n)
  `=destroy`(n.outBufs)
  `=destroy`(n.inBufs)
  # The ref's destructor has no inferred effects: assert it cannot raise.
  {.cast(raises: []).}:
    `=destroy`(n.conn)        # last: freeNative still needs the connection

proc newXSQLDA(n: int): ptr XSQLDA =
  let n = max(n, 1)
  result = cast[ptr XSQLDA](alloc0(xsqldaLength(n)))
  result.version = SQLDA_VERSION1
  result.sqln = IscShort(n)

proc fixedStr(a: array[32, char], n: IscShort): string =
  let n = clamp(int(n), 0, 32)
  result = newString(n)
  for i in 0 ..< n: result[i] = a[i]

proc toColumnInfo(v: ptr XSQLVAR): ColumnInfo =
  ColumnInfo(name: fixedStr(v.sqlname, v.sqlname_length),
             alias: fixedStr(v.aliasname, v.aliasname_length),
             relation: fixedStr(v.relname, v.relname_length),
             owner: fixedStr(v.ownname, v.ownname_length),
             sqlType: int(v.sqltype) and not 1,
             subType: int(v.sqlsubtype),
             scale: int(v.sqlscale),
             length: int(v.sqllen),
             nullable: (int(v.sqltype) and 1) != 0)

proc freeInBufs(st: Statement) =
  for p in st.native.inBufs: dealloc(p)
  st.native.inBufs.setLen(0)

proc inAlloc(st: Statement, n: int): pointer =
  result = alloc0(max(n, 1))
  st.native.inBufs.add result

proc closeCursor*(st: Statement) =
  # Closes the cursor if it is open (errors ignored).
  if st.cursorOpen and not st.singleton and not isNull(st.native.handle) and st.conn.attached:
    var sv: StatusVector
    discard isc_dsql_free_statement(addr sv[0], addr st.native.handle, DSQL_close)
  st.cursorOpen = false
  st.singleton = false
  st.pending = none(Row)
  st.cursorTx = nil

proc close*(st: Statement) =
  # Frees the server-side request and the associated memory.
  st.closeCursor()
  freeNative(st.native)
  # Reset so the destructor won't free anything a second time.
  st.native.handle = default(StmtHandle)
  st.native.outDa = nil
  st.native.inDa = nil
  st.native.outBufs.setLen(0)
  st.native.inBufs.setLen(0)

proc queryKind(st: Statement): StatementKind =
  var req = $chr(isc_info_sql_stmt_type) & $chr(isc_info_end)
  var buf = newString(16)
  var sv: StatusVector
  discard isc_dsql_sql_info(addr sv[0], addr st.native.handle, cshort(req.len), addr req[0],
                            cshort(buf.len), addr buf[0])
  check sv, "isc_dsql_sql_info"
  if uint8(buf[0]).int == isc_info_sql_stmt_type:
    let v = int(leInt(buf, 3, int(leInt(buf, 1, 2))))
    if v in 0..ord(high(StatementKind)): return StatementKind(v)
  skUnknown

proc setupColumns(st: Statement) =
  st.meta = RowMeta()
  for i in 0 ..< int(st.native.outDa.sqld):
    let v = addr st.native.outDa.sqlvars[i]
    let info = toColumnInfo(v)
    st.columns.add info
    let label = if info.alias.len > 0: info.alias else: info.name
    st.meta.names.add label
    let key = label.toUpperAscii
    if key notin st.meta.index: st.meta.index[key] = i
    # Recent types (FB 4+): text conversion requested from the server.
    if info.sqlType in [SQL_INT128, SQL_DEC16, SQL_DEC34, SQL_TIME_TZ,
                        SQL_TIMESTAMP_TZ, SQL_TIME_TZ_EX, SQL_TIMESTAMP_TZ_EX]:
      v.sqltype = IscShort(SQL_VARYING or (int(v.sqltype) and 1))
      v.sqlscale = 0
      v.sqlsubtype = IscShort(CS_ASCII)
      v.sqllen = 128
    let base = int(v.sqltype) and not 1
    let size = if base == SQL_VARYING: int(v.sqllen) + 2 else: max(int(v.sqllen), 1)
    v.sqldata = alloc0(size)
    st.native.outBufs.add v.sqldata
    let ind = alloc0(sizeof(IscShort))
    st.native.outBufs.add ind
    v.sqlind = cast[ptr IscShort](ind)

proc prepare*(t: Transaction, sql: string): Statement =
  # Prepares an SQL query (positional parameters `?`).
  let c = t.conn
  t.ensureActive()
  new(result)
  result.conn = c
  result.native.conn = c
  result.sql = sql
  var sv: StatusVector
  discard isc_dsql_allocate_statement(addr sv[0], addr c.native.db, addr result.native.handle)
  check sv, "query allocation"
  result.native.outDa = newXSQLDA(20)
  discard isc_dsql_prepare(addr sv[0], t.hptr, addr result.native.handle, sqlLen(sql), sql.cstring,
                           cushort(c.dialect), result.native.outDa)
  check sv, "preparation"
  if result.native.outDa.sqld > result.native.outDa.sqln:
    let n = int(result.native.outDa.sqld)
    dealloc(result.native.outDa)
    result.native.outDa = newXSQLDA(n)
    discard isc_dsql_describe(addr sv[0], addr result.native.handle, SQLDA_VERSION1, result.native.outDa)
    check sv, "description of the resultt"
  result.native.inDa = newXSQLDA(20)
  discard isc_dsql_describe_bind(addr sv[0], addr result.native.handle, SQLDA_VERSION1, result.native.inDa)
  check sv, "description of parameters"
  if result.native.inDa.sqld > result.native.inDa.sqln:
    let n = int(result.native.inDa.sqld)
    dealloc(result.native.inDa)
    result.native.inDa = newXSQLDA(n)
    discard isc_dsql_describe_bind(addr sv[0], addr result.native.handle, SQLDA_VERSION1, result.native.inDa)
    check sv, "description of parameters"
  for i in 0 ..< int(result.native.inDa.sqld):
    result.params.add toColumnInfo(addr result.native.inDa.sqlvars[i])
  result.kind = result.queryKind()
  result.setupColumns()

proc prepare*(c: Connection, sql: string): Statement =
  # Prepares a query within the default transaction. A prepared query
  # can be executed in any transaction on the connection.
  c.defaultTransaction.prepare(sql)

proc setCursorName*(st: Statement, name: string) =
  # Names the cursor (for UPDATE … WHERE CURRENT OF name).
  var sv: StatusVector
  discard isc_dsql_set_cursor_name(addr sv[0], addr st.native.handle, name.cstring, 0)
  check sv, "nommage du curseur"

proc plan*(st: Statement, detailed = false): string =
  # Execution plan; `detailed` = detailed plan (Firebird 3+).
  let item = if detailed: isc_info_sql_explain_plan else: isc_info_sql_get_plan
  var req = $chr(item) & $chr(isc_info_end)
  var size = 2048
  while true:
    var buf = newString(size)
    var sv: StatusVector
    discard isc_dsql_sql_info(addr sv[0], addr st.native.handle, cshort(req.len), addr req[0],
                              cshort(buf.len), addr buf[0])
    check sv, "reading the plan"
    let first = uint8(buf[0]).int
    if first == isc_info_truncated and size < 32767:
      size = min(size * 4, 32767)
      continue
    if first != item: return ""
    let n = int(leInt(buf, 1, 2))
    return buf[3 ..< min(3 + n, buf.len)].strip()

proc rowsAffected*(st: Statement): int =
  # Number of rows inserted, modified, and deleted by the last execution.
  var req = $chr(isc_info_sql_records) & $chr(isc_info_end)
  var buf = newString(64)
  var sv: StatusVector
  discard isc_dsql_sql_info(addr sv[0], addr st.native.handle, cshort(req.len), addr req[0],
                            cshort(buf.len), addr buf[0])
  check sv, "isc_dsql_sql_info"
  if uint8(buf[0]).int != isc_info_sql_records: return 0
  let total = int(leInt(buf, 1, 2))
  var i = 3
  while i < 3 + total and i < buf.len:
    let item = uint8(buf[i]).int
    if item == isc_info_end: break
    let l = int(leInt(buf, i + 1, 2))
    if item in [isc_info_req_insert_count, isc_info_req_update_count,
                isc_info_req_delete_count]:
      result += int(leInt(buf, i + 3, l))
    i += 3 + l

# Parameter binding

proc bindParams(st: Statement, t: Transaction, args: openArray[FbValue]) =
  st.freeInBufs()
  if args.len != st.params.len:
    raise newFbError("incorrect number of parameter(s) : " & $st.params.len &
                     " expected, " & $args.len & " supplied")
  for i, a in args:
    let p = st.params[i]
    let x = addr st.native.inDa.sqlvars[i]
    x.sqlscale = IscShort(p.scale)
    x.sqlsubtype = IscShort(p.subType)
    let ind = cast[ptr IscShort](st.inAlloc(sizeof(IscShort)))
    ind[] = 0
    x.sqlind = ind

    template setType(tp: int, length: int) =
      x.sqltype = IscShort(tp or 1)
      x.sqllen = IscShort(length)
      x.sqldata = st.inAlloc(length + (if tp == SQL_VARYING: 2 else: 0))

    case a.kind
    of fkNull:
      ind[] = -1
      setType(p.sqlType, p.length)
    of fkBool:
      if p.sqlType == SQL_BOOLEAN:
        setType(SQL_BOOLEAN, 1)
        store(x.sqldata, uint8(ord(a.boolVal)))
      else:
        setType(SQL_INT64, 8); x.sqlscale = 0
        store(x.sqldata, int64(ord(a.boolVal)))
    of fkInt:
      setType(SQL_INT64, 8); x.sqlscale = 0
      store(x.sqldata, a.intVal)
    of fkDecimal:
      setType(SQL_INT64, 8); x.sqlscale = IscShort(a.decScale)
      store(x.sqldata, a.decVal)
    of fkFloat:
      setType(SQL_DOUBLE, 8); x.sqlscale = 0
      store(x.sqldata, a.floatVal)
    of fkString, fkBinary:
      if p.sqlType == SQL_BLOB:
        let id = t.writeBlob(a.strVal)
        setType(SQL_BLOB, 8); x.sqlscale = 0
        store(x.sqldata, id)
      else:
        if a.strVal.len > 32767:
          raise newFbError("parameter " & $(i + 1) & " : string too long (32767 bytes max)")
        setType(SQL_TEXT, a.strVal.len); x.sqlscale = 0
        x.sqlsubtype =
          if p.sqlType in [SQL_TEXT, SQL_VARYING]: IscShort(p.subType)
          elif a.kind == fkBinary: IscShort(CS_OCTETS)
          else: IscShort(CS_NONE)
        if a.strVal.len > 0:
          copyMem(x.sqldata, unsafeAddr a.strVal[0], a.strVal.len)
    of fkDate:
      setType(SQL_TYPE_DATE, 4); x.sqlscale = 0; x.sqlsubtype = 0
      store(x.sqldata, encodeDate(a.dateVal))
    of fkTime:
      setType(SQL_TYPE_TIME, 4); x.sqlscale = 0; x.sqlsubtype = 0
      store(x.sqldata, encodeTime(a.timeVal))
    of fkTimestamp:
      setType(SQL_TIMESTAMP, 8); x.sqlscale = 0; x.sqlsubtype = 0
      store(x.sqldata, IscTimestamp(timestamp_date: encodeDate(a.tsVal.date),
                                    timestamp_time: encodeTime(a.tsVal.time)))
    of fkBlobId:
      setType(SQL_BLOB, 8); x.sqlscale = 0
      store(x.sqldata, a.blobId)

# Reading the results

proc readValue(st: Statement, v: ptr XSQLVAR, t: Transaction): FbValue =
  let base = int(v.sqltype) and not 1
  if (int(v.sqltype) and 1) != 0 and v.sqlind != nil and v.sqlind[] < 0:
    return fbNull
  let p = v.sqldata
  case base
  of SQL_TEXT:
    var s = newString(int(v.sqllen))
    if s.len > 0: copyMem(addr s[0], p, s.len)
    let binary = (int(v.sqlsubtype) and 0xFF) == CS_OCTETS
    if not binary and st.conn.trimChar:
      s = s.strip(leading = false, chars = {' '})
    strOrBin(s, binary)
  of SQL_VARYING:
    let n = int(load(uint16, p))
    var s = newString(n)
    if n > 0: copyMem(addr s[0], offset(p, 2), n)
    strOrBin(s, (int(v.sqlsubtype) and 0xFF) == CS_OCTETS)
  of SQL_SHORT: intOrDec(int64(load(int16, p)), int(v.sqlscale))
  of SQL_LONG: intOrDec(int64(load(int32, p)), int(v.sqlscale))
  of SQL_INT64: intOrDec(load(int64, p), int(v.sqlscale))
  of SQL_FLOAT: FbValue(kind: fkFloat, floatVal: float64(load(float32, p)))
  of SQL_DOUBLE, SQL_D_FLOAT: FbValue(kind: fkFloat, floatVal: load(float64, p))
  of SQL_TYPE_DATE: FbValue(kind: fkDate, dateVal: decodeDate(load(IscDate, p)))
  of SQL_TYPE_TIME: FbValue(kind: fkTime, timeVal: decodeTime(load(IscTime, p)))
  of SQL_TIMESTAMP:
    let ts = load(IscTimestamp, p)
    FbValue(kind: fkTimestamp, tsVal: FbTimestamp(date: decodeDate(ts.timestamp_date),
                                                  time: decodeTime(ts.timestamp_time)))
  of SQL_BOOLEAN: FbValue(kind: fkBool, boolVal: load(uint8, p) != 0)
  of SQL_BLOB:
    let id = load(IscQuad, p)
    if st.conn.fetchBlobs:
      strOrBin(t.readBlob(id), int(v.sqlsubtype) != 1)
    else:
      FbValue(kind: fkBlobId, blobId: id)
  of SQL_ARRAY, SQL_QUAD:
    FbValue(kind: fkBlobId, blobId: load(IscQuad, p))   # arrays: identifier only.
  of SQL_NULL: fbNull
  else:
    raise newFbError("unsupported SQL type : " & $base)

proc readRow(st: Statement, t: Transaction): Row =
  result.meta = st.meta
  result.values = newSeq[FbValue](st.columns.len)
  for i in 0 ..< st.columns.len:
    result.values[i] = st.readValue(addr st.native.outDa.sqlvars[i], t)

# Execution

proc openImpl(st: Statement, t: Transaction, args: openArray[FbValue]) =
  if isNull(st.native.handle): raise newFbError("request closed")
  st.closeCursor()
  t.ensureActive()
  try:
    st.bindParams(t, args)
    let inDa = if st.params.len > 0: st.native.inDa else: nil
    var sv: StatusVector
    if st.kind in {skSelect, skSelectForUpdate} and st.columns.len > 0:
      discard isc_dsql_execute(addr sv[0], t.hptr, addr st.native.handle, SQLDA_VERSION1, inDa)
      check sv, "execution"
      st.cursorOpen = true
      st.singleton = false
    elif st.columns.len > 0:
      # EXECUTE PROCEDURE, INSERT/UPDATE … RETURNING : une seule ligne
      discard isc_dsql_execute2(addr sv[0], t.hptr, addr st.native.handle, SQLDA_VERSION1,
                                inDa, st.native.outDa)
      check sv, "execution"
      st.cursorOpen = true
      st.singleton = true
      st.pending = some(st.readRow(t))
    else:
      discard isc_dsql_execute(addr sv[0], t.hptr, addr st.native.handle, SQLDA_VERSION1, inDa)
      check sv, "execution"
      st.cursorOpen = true
      st.singleton = true
    st.cursorTx = t
  finally:
    st.freeInBufs()

proc open*(st: Statement, t: Transaction, args: varargs[FbValue, toFb]) =
  # Executes the query and opens the cursor; then read using `fetch`.
  st.openImpl(t, args)

proc fetch*(st: Statement): Option[Row] =
  # Next line of the open cursor, or `none` at the end of the result.
  if not st.cursorOpen: return none(Row)
  if st.singleton:
    result = st.pending
    st.pending = none(Row)
    if result.isNone: st.closeCursor()
    return
  var sv: StatusVector
  let rc = isc_dsql_fetch(addr sv[0], addr st.native.handle, SQLDA_VERSION1, st.native.outDa)
  if rc == 100:
    st.closeCursor()
    return none(Row)
  check sv, "lecture du curseur"
  some(st.readRow(st.cursorTx))

proc execImpl(st: Statement, t: Transaction, args: openArray[FbValue]): int =
  st.openImpl(t, args)
  try: result = st.rowsAffected()
  finally: st.closeCursor()

proc queryImpl(st: Statement, t: Transaction, args: openArray[FbValue]): seq[Row] =
  st.openImpl(t, args)
  try:
    while true:
      let r = st.fetch()
      if r.isNone: break
      result.add r.get
  finally:
    st.closeCursor()

proc exec*(st: Statement, t: Transaction, args: varargs[FbValue, toFb]): int =
  # Executes within transaction `t`; returns the number of affected rows.
  st.execImpl(t, args)

proc query*(st: Statement, t: Transaction, args: varargs[FbValue, toFb]): seq[Row] =
  st.queryImpl(t, args)

proc executeMany*(st: Statement, t: Transaction, rows: openArray[seq[FbValue]]): int =
  # Executes the query for each set of parameters; total number of affected rows.
  for r in rows: result += st.execImpl(t, r)

iterator rows*(st: Statement, t: Transaction, args: varargs[FbValue, toFb]): Row =
  st.openImpl(t, args)
  try:
    while true:
      let r = st.fetch()
      if r.isNone: break
      yield r.get
  finally:
    st.closeCursor()

# Variants using the default transaction (with optional auto-commit)

proc exec*(st: Statement, args: varargs[FbValue, toFb]): int =
  let c = st.conn
  c.autoTx: result = st.execImpl(c.defaultTransaction, args)

proc query*(st: Statement, args: varargs[FbValue, toFb]): seq[Row] =
  let c = st.conn
  c.autoTx: result = st.queryImpl(c.defaultTransaction, args)

proc executeMany*(st: Statement, rows: openArray[seq[FbValue]]): int =
  let c = st.conn
  c.autoTx: result = st.executeMany(c.defaultTransaction, rows)

# API : explicit transaction

proc execImpl(t: Transaction, sql: string, args: openArray[FbValue]): int =
  let st = t.prepare(sql)
  try: result = st.execImpl(t, args)
  finally: st.close()

proc queryImpl(t: Transaction, sql: string, args: openArray[FbValue]): seq[Row] =
  let st = t.prepare(sql)
  try: result = st.queryImpl(t, args)
  finally: st.close()

proc getRowImpl(t: Transaction, sql: string, args: openArray[FbValue]): Option[Row] =
  let st = t.prepare(sql)
  try:
    st.openImpl(t, args)
    result = st.fetch()
  finally:
    st.close()

proc exec*(t: Transaction, sql: string, args: varargs[FbValue, toFb]): int =
  # Executes a statement; returns the number of affected rows.
  execImpl(t, sql, args)

proc query*(t: Transaction, sql: string, args: varargs[FbValue, toFb]): seq[Row] =
  # EExecutes a query and returns all rows.
  queryImpl(t, sql, args)

proc getRow*(t: Transaction, sql: string, args: varargs[FbValue, toFb]): Option[Row] =
  # First row of the result (or `none`).
  getRowImpl(t, sql, args)

proc getValue*(t: Transaction, sql: string, args: varargs[FbValue, toFb]): FbValue =
  # First column of the first row (NULL if no row).
  let r = getRowImpl(t, sql, args)
  if r.isSome and r.get.len > 0: r.get[0] else: fbNull

iterator rows*(t: Transaction, sql: string, args: varargs[FbValue, toFb]): Row =
  let st = t.prepare(sql)
  try:
    st.openImpl(t, args)
    while true:
      let r = st.fetch()
      if r.isNone: break
      yield r.get
  finally:
    st.close()

# API : connection default transaction

proc exec*(c: Connection, sql: string, args: varargs[FbValue, toFb]): int =
  c.autoTx: result = execImpl(c.defaultTransaction, sql, args)

proc query*(c: Connection, sql: string, args: varargs[FbValue, toFb]): seq[Row] =
  c.autoTx: result = queryImpl(c.defaultTransaction, sql, args)

proc getRow*(c: Connection, sql: string, args: varargs[FbValue, toFb]): Option[Row] =
  c.autoTx: result = getRowImpl(c.defaultTransaction, sql, args)

proc getValue*(c: Connection, sql: string, args: varargs[FbValue, toFb]): FbValue =
  var r: Option[Row]
  c.autoTx: r = getRowImpl(c.defaultTransaction, sql, args)
  if r.isSome and r.get.len > 0: r.get[0] else: fbNull

iterator rows*(c: Connection, sql: string, args: varargs[FbValue, toFb]): Row =
  # Iterate row by row. In auto-commit mode, the commit occurs at the
  # end of the iteration: do not execute any other statement on the default
  # transaction inside the loop (use an explicit transaction).
  let t = c.defaultTransaction
  var st: Statement
  var failed = false
  try:
    st = t.prepare(sql)
    st.openImpl(t, args)
    while true:
      let r = st.fetch()
      if r.isNone: break
      yield r.get
  except CatchableError:
    failed = true
    raise
  finally:
    if st != nil: st.close()
    if c.autoCommit:
      if failed: c.safeRollback() else: c.commit()

proc tableNames*(c: Connection, includeSystem = false): seq[string] =
  # List of tables (excluding views).
  var sql = "SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS WHERE RDB$VIEW_BLR IS NULL"
  if not includeSystem: sql.add " AND COALESCE(RDB$SYSTEM_FLAG, 0) = 0"
  sql.add " ORDER BY 1"
  for r in c.query(sql): result.add r[0].asString

# Information

type
  DatabaseInfo* = object
    pageSize*: int
    odsVersion*, odsMinorVersion*: int
    sqlDialect*: int
    readOnly*: bool
    forcedWrites*: bool
    sweepInterval*: int
    attachmentId*: int64
    numBuffers*: int
    pagesAllocated*: int64
    oldestTransaction*, oldestActive*, oldestSnapshot*, nextTransaction*: int64
    serverVersion*: string

proc info*(c: Connection): DatabaseInfo =
  # General information about the database and the server.
  c.checkOpen()
  var req = ""
  for item in [isc_info_page_size, isc_info_ods_version, isc_info_ods_minor_version,
               isc_info_db_sql_dialect, isc_info_db_read_only, isc_info_forced_writes,
               isc_info_sweep_interval, isc_info_attachment_id, isc_info_num_buffers,
               isc_info_allocation, isc_info_oldest_transaction, isc_info_oldest_active,
               isc_info_oldest_snapshot, isc_info_next_transaction,
               isc_info_firebird_version, isc_info_end]:
    req.addByte item
  var buf = newString(2048)
  var sv: StatusVector
  discard isc_database_info(addr sv[0], addr c.native.db, cshort(req.len), addr req[0],
                            cshort(buf.len), addr buf[0])
  check sv, "isc_database_info"
  var i = 0
  while i + 3 <= buf.len:
    let item = uint8(buf[i]).int
    if item == isc_info_end or item == isc_info_truncated: break
    let l = int(leInt(buf, i + 1, 2))
    let p = i + 3
    if item == isc_info_firebird_version:
      if l > 1:
        let sl = uint8(buf[p + 1]).int
        result.serverVersion = buf[p + 2 ..< min(p + 2 + sl, buf.len)]
    elif item != isc_info_error:
      let v = leInt(buf, p, l)
      case item
      of isc_info_page_size: result.pageSize = int(v)
      of isc_info_ods_version: result.odsVersion = int(v)
      of isc_info_ods_minor_version: result.odsMinorVersion = int(v)
      of isc_info_db_sql_dialect: result.sqlDialect = int(v)
      of isc_info_db_read_only: result.readOnly = v != 0
      of isc_info_forced_writes: result.forcedWrites = v != 0
      of isc_info_sweep_interval: result.sweepInterval = int(v)
      of isc_info_attachment_id: result.attachmentId = v
      of isc_info_num_buffers: result.numBuffers = int(v)
      of isc_info_allocation: result.pagesAllocated = v
      of isc_info_oldest_transaction: result.oldestTransaction = v
      of isc_info_oldest_active: result.oldestActive = v
      of isc_info_oldest_snapshot: result.oldestSnapshot = v
      of isc_info_next_transaction: result.nextTransaction = v
      else: discard
    i = p + l

proc serverVersion*(c: Connection): string = c.info.serverVersion

proc clientVersion*(): string =
  # Loaded version of the libfbclient library.
  var buf = newString(256)
  isc_get_client_version(buf.cstring)
  $buf.cstring

proc clientMajorVersion*(): int = int(isc_get_client_major_version())
proc clientMinorVersion*(): int = int(isc_get_client_minor_version())

# Events (POST_EVENT)

type
  EventListener* = ref object
    conn: Connection
    names*: seq[string]
    evBuf, resBuf: string

proc newEventListener*(c: Connection, names: openArray[string]): EventListener =
  # Prepares to listen for 1 to 15 events. `wait` is blocking: preferably use a dedicated connection.
  if names.len == 0 or names.len > 15:
    raise newFbError("requires between 1 and 15 event names.")
  result = EventListener(conn: c, names: @names)
  result.evBuf.addByte EPB_version1
  for n in names:
    if n.len == 0 or n.len > 255: raise newFbError("invalid event name : " & n)
    result.evBuf.addByte n.len
    result.evBuf.add n
    result.evBuf.add "\0\0\0\0"
  result.resBuf = newString(result.evBuf.len)

proc wait*(el: EventListener): Table[string, int] =
  # Blocks until at least one event is received; returns, for each name,
  # the number of occurrences since the previous call.
  # The first call may return immediately (initial counter synchronization).
  el.conn.checkOpen()
  var sv: StatusVector
  discard isc_wait_for_event(addr sv[0], addr el.conn.native.db, cshort(el.evBuf.len),
                             addr el.evBuf[0], addr el.resBuf[0])
  check sv, "waiting for event"
  var counts: array[20, IscULong]
  isc_event_counts(addr counts[0], cshort(el.evBuf.len), addr el.evBuf[0],
                   addr el.resBuf[0])
  for i, n in el.names:
    result[n] = int(counts[i])
