package Text::vFile::asData;
use strict;
use warnings;
no warnings 'uninitialized';
use Text::ParseWords qw( parse_line );
our $VERSION = '0.01';

=head1 NAME

Text::vFile::asData - parse vFile formatted files into data structures

=head1 SYNOPSIS

  use Text::vFile::asData;
  open my $fh, "foo.ics"
    or die "couldn't open ics: $!";
  my $data = Text::vFile::asData->new->parse( $fh );

=head1 DESCRIPTION

Text::vFile::asData reads vFile format files, such as vCard (RFC 2426) and
vCalendar (RFC 2445).

=cut

sub new {
    my $class = shift;
    return bless {}, ref $class || $class;
}

sub _lines_from_fh {
    my $self = shift;
    my $fh = shift;

    return map { chomp; s/\r$//; $_ } <$fh>;
}

sub _unwrap_lines {
    my $self = shift;
    my @lines;
    for (@_) {
        if (/^\s(.*)/) { # Continuation line (RFC Sect. 4.1)
            die "Continuation line, but no preceding line" unless @lines;
            $lines[-1] .= $1;
            next;
        }
        push @lines, $_;
    }
    return @lines;
}

sub parse {
    my $self = shift;
    my $fh = shift;
    return $self->parse_lines( $self->_lines_from_fh( $fh ) );
}

sub parse_lines {
    my $self = shift;

    my @path;
    my $current;
    for ($self->_unwrap_lines( @_ )) {
        $_ = $self->_decode_line($_) if /\000/;

        # Ignore leading or trailing blank lines at the top/bottom of the
        # input.  Not sure about completely blank lines within the input
        next if scalar @path == 0 and $_ =~ /^\s*$/;

        if (/^BEGIN:(.*)/) {
            push @path, $current;
            $current = { type => $1 };
            push @{ $path[-1]{objects} }, $current;
            next;
        }
        if (/^END:(.*)/) {
            die "END $1 in $current->{type}" unless $current->{type} eq $1;
            $current = pop @path;
            next;
        }

        # Text::ParseWords really needs a limit argument, like split,
        # to say "into at most $n hunks" - here we'd want 2 rather
        # than the extra work of the join
        my ($name, @values) = parse_line( ':', 1, $_ );
        my $value = join(':', @values);

        unless ($name) {
            # Text::ParseWords seems to get confused if there are no
            # quoted words

            # print "didn't parse a name from '$_'\n";
            # next;
            ($name, $value) = split /:/, $_, 2;
        }
        my @params = parse_line( ';', 0, $name);
        $name = shift @params;

        $value = { value => $value };

        if (@params) {
            foreach my $param (@params) {
                my ($p_name, $p_value) = split /=/, $param;
                $value->{param}{ $p_name } = $p_value;
            }
        }
        push @{ $current->{properties}{ $name } }, $value;
    }

    return $current;
}

# this might not strictly comply, certainly it doesn't wrap.
sub generate_lines {
    my $self = shift;
    my $this = shift;

    my @lines;
    # XXX all the existence checks are to prevent auto-vivifaction
    # breaking if_diff tests - do we mind, or should the fields have been
    # there anyway?

    push @lines, "BEGIN:$this->{type}" if exists $this->{type};
    if (exists $this->{properties}) {
        while (my ($name, $v) = each %{ $this->{properties} } ) {
            for my $value (@$v) {
                my $param = '';
                if ($value->{param}) {
                    $param = join ';', '', map {
                        "$_" . (defined $value->{param}{$_}
                                  ?  "=" . $value->{param}{$_} : "")
                    } keys %{ $value->{param} };
                }
                push @lines, "$name$param:$value->{value}";
            }
        }
    }

    if (exists $this->{objects}) {
        push @lines, $self->generate_lines( $_ ) for @{ $this->{objects} }
    }
    push @lines, "END:$this->{type}" if exists $this->{type};
    return @lines;
}

# Cargo-culted from Text::vFile
sub _decode_line {
    my $self = shift;
    my $line = shift;

    eval "use Encode;";
    die "Cannot decode this file - need the Encode module; $@\n" if $@;

    my $decoder;

    if ($line =~ /\000\000\000/) {
        if ($line = /^\000/) {
            $decoder = Encode::find_encoding('UTF-32BE');
        }
        else {
            $decoder = Encode::find_encoding('UTF-32LE');
        }
    }
    else {
        if ($line = /^\000/) {
            $decoder = Encode::find_encoding('UTF-16BE');
        }
        else {
            $decoder = Encode::find_encoding('UTF-16LE');
        }
    }

    $line = $decoder->decode($line) if $decoder;
    return $line;
}

1;
__END__

=head1 DATA STRUCTURE

A vFile contains one or more objects, delimited by BEGIN and END tags.

  BEGIN:VCARD
  ...
  END:VCARD

Objects may contain sub-objects;

  BEGIN:VCALENDAR
  ...
  BEGIN:VEVENT
  ...
  END:VEVENT
  ...
  ENV:VCALENDAR

Each object consists of one or more properties.  Each property
consists of a name, zero or more optional parameters, and then a
value.  This fragment:

  DTSTART;VALUE=DATE:19970317

identifies a property with the name, C<DSTART>, the parameter
C<VALUE>, which has the value C<DATE>, and the property's value is
C<19970317>.  Those of you with an XML bent might find this more
recognisable as:

  <dtstart value="date">19970317</dtstart>

The return value from the C<parse()> method is a hash ref.

The top level key, C<objects>, refers to an array ref.  Each entry in the
array ref is a hash ref with two or three keys.

The value of the first key, C<type>, is a string corresponding to the
type of the object.  E.g., C<VCARD>, C<VEVENT>, and so on.

The value of the second key, C<properties>, is a hash ref, with property
names as keys, and an array ref of those property values.  It's an array
ref, because some properties may appear within an object multiple times
with different values.  For example;

  BEGIN:VEVENT
  ATTENDEE;CN="Nik Clayton":mailto:nik@FreeBSD.org
  ATTENDEE;CN="Richard Clamp":mailto:richardc@unixbeard.net
  ...
  END:VEVENT

Each entry in the array ref is a hash ref with one or two keys.

The first key, C<value>, corresponds to the property's value.

The second key, C<param>, contains a hash ref of the property's parameters.
Keys in this hash ref are the parameter's name, the value is the parameter's
value.

The third key in the top level C<objects> hash ref is C<objects>.  If
it exists, it indicates that sub-objects were found.  The value of
this key is an array ref of sub-objects, with identical keys and
behaviour to that of the top level C<objects> key.  This recursive
structure continues, nesting as deeply as there were sub-objects in
the input file.

The C<examples/v2yaml> script that comes with this distribution displays the
format of a vFile as YAML.  C<t/03usage.t> has examples of picking out
the relevant information from the data structure.

=head1 AUTHORS

Richard Clamp <richardc@unixbeard.net> and Nik Clayton <nik@FreeBSD.org>

Copyright 2004, Richard Clamp and Nik Clayton.  All Rights Reserved.

This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 TODO

=over

=item

More comprehensive tests, especially for the nacsent generate routine.

=item

Write some higher-level modules that use this to create DateTime::*
objects via DateTime::Format::ICal and DateTime::Event::ICal for
vCalendar handling.

=item

Figure out if the Encode cargo is really cargo.

=item

Take over the world.

=back

=head1 CAVEATS

We don't do any decoding of property values, including descaping
C<\,>, we're still undecided as to whether this is a bug.

=head1 BUGS

Aside from the TODO list items, none known.

Bugs should be reported to me via the CPAN RT system.
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Text::vFile::asData>.

=head1 SEE ALSO

Text::vFile - parses to objects, doesn't handle nested items

RFC 2426 - vCard specification

RFC 2445 - vCalendar specification

=cut

# Emacs local variables to keep the style consistent

  Local Variables:
  cperl-indent-level: 4
  End:
