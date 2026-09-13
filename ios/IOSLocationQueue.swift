import Foundation
import SQLite3
import UIKit

// Bound strings are copied by SQLite. SQLITE_STATIC (nil) would keep pointers into temporary
// NSStrings that Swift is free to release before sqlite3_step reads them.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
// Apple's SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION, spelled out so the build does
// not depend on the SDK header exposing it. SQLite applies the class to the -wal and -shm files as well,
// so the queue stays writable while the device is locked, once it has been unlocked after boot.
private let openFileProtection:Int32 = 0x00300000

struct EnqueueResult { var stored=0; var dropped=0; var failed=false }

final class IOSLocationQueue {
  // One connection per process: the engine and the background uploader both acknowledge rows,
  // and the uploader does so from a delegate queue in a possibly relaunched app.
  static let shared = IOSLocationQueue()
  struct Row { let id:Int64; let payload:[String:Any] }
  private var db:OpaquePointer?
  // The connection is touched from the main thread (Core Location), the URLSession delegate queue
  // (upload acknowledgements) and the React Native module queue. Apple's libsqlite3 is built in
  // multi-thread mode, where one connection must never be used by two threads at once; doing so
  // corrupts it and crashes inside sqlite3_prepare. Every access below happens on this serial queue.
  private let q=DispatchQueue(label:"com.greinchville.rn-background-location.sqlite")
  private let url:URL
  // Row count kept in step with every write, so the per-fix threshold check is not a table scan.
  private var cachedCount=0
  // Set when SQLite reports an error that reopening can cure (the file became unreadable, typically
  // before first unlock). The handle is closed at the end of the operation and reopened lazily.
  private var broken=false
  // Fixes that arrived while the database could not be opened, e.g. a relaunch after a reboot before
  // the user unlocked. Bounded, and flushed ahead of newer rows on the next successful open.
  private var pending:[(uuid:String,json:String)]=[]
  private static let pendingLimit=500
  private var lastCap=10000
  private var carriedDrops=0

  init(){
    url=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("rn_bg_location.sqlite")
    q.sync{ _ = ensureOpen() }
    NotificationCenter.default.addObserver(forName:UIApplication.protectedDataDidBecomeAvailableNotification,object:nil,queue:nil){[weak self]_ in
      self?.q.async{ _ = self?.withDB((),{}) }
    }
  }
  deinit{sqlite3_close(db)}

  func enqueue(_ payloads:[[String:Any]],max cap:Int)->EnqueueResult{
    let rows:[(uuid:String,json:String)]=payloads.compactMap{p in
      guard let uuid=p["id"] as? String,let d=try? JSONSerialization.data(withJSONObject:p),let s=String(data:d,encoding:.utf8) else{return nil}
      return (uuid,s)
    }
    guard !rows.isEmpty else{return EnqueueResult()}
    return q.sync{
      lastCap=Swift.max(cap,1)
      var r=withDB(buffer(rows)){ let r=insert(rows,lastCap);return r.failed ? buffer(rows) : r }
      r.dropped+=carriedDrops;carriedDrops=0
      return r
    }
  }
  func peek(limit:Int)->[Row]{q.sync{withDB([]){
    var out:[Row]=[];var st:OpaquePointer?
    guard check(sqlite3_prepare_v2(db,"SELECT id,payload FROM queue ORDER BY id ASC LIMIT ?",-1,&st,nil)) else{sqlite3_finalize(st);return out}
    sqlite3_bind_int(st,1,Int32(limit))
    var rc=sqlite3_step(st)
    while rc==SQLITE_ROW {let id=sqlite3_column_int64(st,0);if let c=sqlite3_column_text(st,1),let d=String(cString:c).data(using:.utf8),let o=try? JSONSerialization.jsonObject(with:d) as? [String:Any]{out.append(Row(id:id,payload:o))};rc=sqlite3_step(st)}
    _ = check(rc==SQLITE_DONE ? SQLITE_OK : rc)
    sqlite3_finalize(st);return out
  }}}
  func deleteThrough(_ id:Int64){q.sync{withDB((),{
    var st:OpaquePointer?;defer{sqlite3_finalize(st)}
    guard check(sqlite3_prepare_v2(db,"DELETE FROM queue WHERE id<=?",-1,&st,nil)) else{return}
    sqlite3_bind_int64(st,1,id)
    if check(sqlite3_step(st)==SQLITE_DONE ? SQLITE_OK : sqlite3_errcode(db)) {cachedCount=Swift.max(cachedCount-Int(sqlite3_changes(db)),0)}
  })}}
  // Includes rows held in memory while storage is unavailable: they are queued, just not yet uploadable.
  func count()->Int{q.sync{cachedCount+pending.count}}
  func clear(){q.sync{pending=[];withDB((),{if exec("DELETE FROM queue;"){cachedCount=0}})}}

  // MARK: - Private, all on q

  // Runs body against an open connection, or returns fallback when there is none, and drops a
  // connection that went bad during body so the next operation reopens it.
  private func withDB<T>(_ fallback:@autoclosure()->T,_ body:()->T)->T{
    guard ensureOpen() else{return fallback()}
    let r=body()
    if broken{sqlite3_close_v2(db);db=nil;broken=false}
    return r
  }

  private func ensureOpen()->Bool{
    if db != nil {return true}
    let fm=FileManager.default
    try? fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    var h:OpaquePointer?
    let flags=SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX|openFileProtection
    guard sqlite3_open_v2(url.path,&h,flags,nil)==SQLITE_OK else{sqlite3_close_v2(h);return false}
    sqlite3_busy_timeout(h,3000)
    // WAL + NORMAL: one sequential append per commit instead of a rollback journal and several fsyncs
    // per location fix. A power cut can lose the last commits but never corrupts the file.
    let setup="PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;CREATE TABLE IF NOT EXISTS queue(id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT UNIQUE, payload TEXT NOT NULL);"
    var st:OpaquePointer?
    guard sqlite3_exec(h,setup,nil,nil,nil)==SQLITE_OK,
          sqlite3_prepare_v2(h,"SELECT COUNT(*) FROM queue",-1,&st,nil)==SQLITE_OK,
          sqlite3_step(st)==SQLITE_ROW else{sqlite3_finalize(st);sqlite3_close_v2(h);return false}
    cachedCount=Int(sqlite3_column_int64(st,0))
    sqlite3_finalize(st)
    db=h
    // Files created by earlier versions have whatever class the host's entitlement defaults to.
    for suffix in ["","-wal","-shm"] {try? fm.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path+suffix)}
    // Queued fixes are transient location data: keep them out of iCloud backups.
    var u=url;var rv=URLResourceValues();rv.isExcludedFromBackup=true;try? u.setResourceValues(rv)
    if !pending.isEmpty {
      let rows=pending;pending=[]
      let r=insert(rows,lastCap)
      if r.failed {pending=rows} else {carriedDrops+=r.dropped}
    }
    return true
  }

  // One transaction for the whole batch, with the cap enforced inside it.
  private func insert(_ rows:[(uuid:String,json:String)],_ cap:Int)->EnqueueResult{
    var r=EnqueueResult()
    guard exec("BEGIN IMMEDIATE;") else{r.failed=true;return r}
    var st:OpaquePointer?
    if check(sqlite3_prepare_v2(db,"INSERT OR IGNORE INTO queue(uuid,payload) VALUES(?,?)",-1,&st,nil)) {
      for row in rows {
        sqlite3_bind_text(st,1,row.uuid,-1,SQLITE_TRANSIENT);sqlite3_bind_text(st,2,row.json,-1,SQLITE_TRANSIENT)
        guard check(sqlite3_step(st)==SQLITE_DONE ? SQLITE_OK : sqlite3_errcode(db)) else{r.failed=true;break}
        r.stored+=Int(sqlite3_changes(db))
        sqlite3_reset(st)
      }
    } else {r.failed=true}
    sqlite3_finalize(st)
    let excess=cachedCount+r.stored-cap
    if !r.failed,excess>0 {
      var del:OpaquePointer?
      if check(sqlite3_prepare_v2(db,"DELETE FROM queue WHERE id IN (SELECT id FROM queue ORDER BY id ASC LIMIT ?)",-1,&del,nil)) {
        sqlite3_bind_int64(del,1,Int64(excess))
        if check(sqlite3_step(del)==SQLITE_DONE ? SQLITE_OK : sqlite3_errcode(db)) {r.dropped=Int(sqlite3_changes(db))} else {r.failed=true}
      } else {r.failed=true}
      sqlite3_finalize(del)
    }
    guard !r.failed,exec("COMMIT;") else{_ = exec("ROLLBACK;");return EnqueueResult(stored:0,dropped:0,failed:true)}
    cachedCount+=r.stored-r.dropped
    return r
  }

  private func buffer(_ rows:[(uuid:String,json:String)])->EnqueueResult{
    pending+=rows
    let overflow=pending.count-Self.pendingLimit
    if overflow>0 {pending.removeFirst(overflow)}
    return EnqueueResult(stored:0,dropped:Swift.max(overflow,0),failed:true)
  }

  @discardableResult private func exec(_ sql:String)->Bool{check(sqlite3_exec(db,sql,nil,nil,nil))}
  private func check(_ rc:Int32)->Bool{
    guard rc != SQLITE_OK else{return true}
    switch rc & 0xff {case SQLITE_IOERR,SQLITE_CANTOPEN,SQLITE_PERM,SQLITE_AUTH,SQLITE_NOTADB:broken=true;default:break}
    return false
  }
}
