package Net::HTTP;

# $Id: HTTP.pm,v 1.16 2001/04/13 06:53:52 gisle Exp $

use strict;
use vars qw($VERSION @ISA);

$VERSION = "0.02";
require IO::Socket::INET;
@ISA=qw(IO::Socket::INET);

my $CRLF = "\015\012";   # "\r\n" is not portable

sub configure {
    my($self, $cnf) = @_;
    my $host = delete $cnf->{Host};
    my $peer = $cnf->{PeerAddr} || $cnf->{PeerHost};
    if ($host) {
	$cnf->{PeerHost} = $host unless $peer;
    }
    else {
	$host = $peer;
	$host =~ s/:.*//;
    }
    $cnf->{PeerPort} = 80 unless $cnf->{PeerPort};

    my $keep_alive = delete $cnf->{KeepAlive};
    my $http_version = delete $cnf->{HTTPVersion};
    $http_version = "1.1" unless defined $http_version;
    my $peer_http_version = delete $cnf->{PeerHTTPVersion};
    $peer_http_version = "1.0" unless defined $peer_http_version;

    my $sock = $self->SUPER::configure($cnf);
    if ($sock) {
	unless ($host =~ /:/) {
	    my $p = $sock->peerport;
	    $host .= ":$p"; # if $p != 80;
	}
	$sock->host($host);
	$sock->keep_alive($keep_alive);
	$sock->http_version($http_version);
	$sock->peer_http_version($peer_http_version);

	${*$self}{'http_buf'} = "";
    }
    return $sock;
}

sub host {
    my $self = shift;
    my $old = ${*$self}{'http_host'};
    ${*$self}{'http_host'} = shift if @_;
    $old;
}

sub keep_alive {
    my $self = shift;
    my $old = ${*$self}{'http_keep_alive'};
    ${*$self}{'http_keep_alive'} = shift if @_;
    $old;
}

sub http_version {
    my $self = shift;
    my $old = ${*$self}{'http_version'};
    if (@_) {
	my $v = shift;
	$v = "1.0" if $v eq "1";  # float
	unless ($v eq "1.0" or $v eq "1.1") {
	    require Carp;
	    Carp::croak("Unsupported HTTP version '$v'");
	}
	${*$self}{'http_version'} = $v;
    }
    $old;
}

sub peer_http_version {
    my $self = shift;
    my $old = ${*$self}{'http_peer_version'};
    ${*$self}{'http_peer_version'} = shift if @_;
    $old;
}


sub format_request {
    my $self = shift;
    my $method = shift;
    my $uri = shift;

    my $content = (@_ % 2) ? pop : "";

    for ($method, $uri) {
	require Carp;
	Carp::croak("Bad method or uri") if /\s/ || !length;
    }

    push(@{${*$self}{'http_request_method'}}, $method);
    my $ver = ${*$self}{'http_version'};
    my $peer_ver = ${*$self}{'http_peer_version'} || "1.0";

    my @h;
    my @connection;
    my %given = (host => 0, "content-length" => 0);
    while (@_) {
	my($k, $v) = splice(@_, 0, 2);
	my $lc_k = lc($k);
	if ($lc_k eq "connection") {
	    push(@connection, split(/\s*,\s*/, $v));
	    next;
	}
	if (exists $given{$lc_k}) {
	    $given{$lc_k}++;
	}
	push(@h, "$k: $v");
    }

    if (length($content) && !$given{'content-length'}) {
	push(@h, "Content-Length: " . length($content));
    }

    my @h2;
    unless (grep lc($_) eq "close", @connection) {
	if ($self->keep_alive) {
	    if ($peer_ver eq "1.0") {
		# from looking at Netscape's headers
		push(@h2, "Keep-Alive: 300");
		push(@connection, "Keep-Alive");
	    }
	}
	else {
	    push(@connection, "close") if $ver ge "1.1";
	}
    }
    push(@h2, "Connection: " . join(", ", @connection)) if @connection;
    push(@h2, "Host: ${*$self}{'http_host'}")unless $given{host};

    return join($CRLF, "$method $uri HTTP/$ver", @h2, @h, "", $content);
}


sub write_request {
    my $self = shift;
    print $self $self->format_request(@_);
}


sub xread {
    sysread($_[0], $_[1], $_[2], $_[3] || 0);
}


sub my_read {
    die if @_ > 3;
    my $self = shift;
    my $len = $_[1];
    for (${*$self}{'http_buf'}) {
	if (length) {
	    $_[0] = substr($_, 0, $len, "");
	    return length($_[0]);
	}
	else {
	    return $self->xread($_[0], $len);
	}
    }
}


sub my_readline {
    my $self = shift;
    for (${*$self}{'http_buf'}) {
	my $pos;
	while (1) {
	    $pos = index($_, "\012");
	    last if $pos >= 0;
	    my $n = $self->xread($_, 1024, length);
	    if (!$n) {
		return undef unless length;
		return substr($_, 0, length, "");
	    }
	}
	my $line = substr($_, 0, $pos+1, "");
	$line =~ s/\015?\012\z//;
	return $line;
    }
}



sub read_header_lines {
    my $self = shift;
    my @headers;
    while (my $line = my_readline($self)) {
	if ($line =~ /^(\S+)\s*:\s*(.*)/s) {
	    push(@headers, $1, $2);
	}
	elsif (@headers && $line =~ s/^\s+//) {
	    $headers[-1] .= " " . $line;
	}
	else {
	    die "Bad header: $line\n";
	}
    }
    return @headers;
}


sub read_response_headers {
    my $self = shift;
    my $status = my_readline($self);
    die "EOF instead of reponse status line" unless defined $status;
    my($peer_ver, $code, $message) = split(' ', $status, 3);
    die "Bad response status line: $status" unless $peer_ver =~ s,^HTTP/,,;
    ${*$self}{'http_peer_version'} = $peer_ver;
    ${*$self}{'http_status'} = $code;
    my @headers = $self->read_header_lines;

    # pick out headers that read_entity_body might need
    my @te;
    my $content_length;
    for (my $i = 0; $i < @headers; $i += 2) {
	my $h = lc($headers[$i]);
	if ($h eq 'transfer-encoding') {
	    push(@te, $headers[$i+1]);
	}
	elsif ($h eq 'content-length') {
	    $content_length = $headers[$i+1];
	}
    }
    ${*$self}{'http_te'} = join("", @te);
    ${*$self}{'http_content_length'} = $content_length;
    ${*$self}{'http_first_body'}++;
    delete ${*$self}{'http_trailers'};
    return ($code, $message, @headers);
}


sub read_entity_body {
    my $self = shift;
    my $buf_ref = \$_[0];
    my $size = $_[1];

    my $chunked;
    my $bytes;

    if (${*$self}{'http_first_body'}) {
	${*$self}{'http_first_body'} = 0;
	my $method = shift(@{${*$self}{'http_request_method'}});
	my $status = ${*$self}{'http_status'};
	if ($method eq "HEAD" || $status =~ /^(?:1|[23]04)/) {
	    # these responses are always empty
	    $bytes = 0;
	}
	elsif (my $te = ${*$self}{'http_te'}) {
	    die "Don't know about transfer encoding '$te'"
		unless $te eq "chunked";
	    $chunked = -1;
	}
	elsif (defined(my $content_length = ${*$self}{'http_content_length'})) {
	    $bytes = $content_length;
	}
	else {
	    # XXX Multi-Part types are self delimiting, but RFC 2616 says we
	    # only has to deal with 'multipart/byteranges'

	    # Read until EOF
	}
    }
    else {
	$chunked = ${*$self}{'http_chunked'};
	$bytes   = ${*$self}{'http_bytes'};
    }

    if (defined $chunked) {
	if ($chunked <= 0) {
	    my $line = my_readline($self);
	    if ($chunked == 0) {
		die "Not empty: '$line'" unless $line eq "";
		$line = my_readline($self);
	    }
	    $line =~ s/;.*//;  # ignore potential chunk parameters
	    $line =~ s/\s+$//; # avoid warnings from hex()
	    $chunked = hex($line);
	    if ($chunked == 0) {
		${*$self}{'http_trailers'} = [$self->read_header_lines];
		$$buf_ref = "";
		return 0;
	    }
	}

	my $n = $chunked;
	$n = $size if $size && $size < $n;
	$n = my_read($self, $$buf_ref, $n);
	${*$self}{'http_chunked'} = $chunked - $n;
	return $n;
    }
    elsif (defined $bytes) {
	return 0 unless $bytes;
	my $n = $bytes;
	$n = $size if $size && $size < $n;
	$n = my_read($self, $$buf_ref, $n);
	${*$self}{'http_bytes'} = $bytes - $n;
	return $n;
    }
    else {
	# read until eof
	$size ||= 8*1024;
	return my_read($self, $$buf_ref, $size);
    }
}

sub get_trailers {
    my $self = shift;
    @{${*$self}{'http_trailers'} || []};
}

1;

__END__

=head1 NAME

Net::HTTP - HTTP client connection

=head1 SYNOPSIS

 use Net::HTTP;
 my $s = Net::HTTP->new(Host => "www.perl.com) || die $@;
 $s->write_request(GET => "/", 'User-Agent' => "Mozilla/5.0");
 my($code, $mess, %h) = $s->read_response_headers;

 while (1) {
    my $buf;
    my $n = $s->read_entity_body($buf, 1024);
    last unless $n;
    print $buf;
 }

=head1 DESCRIPTION

The C<Net::HTTP> class is a low-level HTTP client.  An instance of the
C<Net::HTTP> class represents a connection to an HTTP server.  The
HTTP protocol is described in RFC 2616.

C<Net::HTTP> is a sub-class of C<IO::Socket::INET>.  You can mix the
methods described below with reading and writing from the socket
directly.

The follwing methods are provided (in addition to those of
C<IO::Socket::INET>):

=over

=item $s = Net::HTTP->new( %options )

The C<Net::HTTP> constructor takes the same options as
C<IO::Socket::INET> as well as these:

  Host:            Initial host attribute value
  KeepAlive:       Initial keep_alive attribute value
  HTTPVersion:     Initial http_version attribute value
  PeerHTTPVersion: Initial peer_http_version attribute value

=item $s->host

Get/set the default value of the C<Host> header to send.

=item $s->keep_alive

Get/set the I<keep-alive> value.  If this value is TRUE then the
request will sendt with headers indicating that the server should try
to keep the connection open.

=item $s->http_version

Get/set the HTTP version number that this client should announce.
This value can only be set to "1.0" or "1.1".  The default is "1.1".

=item $s->peer_http_version

Get/set the protocol version number of our peer.  This value will
initially be "1.0", but will be updated by a successful
read_response_headers() method call.  The value of this header
influence what headers are added to the request on I<keep-alive>.

=item $s->format_request($method, $uri, %headers, [$content])

Format a request message and return it as a string.  If the headers do
not include a C<Host> header, then a header is inserted with the value
of the C<host> attribute.  Headers like C<Connection> and
C<Keep-Alive> might also be added depending on the I<keep-alive>
status.

If $content is given (and it is non-empty), then a C<Content-Length>
header is automatically added unless it was already present.

=item $s->write_request($method, $uri, %headers, [$content])

Format and send a request message.  Arguments are the same as for
format_request().  Returns true if successful.

=item ($code, $mess, %headers) = $s->read_response_headers

Read response headers from server.

=item $n = $s->read_entity_body($buf, $size);

Reads chunks of the entity body content.  Basically the same interface
as for read() and sysread(), but buffer offset is not supported yet.

=item %headers = $s->get_trailers

After read_entity_body() has returned 0 to indicate end of the entity
body, you might call this method to pick up any trailers.

=back

=head1 SUBCLASSING

The read_response_headers() and read_entity_body() will invoke the
method xread() when they need more data.  This method takes the same
arguments as sysread() and the is in fact implemented as a call to
sysread().  Subclasses might want to override this method to contol
how reading takes place.

The object itself is a glob.

=head1 SEE ALSO

L<LWP>, L<IO::Socket::INET>, L<Net::HTTP::NB>

=head1 COPYRIGHT

Copyright 2001 Gisle Aas.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut