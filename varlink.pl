#!/usr/bin/perl

use strict;
use warnings;
use Irssi;
use Irssi::Irc;
use IO::Socket::UNIX;
use JSON;
use POSIX qw(strftime);

our $VERSION = '1.0';
our %IRSSI = (
    authors     => 'Petr Baudis, Claude',
    contact     => 'pasky@ucw.cz',
    name        => 'Varlink Interface',
    description => 'Exposes irssi functionality via varlink protocol over UNIX socket',
    license     => 'MIT',
    url         => 'https://github.com/pasky/irssi-varlink',
    changed     => '2025-07-25',
);

my $socket_path = $ENV{HOME} . '/.irssi/varlink.sock';
my $server_socket;
my @client_sockets = ();
my %client_buffers = ();  # Buffer for partial messages per client
my %waiting_clients = ();  # Track clients waiting for events (client -> more_flag)
my $json = JSON->new->utf8;

# Varlink interface description string
my $interface_description = <<'EOF';
interface org.irssi.varlink

method WaitForEvent() -> (event: Event)

method SendMessage(target: string, message: string, server: string) -> (success: bool)

method GetServerNick(server: string) -> (nick: string)

type Event (
    type: string,
    subtype: string,
    server: string,
    target: string,
    nick: string,
    address: ?string,
    message: string,
    timestamp: int
)

error ServerNotFound (server: string)
EOF

# Varlink interface definition
my $interface = {
    'interface' => 'org.irssi.varlink',
    'methods' => {
        'SendMessage' => {
            'parameters' => {
                'target' => 'string',
                'message' => 'string',
                'server' => 'string'
            },
            'returns' => {
                'success' => 'bool'
            }
        },
        'GetInterfaceDescription' => {
            'parameters' => {
                'interface' => 'string'
            },
            'returns' => {
                'description' => 'string'
            }
        },
        'GetServerNick' => {
            'parameters' => {
                'server' => 'string'
            },
            'returns' => {
                'nick' => 'string'
            }
        }
    }
};

sub create_server {
    unlink $socket_path if -e $socket_path;

    $server_socket = IO::Socket::UNIX->new(
        Type   => &SOCK_STREAM,
        Local  => $socket_path,
        Listen => 5,
    ) or do {
        Irssi::print("Failed to create UNIX socket: $!");
        return;
    };

    Irssi::print("Varlink server listening on $socket_path");

    # Add to irssi input handlers
    Irssi::input_add(fileno($server_socket), INPUT_READ, \&accept_client, undef);
}

sub accept_client {
    my $client = $server_socket->accept();
    if ($client) {
        push @client_sockets, $client;
        $client_buffers{$client} = '';  # Initialize buffer for this client
        Irssi::input_add(fileno($client), INPUT_READ, \&handle_client, $client);
        Irssi::print("Varlink client connected");
    }
}

sub handle_client {
    my $client = $_[0];
    return unless $client;  # Guard against undefined client
    return unless fileno($client);  # Guard against closed filehandle
    
    my $data;
    my $bytes = sysread($client, $data, 4096);

    if (!defined $bytes || $bytes == 0) {
        # Client disconnected
        close_client($client);
        return;
    }

    # Append new data to client's buffer
    $client_buffers{$client} .= $data;

    # Process all complete messages (NUL-terminated) in buffer
    while ($client_buffers{$client} =~ s/^(.*?)\0//) {
        my $message = $1;
        my $response = process_varlink_call($message, $client);

        if ($response) {
            print $client $response . "\0";  # NUL-terminate response
        }
    }
}

sub close_client {
    my $client = shift;
    return unless $client;  # Guard against undefined client
    
    my $client_fd = fileno($client);
    return unless defined $client_fd;  # Guard against invalid filehandle
    
    Irssi::input_remove($client_fd);
    delete $client_buffers{$client};  # Clean up client buffer
    delete $waiting_clients{$client};  # Clean up waiting client
    close($client);
    @client_sockets = grep { $_ != $client } @client_sockets;
    Irssi::print("Varlink client disconnected");
}

sub validate_call_object {
    my $call = shift;
    
    return "Missing method" unless exists $call->{method};
    return "Invalid method format" unless $call->{method} =~ /^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/;
    
    return undef; # Valid
}

sub process_varlink_call {
    my ($data, $client) = @_;

    my $call;
    eval {
        $call = $json->decode($data);
    };
    if ($@) {
        return encode_error("org.varlink.service.InvalidParameter", "Invalid JSON");
    }

    # Validate call object structure
    my $validation_error = validate_call_object($call);
    if ($validation_error) {
        return encode_error("org.varlink.service.InvalidParameter", $validation_error);
    }

    my $method = $call->{method};
    my $params = $call->{parameters} || {};
    my $more = $call->{more} // 0;
    my $oneway = $call->{oneway} // 0;

    if ($method eq 'org.varlink.service.GetInfo') {
        return $json->encode({
            parameters => {
                vendor => 'irssi-varlink',
                product => 'Irssi Varlink Interface',
                version => $VERSION,
                url => 'https://github.com/pasky/irssi-varlink',
                interfaces => ['org.irssi.varlink']
            }
        });
        
    } elsif ($method eq 'org.varlink.service.GetInterfaceDescription') {
        my $iface = $params->{interface};
        if ($iface eq 'org.irssi.varlink') {
            chomp $interface_description;
            return $json->encode({
                parameters => {
                    description => $interface_description
                }
            });
        } else {
            return encode_error("org.varlink.service.InterfaceNotFound", "Interface '$iface' not found");
        }

    } elsif ($method eq 'org.irssi.varlink.WaitForEvent') {
        if ($more) {
            # Client wants to keep receiving events
            $waiting_clients{$client} = 'streaming';
        } else {
            # Single event request - mark as waiting but will be cleaned up after first event
            $waiting_clients{$client} = 'single';
        }
        
        # Don't return a response immediately - wait for events
        return undef;

    } elsif ($method eq 'org.irssi.varlink.SendMessage') {
        my $target = $params->{target};
        my $message = $params->{message};
        my $server_tag = $params->{server};

        if (!$target || !defined $message || !$server_tag) {
            return encode_error("org.varlink.service.InvalidParameter",
                "Missing required parameters: target, message, server");
        }

        my $server = Irssi::server_find_tag($server_tag);

        if (!$server) {
            return encode_error("org.irssi.varlink.ServerNotFound",
                "Server not found or not connected", 
                { server => $server_tag });
        }

        $server->send_message($target, $message, 0);

        return $json->encode({
            parameters => {
                success => JSON::true
            }
        });

    } elsif ($method eq 'org.irssi.varlink.GetServerNick') {
        my $server_tag = $params->{server};

        if (!$server_tag) {
            return encode_error("org.varlink.service.InvalidParameter",
                "Missing required parameter: server");
        }

        my $server = Irssi::server_find_tag($server_tag);

        if (!$server) {
            return encode_error("org.irssi.varlink.ServerNotFound",
                "Server not found or not connected", 
                { server => $server_tag });
        }

        return $json->encode({
            parameters => {
                nick => $server->{nick}
            }
        });

    } elsif ($method eq 'org.irssi.varlink.TestEvent') {
        # Test method to generate a fake event for testing
        my $event = {
            type => 'message',
            subtype => 'public',
            server => 'test',
            target => '#testchan',
            nick => 'testnick',
            address => 'test@host.com',
            message => $params->{message} || 'test message',
            timestamp => time()
        };

        broadcast_event($event);

        return $json->encode({
            parameters => {
                success => JSON::true
            }
        });

    } else {
        return encode_error("org.varlink.service.MethodNotFound",
            "Method '$method' not found");
    }
}

sub encode_error {
    my ($error, $description, $params) = @_;
    
    my $response = {
        error => $error
    };
    
    if ($description || $params) {
        $response->{parameters} = {};
        $response->{parameters}->{description} = $description if $description;
        if ($params && ref $params eq 'HASH') {
            %{$response->{parameters}} = (%{$response->{parameters}}, %$params);
        }
    }
    
    return $json->encode($response);
}

sub broadcast_event {
    my $event = shift;
    
    # Find waiting clients
    my @waiting_sockets = ();
    for my $client (@client_sockets) {
        if (exists $waiting_clients{$client}) {
            push @waiting_sockets, $client;
        }
    }
    
    for my $client (@waiting_sockets) {
        my $more_flag = $waiting_clients{$client};
        
        my $response = {
            parameters => {
                event => $event
            }
        };
        
        # Add continues flag only for streaming mode
        if ($more_flag eq 'streaming') {
            $response->{continues} = JSON::true;
        }
        
        my $message = $json->encode($response);
        print $client $message . "\0";  # NUL-terminate message
        $client->flush();  # Ensure data is sent immediately
        
        # For single event requests, remove from waiting immediately
        if ($more_flag eq 'single') {
            delete $waiting_clients{$client};
        }
    }
}

# Event handlers
sub create_message_event {
    my ($subtype, $server, $msg, $nick, $address, $target) = @_;
    
    my $event = {
        type => 'message',
        subtype => $subtype,
        server => $server ? $server->{tag} : 'test',
        target => $subtype eq 'public' ? $target : $nick,
        nick => $nick,
        address => $address,
        message => $msg,
        timestamp => time()
    };
    
    broadcast_event($event);
}

sub sig_message_public {
    my ($server, $msg, $nick, $address, $target) = @_;
    create_message_event('public', $server, $msg, $nick, $address, $target);
}

sub sig_message_private {
    my ($server, $msg, $nick, $address) = @_;
    create_message_event('private', $server, $msg, $nick, $address, undef);
}

# Cleanup on unload
sub UNLOAD {
    # Notify all clients that service is shutting down
    my $shutdown_error = encode_error("org.varlink.service.ServiceShutdown", "Service is shutting down");
    for my $client (@client_sockets) {
        eval {
            print $client $shutdown_error . "\0";
            $client->flush();
            # Shutdown write side to signal EOF to client
            $client->shutdown(1);  # SHUT_WR
        };
        # Remove input handler first to prevent processing during shutdown
        my $client_fd = fileno($client);
        Irssi::input_remove($client_fd) if defined $client_fd;
        close($client);
    }

    if ($server_socket) {
        Irssi::input_remove(fileno($server_socket));
        close($server_socket);
    }
    
    %client_buffers = ();  # Clear all client buffers
    %waiting_clients = ();  # Clear all waiting clients

    unlink $socket_path if -e $socket_path;
    Irssi::print("Varlink interface stopped");
}

# Initialize
create_server();

# Connect signal handlers
Irssi::signal_add('message public', 'sig_message_public');
Irssi::signal_add('message private', 'sig_message_private');

Irssi::print("Varlink interface loaded");
