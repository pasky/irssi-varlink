# irssi-varlink Agent Guide

## Build/Test Commands
- Run all tests: `./test.sh`

## Architecture
- **Core**: `varlink.pl` - Perl script implementing varlink protocol over UNIX socket
- **Socket**: `~/.irssi/varlink.sock` - Communication endpoint
- **Protocol**: JSON messages terminated with NUL bytes (\0)
- **Key APIs**: WaitForEvent (monitoring), SendMessage (sending), standard varlink service methods
- **Testing**: Event injection via TestEvent method, autonomous test harness

## Code Style
- **Language**: Perl with strict/warnings
- **Imports**: Irssi, IO::Socket::UNIX, JSON, POSIX
- **Naming**: snake_case for functions, camelCase for varlink methods
- **Error handling**: encode_error() with varlink error format
- **Validation**: validate_call_object() for method structure
- **Client tracking**: Hash-based with file descriptors as keys
- **Comments**: Minimal, code should be self-explanatory
