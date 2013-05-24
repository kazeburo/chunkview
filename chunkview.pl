#!/usr/bin/perl

use strict;
use warnings;
use Carp;
use Log::Minimal;
use IO::Socket::INET;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use HTTP::Parser::XS qw/HEADERS_NONE HEADERS_AS_ARRAYREF HEADERS_AS_HASHREF/;
use Text::ASCIITable;
use Compress::Raw::Zlib qw(Z_OK Z_STREAM_END);
use URI::Escape qw/uri_escape/;

$Log::Minimal::AUTODUMP = 1;
my $HTTP_TOKEN         = '[^\x00-\x31\x7F]+';
my $HTTP_QUOTED_STRING = q{"([^"]+|\\.)*"};

my $url = $ARGV[0] || die "usage: $0 url";
my $timeout = 10;
my ($scheme, $host, $port, $path_query) = _parse_url($url);
$port = 80 if ! defined $port;
$path_query= '/' if ! defined $path_query;

my @header;
push @header, "GET $path_query HTTP/1.1";
push @header, 'Host: ' . $host;
push @header, 'User-Agent: Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.16) Gecko/20110319 Firefox/3.6.16';
push @header, 'Accept-Encoding: gzip';

debugf("connected to %s:%s",$host,$port);
my $client = new_client($host, $port, $timeout);
debugf("send request %s", \@header);
write_all($client, join("\015\012",@header). "\015\012\015\012", $timeout)
    or die "request timeout";

my $buf = '';
my ($res_minor_version, $res_status, $res_msg, $res_headers);
my $rest_header;
my $special_headers = +{};
$special_headers->{server}  = '';
$special_headers->{'content-encoding'}  = '';
$special_headers->{'transfer-encoding'} = '';
$special_headers->{'content-length'} = '';

while (1) {
    my $read_len = read_timeout($client, \$buf, 4096 - length($buf), length($buf), $timeout)
        or die "read timeout";
    my $ret;
    ( $ret, $res_minor_version, $res_status, $res_msg, $res_headers )
        =  HTTP::Parser::XS::parse_http_response( $buf,
                                                  HEADERS_AS_ARRAYREF, $special_headers );
    if ( $ret == -1 ) {
        die "Invalid HTTP response";
    }
    elsif ( $ret == -2 ) {
        # partial response
        next;
    }
    else {
        # succeeded
        $rest_header = substr( $buf, $ret );
        last;
    }
}

debugf "response header %s", $special_headers;
die "not successful response code: $res_status" if $res_status != '200';
die "not chunked response" if $special_headers->{'transfer-encoding'} ne 'chunked';
my $res_content = '';
my @chunk = _read_body_chunked($client,
               \$res_content, $rest_header, $timeout, $special_headers->{'content-encoding'} =~ m/(?:gzip|deflate)/);
debugf("chunk %s",\@chunk);
my $tbl = Text::ASCIITable->new({ headingText => 'Chunk View' });
$tbl->setCols('chunk size','byte','content');
$tbl->alignCol('chunk size','right');
$tbl->alignCol('byte','right');
$tbl->addRow(@{$_}) for @chunk;
print $tbl;
say "* Headers";
say "$_: ".$special_headers->{$_} for keys %{$special_headers};

sub _read_body_chunked {
    my ($sock, $res_content, $rest_header, $timeout, $is_gzip) = @_;
    my @chunk;
    my $buf = $rest_header;
    my ( $zlib, $status ) = Compress::Raw::Zlib::Inflate->new(
        -WindowBits => Compress::Raw::Zlib::WANT_GZIP_OR_ZLIB(), );

  READ_LOOP: while (1) {
        if (
            my ( $header, $next_len ) = (
                $buf =~
                  m{\A (                 # header
                        ( [0-9a-fA-F]+ ) # next_len (hex number)
                        (?:;
                            $HTTP_TOKEN
                            =
                            (?: $HTTP_TOKEN | $HTTP_QUOTED_STRING )
                        )*               # optional chunk-extentions
                        [ ]*             # www.yahoo.com adds spaces here.
                                         # Is this valid?
                        \015\012         # CR+LF
                  ) }xmso
            )
          )
        {
            $buf = substr($buf, length($header)); # remove header from buf
            push @chunk, [$next_len,hex($next_len)];
            $next_len = hex($next_len);
            if ($next_len == 0) {
                last READ_LOOP;
            }

            # +2 means trailing CRLF
          READ_CHUNK: while ( $next_len+2 > length($buf) ) {
                my $n = read_timeout( $sock,
                    \$buf, 10240, length($buf), $timeout );
                if (!$n) {
                    die "cannot read chunk";
                }
            }
            my $chunk_content = substr($buf, 0, $next_len);
            if ( $is_gzip ) {
                $zlib->inflate( $chunk_content, \my $deflated );
                my $dlen = length $deflated;
                push @{$chunk[-1]}, uri_escape(substr($deflated,0,20),"\x00-\x1f\x7f-\xff") . "($dlen)";
                
            }
            else {
                push @{$chunk[-1]}, uri_escape(substr($chunk_content,0,20),"\x00-\x1f\x7f-\xff");
            }
            $$res_content .= $chunk_content;
            $buf = substr($buf, $next_len+2);
            if (length($buf) > 0) {
                next; # re-parse header
            }
        }

        my $n = read_timeout( $sock,
            \$buf, 10240, length($buf), $timeout );
        if (!$n) {
            die "cannot read chunk";
        }
    }
    return @chunk;
}


# returns $scheme, $host, $port, $path_query
sub _parse_url {
    my($url) = @_;
    $url =~ m{\A
        ([a-z]+)                    # scheme
        ://
        ([^/:?]+)                   # host
        (?: : (\d+) )?              # port
        (?: ( /? \? .* | / .*)  )?  # path_query
    \z}xms or Carp::croak("Passed malformed URL: $url");
    return( $1, $2, $3, $4 );
}


sub new_client {
    my ($host, $port, $timeout) = @_;

    my $sock = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Timeout  => $timeout, 
        Proto    => 'tcp',
    ) or die "Cannot open client socket: $!\n";

    setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;
    $sock->autoflush(1);
    $sock;
}

# returns (positive) number of bytes read, or undef if the socket is to be closed
sub read_timeout {
    my ($sock, $buf, $len, $off, $timeout) = @_;
    do_io(undef, $sock, $buf, $len, $off, $timeout);
}

# returns (positive) number of bytes written, or undef if the socket is to be closed
sub write_timeout {
    my ($sock, $buf, $len, $off, $timeout) = @_;
    do_io(1, $sock, $buf, $len, $off, $timeout);
}

# writes all data in buf and returns number of bytes written or undef if failed
sub write_all {
    my ($sock, $buf, $timeout) = @_;
    my $off = 0;
    while (my $len = length($buf) - $off) {
        my $ret = write_timeout($sock, $buf, $len, $off, $timeout)
            or return;
        $off += $ret;
    }
    return length $buf;
}

# returns value returned by $cb, or undef on timeout or network error
sub do_io {
    my ($is_write, $sock, $buf, $len, $off, $timeout) = @_;
    my $ret;
 DO_READWRITE:
    # try to do the IO
    if ($is_write) {
        $ret = syswrite $sock, $buf, $len, $off
            and return $ret;
    } else {
        $ret = sysread $sock, $$buf, $len, $off
            and return $ret;
    }
    unless ((! defined($ret)
                 && ($! == EINTR || $! == EAGAIN || $! == EWOULDBLOCK))) {
        return;
    }
    # wait for data
 DO_SELECT:
    while (1) {
        my ($rfd, $wfd);
        my $efd = '';
        vec($efd, fileno($sock), 1) = 1;
        if ($is_write) {
            ($rfd, $wfd) = ('', $efd);
        } else {
            ($rfd, $wfd) = ($efd, '');
        }
        my $start_at = time;
        my $nfound = select($rfd, $wfd, $efd, $timeout);
        $timeout -= (time - $start_at);
        last if $nfound;
        return if $timeout <= 0;
    }
    goto DO_READWRITE;
}

