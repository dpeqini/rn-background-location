import Foundation
@objc public final class NativeBackgroundLocationBootstrap:NSObject {
  @objc public static func start(){BackgroundLocationEngine.shared.bootstrap()}
  @objc public static func handleEventsForBackgroundURLSession(_ identifier:String, completionHandler:@escaping()->Void){
    if identifier == "com.greinchville.rn-background-location.http" { BackgroundUploader.shared.reattach(completion:completionHandler) }
    else { completionHandler() }
  }
}
