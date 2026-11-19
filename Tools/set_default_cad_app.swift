// Sets CadLens as the per-user default handler for .dwg/.dxf.
// Build:
//   swiftc -O Tools/set_default_cad_app.swift -o /tmp/set-cad-default -framework CoreServices
// Run after the app has been registered with LaunchServices.
import Foundation
import CoreServices

let bundleID = "com.cadlens.native"
// Older builds of 速看CAD registered these UTIs; include them so existing
// files are switched too, without claiming them in our Info.plist.
let declared = ["com.autodesk.dwg", "com.autodesk.dxf", "com.sukancad.dwg", "com.sukancad.dxf"]
let extensions = ["dwg", "dxf"]

func setHandler(_ contentType: String) -> OSStatus {
    LSSetDefaultRoleHandlerForContentType(contentType as CFString, .all, bundleID as CFString)
}

var failed = false
for type in declared {
    let status = setHandler(type)
    let current = LSCopyDefaultRoleHandlerForContentType(type as CFString, .all)?
        .takeRetainedValue() as String? ?? "-"
    print("\(type): status=\(status) handler=\(current)")
    if status != noErr { failed = true }
}

for ext in extensions {
    guard let uti = UTTypeCreatePreferredIdentifierForTag(
        kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue() as String? else {
        print("\(ext): no UTI")
        failed = true
        continue
    }
    let status = setHandler(uti)
    let current = LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all)?
        .takeRetainedValue() as String? ?? "-"
    print("\(ext) -> \(uti): status=\(status) handler=\(current)")
    if status != noErr { failed = true }
}
exit(failed ? 1 : 0)
