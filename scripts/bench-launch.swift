// Launch-time, memory and idle-CPU benchmark: swift scripts/bench-launch.swift build/Wisp.app/Contents/MacOS/Wisp 6
import AppKit
import CoreGraphics

func sh(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe(); try! p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

let bin = CommandLine.arguments[1]
let runs = Int(CommandLine.arguments[2]) ?? 5
var launches: [Double] = [], footprints: [Double] = [], rss: [Double] = [], cpus: [Double] = []
for i in 1...runs {
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
    let t0 = DispatchTime.now()
    try! p.run()
    var ms = -1.0
    while ms < 0 {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
        if list.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == p.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
            ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        } else { usleep(2000) }
        if Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9 > 15 { break }
    }
    sleep(3)
    let pid = p.processIdentifier
    let fp = sh("footprint -p \(pid) 2>/dev/null | grep -i 'phys_footprint:' | head -1")
    let fpMB = Double(fp.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.first ?? "0") ?? 0
    let unitMB = fp.contains("KB") ? fpMB / 1024 : (fp.contains("GB") ? fpMB * 1024 : fpMB)
    let r = (Double(sh("ps -o rss= -p \(pid)").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    var cpuSamples: [Double] = []
    for _ in 0..<5 { cpuSamples.append(Double(sh("ps -o %cpu= -p \(pid)").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0); sleep(1) }
    let cpu = cpuSamples.reduce(0, +) / Double(cpuSamples.count)
    p.terminate(); p.waitUntilExit()
    print(String(format: "run %d: window in %.0f ms · footprint %.1f MB · RSS %.1f MB · idle CPU %.2f%%", i, ms, unitMB, r, cpu))
    launches.append(ms); footprints.append(unitMB); rss.append(r); cpus.append(cpu)
    usleep(500_000)
}
func median(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
print(String(format: "MEDIAN: launch→window %.0f ms (first/cold %.0f ms) · footprint %.1f MB · RSS %.1f MB · idle CPU %.2f%%",
             median(Array(launches.dropFirst())), launches[0], median(footprints), median(rss), median(cpus)))
