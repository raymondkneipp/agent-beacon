import SwiftUI
import AppKit
import Foundation
import Darwin

enum BeaconState {
    case working   // ⏳
    case needsInput // 👋

    var emoji: String {
        switch self {
        case .working: return "⏳"
        case .needsInput: return "👋"
        }
    }
}

@MainActor
class BeaconManager: ObservableObject {
    @Published var state: BeaconState = .needsInput
    private var lastOutput = Date(timeIntervalSince1970: 0)
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateState()
            }
        }
    }

    func reportOutput(_ data: Data) {
        // Ignore small chunks that look like terminal overhead (ESC, CR, LF) or prompt re-draws
        if data.count <= 15 {
            if let firstByte = data.first, firstByte == 0x1B || firstByte == 0x0D || firstByte == 0x0A {
                return
            }
        }
        lastOutput = Date()
    }

    private func updateState() {
        let now = Date()
        let silence = now.timeIntervalSince(lastOutput)
        let newState: BeaconState = silence < 1.5 ? .working : .needsInput
        if newState != state {
            self.state = newState
        }
    }
}

struct BeaconView: View {
    @ObservedObject var manager: BeaconManager
    @State private var waveOffset: Double = 0
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(manager.state.emoji)
            .font(.system(size: 32))
            .rotationEffect(.degrees(waveOffset), anchor: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(timer) { _ in
                guard manager.state == .needsInput else { return }
                // Perform 3 full waves (6 half-cycles)
                withAnimation(.easeInOut(duration: 0.15).repeatCount(6, autoreverses: true)) {
                    waveOffset = 15
                }
                // Reset to 0 after animation finishes (0.15 * 6 = 0.9s)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if manager.state == .needsInput {
                        waveOffset = 0
                    }
                }
            }
            .onChange(of: manager.state) { newState in
                if newState == .working {
                    // Immediately cancel any rotation
                    withAnimation(.none) {
                        waveOffset = 0
                    }
                }
            }
            .animation(.spring(), value: manager.state)
    }
}

@main
struct AgentBeacon {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let manager = BeaconManager()
        let arguments = CommandLine.arguments

        if arguments.count < 2 {
            print("Usage: agent-beacon <command> [args...]")
            print("Example: agent-beacon gemini")
            exit(1)
        }

        let cmdArgs = Array(arguments.dropFirst())
        
        DispatchQueue.global(qos: .userInteractive).async {
                var master: Int32 = 0
                var slave: Int32 = 0
                
                // Get current terminal window size
                var winSize = winsize()
                _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &winSize)
                
                // Get current terminal settings to restore later
                var originalTermios = termios()
                tcgetattr(STDIN_FILENO, &originalTermios)
                
                // Create PTY with current terminal size
                if openpty(&master, &slave, nil, nil, &winSize) != 0 {
                    print("Failed to open PTY")
                    exit(1)
                }
                
                let envPath = "/usr/bin/env"
                var argv: [UnsafeMutablePointer<CChar>?] = [strdup(envPath)]
                for arg in cmdArgs {
                    argv.append(strdup(arg))
                }
                argv.append(nil)
                
                var envp: [UnsafeMutablePointer<CChar>?] = []
                for (key, value) in ProcessInfo.processInfo.environment {
                    envp.append(strdup("\(key)=\(value)"))
                }
                envp.append(nil)
                
                var fileActions: posix_spawn_file_actions_t?
                posix_spawn_file_actions_init(&fileActions)
                posix_spawn_file_actions_adddup2(&fileActions, slave, 0)
                posix_spawn_file_actions_adddup2(&fileActions, slave, 1)
                posix_spawn_file_actions_adddup2(&fileActions, slave, 2)
                
                var attr: posix_spawnattr_t?
                posix_spawnattr_init(&attr)
                posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
                
                // Set parent terminal to raw mode
                var rawTermios = originalTermios
                cfmakeraw(&rawTermios)
                tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)
                
                var pid: pid_t = 0
                let status = posix_spawn(&pid, envPath, &fileActions, &attr, argv, envp)
                
                // Cleanup spawn structures
                posix_spawn_file_actions_destroy(&fileActions)
                posix_spawnattr_destroy(&attr)
                for p in argv { if let p = p { free(p) } }
                for p in envp { if let p = p { free(p) } }
                close(slave)
                
                if status == 0 {
                    let masterFile = FileHandle(fileDescriptor: master)
                    
                    // Thread to read from Master (Child -> Parent)
                    let readThread = Thread {
                        while true {
                            let data = masterFile.availableData
                            if data.isEmpty { break }
                            FileHandle.standardOutput.write(data)
                            Task { @MainActor in
                                manager.reportOutput(data)
                            }
                        }
                    }
                    readThread.start()
                    
                    // Thread to write to Master (Parent -> Child)
                    let writeThread = Thread {
                        while true {
                            let data = FileHandle.standardInput.availableData
                            if data.isEmpty { break }
                            
                            // Filter out Focus In (\x1b[I) and Focus Out (\x1b[O) events
                            // This prevents the child from reacting to terminal focus changes
                            if data.count == 3 && data[0] == 0x1B && data[1] == 0x5B {
                                if data[2] == 0x49 || data[2] == 0x4F {
                                    continue
                                }
                            }
                            
                            try? masterFile.write(contentsOf: data)
                        }
                    }
                    writeThread.start()
                    
                    var exitStatus: Int32 = 0
                    waitpid(pid, &exitStatus, 0)
                }
                
                // Restore original terminal settings
                tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
                
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let windowWidth: CGFloat = 100
            let windowHeight: CGFloat = 100
            let x = screenFrame.maxX - windowWidth
            let y = screenFrame.maxY - windowHeight

            let window = NSWindow(
                contentRect: NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: BeaconView(manager: manager))
            window.orderFront(nil)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
        }

        app.run()
    }
}
