# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Low-level FFI bindings to the Firebird client library (libfbclient).
#
# This module exposes the "legacy" C API (ISC) declared in `ibase.h`,
# available in all Firebird versions (2.5, 3, 4, 5).
#
# The library name can be specified at compile time:
# > nim c -d:fbClientLib=/opt/firebird/lib/libfbclient.so.2 monprog.nim

const fbClientLib* {.strdefine.} = ""

const fbLib* =
  when fbClientLib.len > 0: fbClientLib
  elif defined(windows): "winOS/fbclient.dll"
  elif defined(macosx): "macOS/libfbclient.dylib"
  else: "linOS/libfbclient.so(|.2|.3|.4|.5)"

# On Windows, ISC_EXPORT functions use __stdcall; variadic functions (ISC_EXPORT_VARARG) always use __cdecl.
when defined(windows):
  {.pragma: fbapi, importc, dynlib: fbLib, stdcall.}
else:
  {.pragma: fbapi, importc, dynlib: fbLib, cdecl.}
{.pragma: fbvararg, importc, dynlib: fbLib, cdecl, varargs.}

# Basic types

type
  IscStatus* = int    # intptr_t.
  IscLong* = int32
  IscULong* = uint32
  IscShort* = int16
  IscUShort* = uint16
  IscInt64* = int64
  IscDate* = int32
  IscTime* = uint32

when sizeof(pointer) == 8:
  type FbApiHandle* = uint32    # FB_API_HANDLE (32-bit on 64-bit platforms).
else:
  type FbApiHandle* = pointer

type
  DbHandle* = FbApiHandle
  TrHandle* = FbApiHandle
  StmtHandle* = FbApiHandle
  BlobHandle* = FbApiHandle

  IscQuad* {.bycopy.} = object
    gds_quad_high*: IscLong
    gds_quad_low*: IscULong

  IscTimestamp* {.bycopy.} = object
    timestamp_date*: IscDate
    timestamp_time*: IscTime

  StatusVector* = array[20, IscStatus]    # ISC_STATUS_ARRAY.

  XSQLVAR* {.bycopy.} = object
    sqltype*: IscShort
    sqlscale*: IscShort
    sqlsubtype*: IscShort
    sqllen*: IscShort
    sqldata*: pointer
    sqlind*: ptr IscShort
    sqlname_length*: IscShort
    sqlname*: array[32, char]
    relname_length*: IscShort
    relname*: array[32, char]
    ownname_length*: IscShort
    ownname*: array[32, char]
    aliasname_length*: IscShort
    aliasname*: array[32, char]

  XSQLDA* {.bycopy.} = object
    version*: IscShort
    sqldaid*: array[8, char]
    sqldabc*: IscLong
    sqln*: IscShort
    sqld*: IscShort
    sqlvar*: array[1, XSQLVAR]    # variable-length array (XSQLDA_LENGTH).

  IscEventCallback* = proc (userData: pointer, length: IscUShort,
                            updated: ptr uint8) {.cdecl.}

template isNull*(h: FbApiHandle): bool =
  when FbApiHandle is pointer: h == nil
  else: h == 0

# Constants

const
  SQLDA_VERSION1* = 1
  SQL_DIALECT_V5* = 1
  SQL_DIALECT_V6* = 3
  SQL_DIALECT_CURRENT* = 3

  # SQL types (bit 0 indicates nullability).
  SQL_TEXT* = 452
  SQL_VARYING* = 448
  SQL_SHORT* = 500
  SQL_LONG* = 496
  SQL_FLOAT* = 482
  SQL_DOUBLE* = 480
  SQL_D_FLOAT* = 530
  SQL_TIMESTAMP* = 510
  SQL_BLOB* = 520
  SQL_ARRAY* = 540
  SQL_QUAD* = 550
  SQL_TYPE_TIME* = 560
  SQL_TYPE_DATE* = 570
  SQL_INT64* = 580
  SQL_TIMESTAMP_TZ_EX* = 32748
  SQL_TIME_TZ_EX* = 32750
  SQL_INT128* = 32752
  SQL_TIMESTAMP_TZ* = 32754
  SQL_TIME_TZ* = 32756
  SQL_DEC16* = 32760
  SQL_DEC34* = 32762
  SQL_BOOLEAN* = 32764
  SQL_NULL* = 32766

  # Common character sets (least significant byte of sqlsubtype).
  CS_NONE* = 0
  CS_OCTETS* = 1
  CS_ASCII* = 2
  CS_UNICODE_FSS* = 3
  CS_UTF8* = 4

  # isc_dsql_free_statement.
  DSQL_close* = 1
  DSQL_drop* = 2
  DSQL_unprepare* = 4

  # Codes d'erreur particuliers.
  isc_segment* = 335544366
  isc_segstr_eof* = 335544367

  # fb_cancel_operation.
  fb_cancel_disable* = 1
  fb_cancel_enable* = 2
  fb_cancel_raise* = 3
  fb_cancel_abort* = 4

  # Database Parameter Block.
  isc_dpb_version1* = 1
  isc_dpb_page_size* = 4
  isc_dpb_num_buffers* = 5
  isc_dpb_no_garbage_collect* = 16
  isc_dpb_sweep_interval* = 22
  isc_dpb_force_write* = 24
  isc_dpb_user_name* = 28
  isc_dpb_password* = 29
  isc_dpb_lc_ctype* = 48
  isc_dpb_connect_timeout* = 57
  isc_dpb_dummy_packet_interval* = 58
  isc_dpb_sql_role_name* = 60
  isc_dpb_set_page_buffers* = 61
  isc_dpb_sql_dialect* = 63
  isc_dpb_set_db_readonly* = 64
  isc_dpb_set_db_sql_dialect* = 65
  isc_dpb_set_db_charset* = 68
  isc_dpb_process_id* = 71
  isc_dpb_no_db_triggers* = 72
  isc_dpb_process_name* = 74
  isc_dpb_utf8_filename* = 77
  isc_dpb_auth_plugin_list* = 85
  isc_dpb_config* = 87
  isc_dpb_nolinger* = 88
  isc_dpb_session_time_zone* = 91
  isc_dpb_set_bind* = 93
  isc_dpb_decfloat_round* = 94
  isc_dpb_decfloat_traps* = 95

  # Transaction Parameter Block.
  isc_tpb_version3* = 3
  isc_tpb_consistency* = 1
  isc_tpb_concurrency* = 2
  isc_tpb_shared* = 3
  isc_tpb_protected* = 4
  isc_tpb_exclusive* = 5
  isc_tpb_wait* = 6
  isc_tpb_nowait* = 7
  isc_tpb_read* = 8
  isc_tpb_write* = 9
  isc_tpb_lock_read* = 10
  isc_tpb_lock_write* = 11
  isc_tpb_verb_time* = 12
  isc_tpb_commit_time* = 13
  isc_tpb_ignore_limbo* = 14
  isc_tpb_read_committed* = 15
  isc_tpb_autocommit* = 16
  isc_tpb_rec_version* = 17
  isc_tpb_no_rec_version* = 18
  isc_tpb_restart_requests* = 19
  isc_tpb_no_auto_undo* = 20
  isc_tpb_lock_timeout* = 21
  isc_tpb_read_consistency* = 22

  # Blob Parameter Block.
  isc_bpb_version1* = 1
  isc_bpb_source_type* = 1
  isc_bpb_target_type* = 2
  isc_bpb_type* = 3
  isc_bpb_type_segmented* = 0
  isc_bpb_type_stream* = 1

  # Éléments d'information génériques.
  isc_info_end* = 1
  isc_info_truncated* = 2
  isc_info_error* = 3

  # isc_database_info.
  isc_info_db_id* = 4
  isc_info_reads* = 5
  isc_info_writes* = 6
  isc_info_fetches* = 7
  isc_info_marks* = 8
  isc_info_implementation* = 11
  isc_info_isc_version* = 12
  isc_info_page_size* = 14
  isc_info_num_buffers* = 15
  isc_info_current_memory* = 17
  isc_info_max_memory* = 18
  isc_info_allocation* = 21
  isc_info_attachment_id* = 22
  isc_info_sweep_interval* = 31
  isc_info_ods_version* = 32
  isc_info_ods_minor_version* = 33
  isc_info_forced_writes* = 52
  isc_info_db_sql_dialect* = 62
  isc_info_db_read_only* = 63
  isc_info_db_size_in_pages* = 64
  isc_info_firebird_version* = 103
  isc_info_oldest_transaction* = 104
  isc_info_oldest_active* = 105
  isc_info_oldest_snapshot* = 106
  isc_info_next_transaction* = 107

  # isc_transaction_info.
  isc_info_tra_id* = 4

  # isc_blob_info.
  isc_info_blob_num_segments* = 4
  isc_info_blob_max_segment* = 5
  isc_info_blob_total_length* = 6
  isc_info_blob_type* = 7

  # isc_dsql_sql_info.
  isc_info_req_select_count* = 13
  isc_info_req_insert_count* = 14
  isc_info_req_update_count* = 15
  isc_info_req_delete_count* = 16
  isc_info_sql_select* = 4
  isc_info_sql_bind* = 5
  isc_info_sql_stmt_type* = 21
  isc_info_sql_get_plan* = 22
  isc_info_sql_records* = 23
  isc_info_sql_explain_plan* = 26   # Firebird 3+.

  # Instruction types (isc_info_sql_stmt_type).
  isc_info_sql_stmt_select* = 1
  isc_info_sql_stmt_insert* = 2
  isc_info_sql_stmt_update* = 3
  isc_info_sql_stmt_delete* = 4
  isc_info_sql_stmt_ddl* = 5
  isc_info_sql_stmt_get_segment* = 6
  isc_info_sql_stmt_put_segment* = 7
  isc_info_sql_stmt_exec_procedure* = 8
  isc_info_sql_stmt_start_trans* = 9
  isc_info_sql_stmt_commit* = 10
  isc_info_sql_stmt_rollback* = 11
  isc_info_sql_stmt_select_for_upd* = 12
  isc_info_sql_stmt_set_generator* = 13
  isc_info_sql_stmt_savepoint* = 14

  # Events.
  EPB_version1* = 1

# Connection / Database

proc isc_attach_database*(status: ptr IscStatus, nameLen: cshort, dbName: cstring,
                          db: ptr DbHandle, dpbLen: cshort, dpb: pointer): IscStatus {.fbapi.}
proc isc_create_database*(status: ptr IscStatus, nameLen: cushort, dbName: cstring,
                          db: ptr DbHandle, dpbLen: cushort, dpb: pointer,
                          dbType: cushort): IscStatus {.fbapi.}
proc isc_detach_database*(status: ptr IscStatus, db: ptr DbHandle): IscStatus {.fbapi.}
proc isc_drop_database*(status: ptr IscStatus, db: ptr DbHandle): IscStatus {.fbapi.}
proc isc_database_info*(status: ptr IscStatus, db: ptr DbHandle, itemLen: cshort,
                        items: pointer, bufLen: cshort, buffer: pointer): IscStatus {.fbapi.}
proc fb_ping*(status: ptr IscStatus, db: ptr DbHandle): IscStatus {.fbapi.}
proc fb_cancel_operation*(status: ptr IscStatus, db: ptr DbHandle,
                          option: cushort): IscStatus {.fbapi.}

# Transactions

proc isc_start_transaction*(status: ptr IscStatus, tr: ptr TrHandle,
                            count: cshort): IscStatus {.fbvararg.}
proc isc_commit_transaction*(status: ptr IscStatus, tr: ptr TrHandle): IscStatus {.fbapi.}
proc isc_commit_retaining*(status: ptr IscStatus, tr: ptr TrHandle): IscStatus {.fbapi.}
proc isc_rollback_transaction*(status: ptr IscStatus, tr: ptr TrHandle): IscStatus {.fbapi.}
proc isc_rollback_retaining*(status: ptr IscStatus, tr: ptr TrHandle): IscStatus {.fbapi.}
proc isc_prepare_transaction*(status: ptr IscStatus, tr: ptr TrHandle): IscStatus {.fbapi.}
proc isc_prepare_transaction2*(status: ptr IscStatus, tr: ptr TrHandle, msgLen: cushort,
                               msg: pointer): IscStatus {.fbapi.}
proc isc_transaction_info*(status: ptr IscStatus, tr: ptr TrHandle, itemLen: cshort,
                           items: pointer, bufLen: cshort, buffer: pointer): IscStatus {.fbapi.}

# DSQL

proc isc_dsql_allocate_statement*(status: ptr IscStatus, db: ptr DbHandle,
                                  stmt: ptr StmtHandle): IscStatus {.fbapi.}
proc isc_dsql_prepare*(status: ptr IscStatus, tr: ptr TrHandle, stmt: ptr StmtHandle,
                       length: cushort, sql: cstring, dialect: cushort,
                       sqlda: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_describe*(status: ptr IscStatus, stmt: ptr StmtHandle, daVersion: cushort,
                        sqlda: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_describe_bind*(status: ptr IscStatus, stmt: ptr StmtHandle, daVersion: cushort,
                             sqlda: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_execute*(status: ptr IscStatus, tr: ptr TrHandle, stmt: ptr StmtHandle,
                       daVersion: cushort, sqlda: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_execute2*(status: ptr IscStatus, tr: ptr TrHandle, stmt: ptr StmtHandle,
                        daVersion: cushort, inDa: ptr XSQLDA,
                        outDa: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_execute_immediate*(status: ptr IscStatus, db: ptr DbHandle, tr: ptr TrHandle,
                                 length: cushort, sql: cstring, dialect: cushort,
                                 sqlda: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_exec_immed2*(status: ptr IscStatus, db: ptr DbHandle, tr: ptr TrHandle,
                           length: cushort, sql: cstring, dialect: cushort,
                           inDa: ptr XSQLDA, outDa: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_fetch*(status: ptr IscStatus, stmt: ptr StmtHandle, daVersion: cushort,
                     sqlda: ptr XSQLDA): IscStatus {.fbapi.}
proc isc_dsql_free_statement*(status: ptr IscStatus, stmt: ptr StmtHandle,
                              option: cushort): IscStatus {.fbapi.}
proc isc_dsql_set_cursor_name*(status: ptr IscStatus, stmt: ptr StmtHandle,
                               name: cstring, typ: cushort): IscStatus {.fbapi.}
proc isc_dsql_sql_info*(status: ptr IscStatus, stmt: ptr StmtHandle, itemLen: cshort,
                        items: pointer, bufLen: cshort, buffer: pointer): IscStatus {.fbapi.}

# BLOB

proc isc_create_blob2*(status: ptr IscStatus, db: ptr DbHandle, tr: ptr TrHandle,
                       blob: ptr BlobHandle, blobId: ptr IscQuad, bpbLen: cshort,
                       bpb: pointer): IscStatus {.fbapi.}
proc isc_open_blob2*(status: ptr IscStatus, db: ptr DbHandle, tr: ptr TrHandle,
                     blob: ptr BlobHandle, blobId: ptr IscQuad, bpbLen: cushort,
                     bpb: pointer): IscStatus {.fbapi.}
proc isc_get_segment*(status: ptr IscStatus, blob: ptr BlobHandle, actualLen: ptr cushort,
                      bufLen: cushort, buffer: pointer): IscStatus {.fbapi.}
proc isc_put_segment*(status: ptr IscStatus, blob: ptr BlobHandle, bufLen: cushort,
                      buffer: pointer): IscStatus {.fbapi.}
proc isc_close_blob*(status: ptr IscStatus, blob: ptr BlobHandle): IscStatus {.fbapi.}
proc isc_cancel_blob*(status: ptr IscStatus, blob: ptr BlobHandle): IscStatus {.fbapi.}
proc isc_blob_info*(status: ptr IscStatus, blob: ptr BlobHandle, itemLen: cshort,
                    items: pointer, bufLen: cshort, buffer: pointer): IscStatus {.fbapi.}

# Events

proc isc_wait_for_event*(status: ptr IscStatus, db: ptr DbHandle, length: cshort,
                         eventBuf: pointer, resultBuf: pointer): IscStatus {.fbapi.}
proc isc_event_counts*(counts: ptr IscULong, length: cshort, eventBuf: pointer,
                       resultBuf: pointer) {.fbapi.}
proc isc_que_events*(status: ptr IscStatus, db: ptr DbHandle, eventId: ptr IscLong,
                     length: cshort, eventBuf: pointer, callback: IscEventCallback,
                     userData: pointer): IscStatus {.fbapi.}
proc isc_cancel_events*(status: ptr IscStatus, db: ptr DbHandle,
                        eventId: ptr IscLong): IscStatus {.fbapi.}

# Errors and utilities

proc fb_interpret*(buffer: cstring, bufLen: cuint,
                   vector: ptr ptr IscStatus): IscLong {.fbapi.}
proc isc_sqlcode*(vector: ptr IscStatus): IscLong {.fbapi.}
proc fb_sqlstate*(buffer: cstring, vector: ptr IscStatus) {.fbapi.}
proc isc_sql_interprete*(sqlcode: cshort, buffer: cstring, bufLen: cshort) {.fbapi.}
proc isc_vax_integer*(buffer: pointer, length: cshort): IscLong {.fbapi.}
proc isc_portable_integer*(buffer: pointer, length: cshort): IscInt64 {.fbapi.}
proc isc_get_client_version*(buffer: cstring) {.fbapi.}
proc isc_get_client_major_version*(): cint {.fbapi.}
proc isc_get_client_minor_version*(): cint {.fbapi.}

# XSQLDA

proc xsqldaLength*(n: int): int =
  sizeof(XSQLDA) + (max(n, 1) - 1) * sizeof(XSQLVAR)

template sqlvars*(da: ptr XSQLDA): ptr UncheckedArray[XSQLVAR] =
  cast[ptr UncheckedArray[XSQLVAR]](addr da.sqlvar[0])
