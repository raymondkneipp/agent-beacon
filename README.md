# AgentBeacon 🚨

A lightweight macOS menu-bar-style "activity light" for CLI-based AI agents. It lives in the corner of your screen and tells you at a glance if your agent is **working** or **waiting for your input**.

![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

## Features
- **Visual Status:** Displays `⏳` (Working) or `👋` (Needs Input).
- **Attention Grabber:** The `👋` emoji waves every 5 seconds when the agent is idle to catch your eye.
- **Smart Filtering:** Automatically ignores terminal focus events and common "noise" to prevent false status changes.
- **Generic Support:** Works with any CLI tool (Gemini, Claude, GPT, etc.).
- **Always on Top:** Floating, click-through window that stays visible even when you switch apps.

## Installation

### Prerequisites
- macOS 11.0+
- Swift 5.9+ (included with Xcode)

### Building from source
```bash
git clone https://github.com/yourusername/AgentBeacon.git
cd AgentBeacon
swift build -c release
```

The executable will be located at:
`.build/release/agent-beacon`

## Usage

Run any CLI command through `agent-beacon`:

```bash
# Run Gemini CLI
agent-beacon gemini

# Run Claude Code
agent-beacon claude

# Run a long-running build or script
agent-beacon ./my-long-script.sh
```

## Running from anywhere

To make `agent-beacon` available globally, you can move it to your `/usr/local/bin`:

```bash
sudo cp .build/release/agent-beacon /usr/local/bin/
```

Now you can simply run:
`agent-beacon gemini`

## How it Works
`AgentBeacon` creates a Pseudo-Terminal (PTY) and spawns your command as a child process. It monitors the output stream for activity. If the stream is silent for more than 1.5 seconds, it assumes the agent is waiting for input.

## License
MIT
