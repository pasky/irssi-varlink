# irssi-varlink

A Perl script for irssi that provides a varlink RPC interface via UNIX socket for programmatic access to IRC functionality.

## Features

- Monitor IRC messages (public and private) in real-time
- Send messages to channels or users
- Varlink protocol over UNIX socket
- JSON-based communication

## Installation

1. Copy `varlink.pl` to your irssi scripts directory (usually `~/.irssi/scripts/`)
2. Load the script in irssi: `/script load varlink.pl`

## Usage

The script creates a UNIX socket at `~/.irssi/varlink.sock` when loaded.

### Available Methods

#### WaitForEvent
Waits for IRC events. Use `"more": true` to keep receiving events, or omit for single event.

```json
{"method": "org.irssi.varlink.WaitForEvent", "parameters": {}, "more": true}
```

Response includes events like:
```json
{
  "parameters": {
    "event": {
      "type": "message",
      "subtype": "public",
      "server": "freenode",
      "target": "#channel",
      "nick": "username", 
      "address": "user@host.com",
      "message": "Hello world!",
      "timestamp": 1642598400
    }
  },
  "continues": true
}
```

#### SendMessage
Sends a message to a channel or user.

```json
{
  "method": "org.irssi.varlink.SendMessage",
  "parameters": {
    "target": "#channel",
    "message": "Hello from varlink!",
    "server": "freenode"
  }
}
```

The `server` parameter is optional - if not provided, uses the active server.

#### GetInfo
Returns service information (standard varlink method).

```json
{"method": "org.varlink.service.GetInfo", "parameters": {}}
```

#### GetInterfaceDescription
Returns interface description (standard varlink method).

```json
{"method": "org.varlink.service.GetInterfaceDescription", "parameters": {"interface": "org.irssi.varlink"}}
```

## Example Client

You can test the interface using any varlink client or simple socket communication:

```bash
# Using socat to test (note: messages are NUL-terminated)
printf '{"method": "org.varlink.service.GetInfo", "parameters": {}}\0' | socat - UNIX-CONNECT:$HOME/.irssi/varlink.sock
```

## Protocol

The script implements the varlink protocol over UNIX domain sockets. Each request/response is a JSON message terminated with a NUL byte (\0).

## Development

`test.sh` is a simple test harness for making sure things work.

## License

MIT

The code has been co-written with Claude.
