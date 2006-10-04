package POE::Wheel::UDP;

=head1 NAME

POE::Wheel::UDP - POE Wheel for UDP handling.

=head1 SYNOPSIS

  use POE;
  use POE::Wheel::UDP;
  
  POE::Session->create(
    inline_states => {
      _start => sub {
        my $wheel = $_[HEAP]->{wheel} = POE::Wheel::UDP->new(
	  LocalAddr => '10.0.0.1',
	  LocalPort => 1234,
	  PeerAddr => '10.0.0.2',
	  PeerPort => 1235,
	  InputEvent => 'input',
	);
	$wheel->put(
	  {
            payload => 'This datagram will go to the default address.',
	  },
	  {
            payload => 'This datagram will go to the explicit address and port I have paired with it.',
	    addr => '10.0.0.3',
	    port => 1236,
	  },
	);
      },
      input => sub {
      	my ($wheel_id, $input) = @_[ARG0, ARG1];
	print "Incoming datagram from $input->{addr}:$input->{port}: '$input->{payload}'\n";
      },
    }
  );

  POE::Kernel->run;

=head1 DESCRIPTION

POE Wheel for UDP handling.

=cut

use 5.006; # I don't plan to support old perl
use strict;
use warnings;

use base 'POE::Wheel';

use POE;
use Carp;
use Socket;
use Fcntl;

our $VERSION = '0.00_01';
$VERSION = eval $VERSION;  # see L<perlmodstyle>

=head1 Package Methods

=head2 $wheel = POE::Wheel::UDP->new( OPTIONS );

Constructor for a new UDP Wheel object. OPTIONS is a key => value pair list specifying the following options:

=over

=item LocalAddr (required)

=item LocalPort (required)

Specify the local IP address and port for the created socket. LocalAddr should be in dotted-quad notation,
and LocalPort should be an integer. This module will not resolve names to numbers at all.

=item PeerAddr (optional)

=item PeerPort (optional)

Specify the remote IP address and port for the created socket. As above, PeerAddr should be in dotted-quad
notation, and PeerPort should be an integer. No names will be resolved. These arguments are optional, and if
not specified a pair will be required during the ->put() call.

=item InputEvent (optional)

Specify the event to be invoked via Kernel->yield when a packet arrives on this socket. Currently all incoming
data is truncated to 1500 bytes. If you do not specify an event, the wheel will not ask the kernel to pass
incoming datagrams to it, and therefore this wheel will not hold your session alive.

=back

=cut

sub new {
	my $class = shift;
	carp( "Uneven set of options passed to ${class}->new." ) unless (@_ % 2 == 0);
	my %opts = @_;
	
	my $self = bless { }, (ref $class || $class);

	my %sockopts;

	foreach (qw(LocalAddr LocalPort PeerAddr PeerPort)) {
		$sockopts{$_} = $opts{$_} if exists( $opts{$_} );
	}

	$self->_open( %sockopts );

	my $id = $self->{id} = $self->SUPER::allocate_wheel_id();
	my $read_event = $self->{read_event} = ref($self) . "($id) -> select read";
	my $write_event = $self->{write_event} = ref($self) . "($id) -> select write";

	if (exists( $opts{InputEvent} )) {
		my $input_event = $self->{InputEvent} = $opts{InputEvent};

		$poe_kernel->state( $read_event, sub {
			my ($kernel, $socket) = @_[KERNEL, ARG0];
			$! = undef;
			while( my $addr = recv( $socket, my $input, 1500, MSG_DONTWAIT ) ) {
				if (defined( $addr )) {
					my $thing = {
						payload => $input,
					};

					if ($addr) {
						my ($port, $addr) = sockaddr_in( $addr )
							or warn( "sockaddr_in failure: $!" );
						$thing->{addr} = inet_ntoa( $addr );
						$thing->{port} = $port;
					}
					
					$poe_kernel->yield( $input_event, $thing, $id );
				}
				else {
					warn "recv failure: $!";
					next
				}
			}
		} );
		
		$poe_kernel->select_read( $self->{sock}, $read_event );
	}

#	Does anyone know if I should watch for writability on the socket at all? it's pretty hard to test
#	to see if UDP can ever return EAGAIN because I can't get it to go fast enough to blast past the buffers.

	return $self;
}

sub _open {
	my $self = shift;
	my %opts = @_;
	
	my $proto = getprotobyname( "udp" );
	
	socket( my $sock, PF_INET, SOCK_DGRAM, $proto )
		or die( "socket() failure: $!" );

	fcntl( $sock, F_SETFL, O_NONBLOCK | O_RDWR )
		or die( "fcntl problem: $!" );
		
	{
		my $addr = inet_aton( $opts{LocalAddr} )
			or die( "inet_aton problem: $!" );
		my $sockaddr = sockaddr_in( $opts{LocalPort}, $addr )
			or die( "sockaddr_in problem: $!" );
		bind( $sock, $sockaddr )
			or die( "bind error: $!" );
	}

	if ($opts{PeerAddr} and $opts{PeerPort}) {
		my $addr = inet_aton( $opts{PeerAddr} )
			or die( "inet_aton problem: $!" );
		my $sockaddr = sockaddr_in( $opts{PeerPort}, $addr )
			or die( "sockaddr_in problem: $!" );
		connect( $sock, $sockaddr )
			or die( "connect error: $!" );
	}

	return $self->{sock} = $sock;
}

=head1 Object Methods

=head2 $wheel->put( LIST )

Returns the total number of bytes sent in this call, which may not match the number of bytes
you passed in for payloads due to send(2) semantics. Takes a list of hashrefs with the
following useful keys in them:

=over

=item payload

The actual data you wish to send in the packet.

=item addr

=item port

Specify a destination IP address and port for this specific packet. Optional if you specified
a PeerAddr and PeerPort in the wheel constructor; Required if you did not.

=back

=cut

sub put {
	my $self= shift;

	my $sock = $self->{sock};
	my $total_bytes = 0;

	while (my $thing = shift) {
		if (!defined( $thing )) {
			warn "Undefined argument, ignoring";
			next;
		}

		if (ref( $thing ) ne 'HASH') {
			warn "Non-hasref argument, ignoring";
			next;
		}

		my $payload = $thing->{payload} or die;
		
		my $bytes;
		if (exists( $thing->{addr} ) or exists( $thing->{port} )) {
			my $addr = $thing->{addr} or die;
			my $port = $thing->{port} or die;
			$bytes = send( $sock, $payload, MSG_DONTWAIT, sockaddr_in( $port,inet_aton( $addr ) ) );
		}
		else {
			$bytes = send( $sock, $payload, MSG_DONTWAIT );
		}

		if (!defined( $bytes )) {
			die( "send() failed: $!" );
			# if we ever remove fatal handling of this, do the following:
			# push current thing onto buffer.
			# last;
		}
		$total_bytes += $bytes;
	}

	# push rest of @_ onto buffer

	return $total_bytes;
}

sub DESTROY {
	my $self = shift;
	if ($self->{read_event}) {
		$poe_kernel->state( delete $self->{read_event} );
		$poe_kernel->select_read( $self->{sock} );
	}
	$self->SUPER::free_wheel_id( delete $self->{id} );
}

sub allocate_wheel_id; # try to cancel this method from being inhereted.
sub free_wheel_id;

1;
__END__

=head1 Events

=head2 InputEvent

=over

=item ARG0

Contains a hashref with the following keys:

=over

=item addr

=item port

Specifies the address and port from which we received this datagram.

=item payload

The actual contents of the datagram.

=back

=item ARG1

The wheel id for the wheel that fired this event.

=back

=head1 UPCOMING FEATURES

=over

=item *

CFEDDE would like to see filter support in the UDP wheel... I would love to have a piece of pie. Let's see who gets what they want first.

=item *

IPV6 support.

=item *

TTL changing support.

=back

=head1 SEE ALSO

POE

=head1 AUTHOR

Jonathan Steinert E<lt>hachi@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Jonathan Steinert... or Six Apart... I don't know who owns me when I'm at home. Oh well.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
