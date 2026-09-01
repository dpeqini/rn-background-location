import Foundation
import SQLite3

final class IOSLocationQueue {
  // One connection per process: the engine and the background uploader both acknowledge rows,
  // and the uploader does so from a delegate queue in a possibly relaunched app.
  static let shared = IOSLocationQueue()
  struct Row { let id:Int64; let payload:[String:Any] }
  private var db:OpaquePointer?
  private var sinceTrim=0
  init(){ let url=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("rn_bg_location.sqlite"); try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); sqlite3_open(url.path,&db); sqlite3_exec(db,"CREATE TABLE IF NOT EXISTS queue(id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT UNIQUE, payload TEXT NOT NULL);",nil,nil,nil) }
  deinit{sqlite3_close(db)}
  func enqueue(_ payload:[String:Any],max:Int){ guard let d=try? JSONSerialization.data(withJSONObject:payload),let s=String(data:d,encoding:.utf8),let uuid=payload["id"] as? String else{return}; var st:OpaquePointer?;sqlite3_prepare_v2(db,"INSERT OR IGNORE INTO queue(uuid,payload) VALUES(?,?)",-1,&st,nil);sqlite3_bind_text(st,1,(uuid as NSString).utf8String,-1,nil);sqlite3_bind_text(st,2,(s as NSString).utf8String,-1,nil);sqlite3_step(st);sqlite3_finalize(st);trim(max) }
  // The cap is a soft one: trimming ran a COUNT(*) scan on every insert, which is wasted work
  // per location fix once the table is large. Amortise it over a batch of writes instead.
  private func trim(_ max:Int){ sinceTrim += 1; guard sinceTrim >= 50 else {return}; sinceTrim = 0; sqlite3_exec(db,"DELETE FROM queue WHERE id IN (SELECT id FROM queue ORDER BY id ASC LIMIT MAX((SELECT COUNT(*) FROM queue)-\(max),0));",nil,nil,nil) }
  func peek(limit:Int)->[Row]{var out:[Row]=[];var st:OpaquePointer?;sqlite3_prepare_v2(db,"SELECT id,payload FROM queue ORDER BY id ASC LIMIT ?",-1,&st,nil);sqlite3_bind_int(st,1,Int32(limit));while sqlite3_step(st)==SQLITE_ROW {let id=sqlite3_column_int64(st,0);if let c=sqlite3_column_text(st,1),let d=String(cString:c).data(using:.utf8),let o=try? JSONSerialization.jsonObject(with:d) as? [String:Any]{out.append(Row(id:id,payload:o))}};sqlite3_finalize(st);return out}
  func deleteThrough(_ id:Int64){sqlite3_exec(db,"DELETE FROM queue WHERE id<=\(id)",nil,nil,nil)}
  func count()->Int{var st:OpaquePointer?;sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM queue",-1,&st,nil);defer{sqlite3_finalize(st)};return sqlite3_step(st)==SQLITE_ROW ? Int(sqlite3_column_int(st,0)):0}
  func clear(){sqlite3_exec(db,"DELETE FROM queue",nil,nil,nil)}
}
