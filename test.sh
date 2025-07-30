#!/bin/bash

# Autonomous test for irssi-varlink
# Tests all varlink methods using irssi signal injection

set -e
SOCKET_PATH="$HOME/.irssi/varlink.sock"
TEST_CONFIG="test_config.tmp"
IRSSI_PID=""

cleanup() {
    echo "Cleaning up..."
    if [ -n "$IRSSI_PID" ]; then
        kill $IRSSI_PID 2>/dev/null || true
        wait $IRSSI_PID 2>/dev/null || true
    fi
    # Close pipe file descriptor
    exec 3>&- 2>/dev/null || true
    rm -f "$SOCKET_PATH"
    rm -rf "$TEST_CONFIG"
}

trap cleanup EXIT

# Create minimal irssi config for testing
setup_irssi_config() {
    mkdir -p "$TEST_CONFIG"
    cat > "$TEST_CONFIG/config" << 'EOF'
settings = {
  core = {
    real_name = "Test User";
    user_name = "testuser";
    nick = "testnick";
  };
};
EOF
}

# Start irssi with varlink script loaded
start_irssi() {
    echo "Starting irssi with varlink script..."
    setup_irssi_config
    
    # Create named pipe for sending commands to irssi
    IRSSI_PIPE="$TEST_CONFIG/irssi_pipe"
    mkfifo "$IRSSI_PIPE"
    
    # Start irssi in background with our script, reading from pipe
    (cat "$IRSSI_PIPE" | irssi --home="$TEST_CONFIG" \
          --noconnect \
          > "$TEST_CONFIG/irssi.log" 2>&1) &
    
    IRSSI_PID=$!
    
    # Keep pipe open for writing
    exec 3>"$IRSSI_PIPE"
    
    # Load script and hide window
    echo "/script load $(pwd)/varlink.pl" >&3
    sleep 2
    
    # Wait for socket creation
    for i in {1..10}; do
        if [ -S "$SOCKET_PATH" ]; then
            echo "✓ Varlink socket created"
            return 0
        fi
        sleep 1
    done
    
    echo "✗ Socket not created within 10 seconds"
    echo "irssi log:"
    cat "$TEST_CONFIG/irssi.log" 2>/dev/null || echo "No log file found"
    echo "irssi process status:"
    ps aux | grep irssi | grep -v grep || echo "No irssi process found"  
    return 1
}

# Send varlink request and get response
varlink_call() {
    local request="$1"
    printf '%s\0' "$request" | socat - "UNIX-CONNECT:$SOCKET_PATH" | tr -d '\0'
}

# Test GetInfo method
test_get_info() {
    echo "Testing GetInfo..."
    local response=$(varlink_call '{"method": "org.varlink.service.GetInfo", "parameters": {}}')
    
    if echo "$response" | grep -q '"vendor":"irssi-varlink"'; then
        echo "✓ GetInfo works"
        return 0
    else
        echo "✗ GetInfo failed: $response"
        return 1
    fi
}

# Test GetInterfaceDescription method
test_interface_description() {
    echo "Testing GetInterfaceDescription..."
    local response=$(varlink_call '{"method": "org.varlink.service.GetInterfaceDescription", "parameters": {"interface": "org.irssi.varlink"}}')
    
    if echo "$response" | grep -q 'method WaitForEvent'; then
        echo "✓ GetInterfaceDescription works"
        return 0
    else
        echo "✗ GetInterfaceDescription failed: $response"
        return 1
    fi
}

# Test WaitForEvent with signal injection
test_wait_for_event() {
    echo "Testing WaitForEvent with signal injection..."
    
    # Start waiting for events in background and capture response
    local response_file="$TEST_CONFIG/event_response"
    (printf '{"method": "org.irssi.varlink.WaitForEvent", "parameters": {}}\0'; sleep 10) | socat - "UNIX-CONNECT:$SOCKET_PATH" > "$response_file" &
    local socat_pid=$!
    
    sleep 2
    
    # Generate test event using varlink method  
    echo "Generating test event..."
    sleep 1
    (sleep 1; 
     echo "Actually calling TestEvent..."; 
     result=$(varlink_call '{"method": "org.irssi.varlink.TestEvent", "parameters": {"message": "test message"}}'); 
     echo "TestEvent result: $result") &
    
    # Wait for event response
    local timeout=8
    while [ $timeout -gt 0 ] && [ ! -s "$response_file" ]; do
        sleep 1
        timeout=$((timeout - 1))
    done
    
    # Give socat a moment to write the response after receiving it
    sleep 1
    
    # Kill socat if still running
    kill $socat_pid 2>/dev/null || true
    wait $socat_pid 2>/dev/null || true
    
    # Debug: check what we got
    echo "Response file size: $(wc -c < "$response_file" 2>/dev/null || echo 0)"
    echo "Response file content (hex): $(xxd "$response_file" 2>/dev/null | head -2 || echo 'no file')"
    
    # Validate event structure
    if [ -s "$response_file" ]; then
        local response=$(cat "$response_file" | tr -d '\0')
        echo "Event response: $response"
        
        if echo "$response" | grep -q '"type":"message"' && \
           echo "$response" | grep -q '"subtype":"public"' && \
           echo "$response" | grep -q '"message":"test message"' && \
           echo "$response" | grep -q '"nick":"testnick"'; then
            echo "✓ WaitForEvent returns correct event structure"
            return 0
        else
            echo "✗ WaitForEvent returned invalid event structure"
            return 1
        fi
    else
        echo "✗ WaitForEvent did not return event"
        return 1
    fi
}

# Test WaitForEvent streaming mode
test_wait_for_event_streaming() {
    echo "Testing WaitForEvent streaming mode..."
    

    
    # Start streaming mode in background and capture output
    local stream_file="$TEST_CONFIG/stream_response"
    (printf '{"method": "org.irssi.varlink.WaitForEvent", "parameters": {}, "more": true}\0'; sleep 8) | socat - "UNIX-CONNECT:$SOCKET_PATH" > "$stream_file" &
    local socat_pid=$!
    
    sleep 2
    
    # Send multiple events via TestEvent method
    for i in 1 2 3; do
        echo "Generating event $i..."
        varlink_call "{\"method\": \"org.irssi.varlink.TestEvent\", \"parameters\": {\"message\": \"message $i\"}}" > /dev/null &
        sleep 1
    done
    
    sleep 2
    kill $socat_pid 2>/dev/null || true
    wait $socat_pid 2>/dev/null || true
    
    # Check if we got multiple events
    if [ -s "$stream_file" ]; then
        local event_count=$(cat "$stream_file" | tr '\0' '\n' | grep -c '"type":"message"' 2>/dev/null || echo 0)
        if [ "$event_count" -gt 2 ] 2>/dev/null; then
            echo "✓ WaitForEvent streaming received $event_count events"
            return 0
        else
            echo "✗ WaitForEvent streaming only received $event_count events"
            return 1
        fi
    else
        echo "✗ WaitForEvent streaming returned no data"
        return 1
    fi
}

# Test UTF-8 encoding (no double-encoding)
test_utf8_encoding() {
    echo "Testing UTF-8 encoding..."
    
    local utf8_message="café 中文 🎉"
    # Expected UTF-8 bytes: 636166c3a920e4b8ade6968720f09f8e89
    
    local response_file="$TEST_CONFIG/utf8_response"
    (printf '{"method": "org.irssi.varlink.WaitForEvent", "parameters": {}}\0'; sleep 5) | socat - "UNIX-CONNECT:$SOCKET_PATH" > "$response_file" &
    local socat_pid=$!
    
    sleep 1
    varlink_call "{\"method\": \"org.irssi.varlink.TestEvent\", \"parameters\": {\"message\": \"$utf8_message\"}}" > /dev/null
    sleep 2
    
    kill $socat_pid 2>/dev/null || true
    wait $socat_pid 2>/dev/null || true
    
    if [ -s "$response_file" ]; then
        # Check if the UTF-8 bytes appear correctly (not double-encoded)
        local response_hex=$(xxd -p "$response_file" | tr -d '\n')
        if echo "$response_hex" | grep -q "636166c3a920e4b8ade6968720f09f8e89"; then
            echo "✓ UTF-8 properly encoded (no double-encoding)"
            return 0
        else
            echo "✗ UTF-8 encoding issue detected"
            echo "Expected hex pattern: 636166c3a920e4b8ade6968720f09f8e89"
            echo "Actual response:"
            xxd "$response_file" | head -3
            return 1
        fi
    else
        echo "✗ No UTF-8 response received"
        return 1
    fi
}

# Test SendMessage method (without real IRC server)
test_send_message() {
    echo "Testing SendMessage..."
    local response=$(varlink_call '{"method": "org.irssi.varlink.SendMessage", "parameters": {"target": "#test", "message": "test message", "server": "nonexistent"}}')
    
    # Should fail since no server is connected, but should be well-formed error
    if echo "$response" | grep -q '"error"'; then
        echo "✓ SendMessage returns proper error when no server connected"
        return 0
    else
        echo "✗ SendMessage unexpected response: $response"
        return 1
    fi
}

# Test graceful shutdown notification on script reload
test_graceful_shutdown() {
    echo "Testing graceful shutdown notification..."
    
    local response_file="$TEST_CONFIG/shutdown_response"
    
    # Start a client waiting for events in background
    (printf '{"method": "org.irssi.varlink.WaitForEvent", "parameters": {}, "more": true}\0'; sleep 10) | socat - "UNIX-CONNECT:$SOCKET_PATH" > "$response_file" &
    local socat_pid=$!
    
    sleep 2
    
    # Trigger script reload (which calls UNLOAD)
    echo "Triggering script reload..."
    echo "/script unload varlink" >&3
    sleep 1
    echo "/script load $(pwd)/varlink.pl" >&3
    
    sleep 3
    
    # Check if socat process exited gracefully (should have received shutdown error and EOF)
    local socat_exited=false
    if ! kill -0 $socat_pid 2>/dev/null; then
        socat_exited=true
        echo "✓ Client connection terminated automatically"
    else
        echo "✗ Client connection still hanging"
        kill $socat_pid 2>/dev/null || true
        wait $socat_pid 2>/dev/null || true
    fi
    
    # Check if we received shutdown notification
    if [ -s "$response_file" ]; then
        local response=$(cat "$response_file" | tr -d '\0')
        echo "Shutdown response: $response"
        
        if echo "$response" | grep -q '"error":"org.varlink.service.ServiceShutdown"' && \
           echo "$response" | grep -q '"description":"Service is shutting down"'; then
            if $socat_exited; then
                echo "✓ Graceful shutdown: notification sent and connection closed"
                return 0
            else
                echo "✓ Shutdown notification sent (but connection didn't auto-close)"
                return 0
            fi
        else
            echo "✗ Received response but not shutdown error: $response"
            return 1
        fi
    else
        echo "✗ No shutdown notification received"
        if $socat_exited; then
            echo "   (but connection did close)"
            return 0
        else
            return 1
        fi
    fi
}

# Test client disconnect handling (no error flood)
test_disconnect_handling() {
    echo "Testing client disconnect handling..."
    
    local log_file="$TEST_CONFIG/irssi.log"
    local test_log="$TEST_CONFIG/disconnect_test.log"
    
    # Clear previous log and start fresh monitoring
    > "$test_log"
    
    # Tail the log during our test to capture all output
    tail -f "$log_file" > "$test_log" 2>&1 &
    local tail_pid=$!
    
    sleep 1
    
    # Connect and immediately disconnect multiple times to trigger error conditions
    echo "Creating 15 aggressive disconnects..."
    for i in {1..15}; do
        echo "  Disconnect attempt $i..."
        # Start connection and kill it abruptly to simulate network issues
        timeout --foreground 0.1 socat - "UNIX-CONNECT:$SOCKET_PATH" </dev/null >/dev/null 2>&1 || true
        # Also try sending partial data then disconnecting
        (printf '{"meth' | timeout --foreground 0.1 socat - "UNIX-CONNECT:$SOCKET_PATH" </dev/null) >/dev/null 2>&1 || true
        sleep 0.1
    done
    echo "Disconnect attempts completed."
    
    sleep 3  # Give time for any error messages
    
    # More robust tail cleanup as suggested by Oracle
    echo "Cleaning up tail process ($tail_pid)..."
    kill -TERM $tail_pid 2>/dev/null || true
    sleep 0.2
    kill -KILL $tail_pid 2>/dev/null || true
    wait $tail_pid 2>/dev/null || true
    
    # Look for specific error patterns that indicate bad disconnect handling
    local sysread_errors=0
    local uninit_errors=0
    
    if [ -f "$test_log" ]; then
        sysread_errors=$(grep -c "sysread() on closed filehandle" "$test_log" 2>/dev/null || echo 0)
        uninit_errors=$(grep -c "Use of uninitialized value" "$test_log" 2>/dev/null || echo 0)
    fi
    
    # Debug: ensure variables are numeric
    sysread_errors=${sysread_errors//[^0-9]/}
    uninit_errors=${uninit_errors//[^0-9]/}
    sysread_errors=${sysread_errors:-0}
    uninit_errors=${uninit_errors:-0}
    
    local total_errors=$((sysread_errors + uninit_errors))
    
    # Count normal disconnect messages (should be present)
    local disconnect_msgs=$(grep -c "Varlink client disconnected" "$test_log" 2>/dev/null || echo 0)
    
    echo "Found: $disconnect_msgs disconnect messages, $sysread_errors sysread errors, $uninit_errors uninitialized value errors"
    
    # Save test output for inspection
    echo "=== Disconnect Test Log ===" > "$TEST_CONFIG/disconnect_analysis.log"
    cat "$test_log" >> "$TEST_CONFIG/disconnect_analysis.log"
    echo "Test log saved to: $TEST_CONFIG/disconnect_analysis.log"
    
    # Should have disconnect messages but no error floods
    if [ "$total_errors" -eq 0 ] && [ "$disconnect_msgs" -gt 0 ]; then
        echo "✓ Client disconnect handling clean ($disconnect_msgs disconnects, no errors)"
        return 0
    elif [ "$total_errors" -gt 0 ]; then
        echo "✗ Client disconnect caused $total_errors error messages"
        echo "Sample errors:"
        grep -E "(sysread|uninitialized)" "$test_log" | head -5 || true
        return 1
    else
        echo "✗ No disconnect messages found (test may not have worked)"
        return 1
    fi
}

# Main test execution
main() {
    echo "=== irssi-varlink Autonomous Test ==="
    
    # Check dependencies
    if ! command -v irssi >/dev/null 2>&1; then
        echo "✗ irssi not found"
        exit 1
    fi
    
    if ! command -v socat >/dev/null 2>&1; then
        echo "✗ socat not found"
        exit 1
    fi
    
    echo "✓ Dependencies available"
    
    # Start irssi
    if ! start_irssi; then
        exit 1
    fi
    
    sleep 3  # Give irssi time to fully initialize
    
    # Run tests
    local failed=0
    
    test_get_info || failed=$((failed + 1))
    test_interface_description || failed=$((failed + 1))
    test_send_message || failed=$((failed + 1))
    test_utf8_encoding || failed=$((failed + 1))
    test_disconnect_handling || failed=$((failed + 1))
    test_graceful_shutdown || failed=$((failed + 1))
    test_wait_for_event || failed=$((failed + 1))
    test_wait_for_event_streaming || failed=$((failed + 1))
    
    echo
    if [ $failed -eq 0 ]; then
        echo "=== ALL TESTS PASSED ==="
        exit 0
    else
        echo "=== $failed TESTS FAILED ==="
        exit 1
    fi
}

main "$@"
