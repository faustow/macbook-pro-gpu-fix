#!/bin/bash
# Claude Code Watchdog Script
# Keeps Claude Code running to fix this MacBook Pro

MISSION_FILE="$HOME/CLAUDE_FIX_COMPUTER_MISSION.md"
LOG_FILE="$HOME/claude_watchdog.log"
LOCK_FILE="/tmp/claude_watchdog.lock"

# Ensure only one instance runs
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "$(date): Watchdog already running (PID $pid)" >> "$LOG_FILE"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"

log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

cleanup() {
    rm -f "$LOCK_FILE"
    log "Watchdog stopped"
    exit 0
}

trap cleanup EXIT INT TERM

log "=== Claude Watchdog Started ==="
log "Mission: Fix MacBook Pro GPU issues"
log "Mission file: $MISSION_FILE"

# Wait for system to stabilize after boot
sleep 10

while true; do
    # Check if Claude Code is running
    # Look for: 'claude' binary (not watchdog, not grep, not other claude-named things)
    # Using ps to get actual command and filtering carefully
    CLAUDE_PIDS=$(ps aux | grep -E "claude\s|claude$|\.local/bin/claude" | grep -v "watchdog" | grep -v "grep" | awk '{print $2}')

    if [ -z "$CLAUDE_PIDS" ]; then
        log "Claude Code not running - starting it..."

        # Open Terminal and run Claude Code with mission
        osascript -e 'tell application "Terminal"
            activate
            do script "cd ~ && echo \"\" && echo \"============================================\" && echo \"  CLAUDE CODE MACBOOK FIX MISSION\" && echo \"============================================\" && echo \"\" && head -30 ~/CLAUDE_FIX_COMPUTER_MISSION.md && echo \"\" && echo \"Starting Claude Code...\" && echo \"\" && /Users/daftlog/.local/bin/claude \"Read ~/CLAUDE_FIX_COMPUTER_MISSION.md and execute all phases to fix this MacBook Pro. You have full authorization. Do not stop until the computer is stable.\""
        end tell' 2>/dev/null

        log "Claude Code started via Terminal"

        # Wait before checking again (give Claude time to start)
        sleep 180
    else
        log "Claude Code is running (PIDs: $CLAUDE_PIDS)"
    fi

    # Check every 90 seconds
    sleep 90
done
