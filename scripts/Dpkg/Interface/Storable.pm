# Copyright © 2010 Raphaël Hertzog <hertzog@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

package Dpkg::Interface::Storable;

use strict;
use warnings;

our $VERSION = '1.00';

use Carp;

use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Compression::FileHandle;

use overload
    '""' => \&_stringify,
    'fallback' => 1;

=encoding utf8

=head1 NAME

Dpkg::Interface::Storable - common methods related to object serialization

=head1 DESCRIPTION

Dpkg::Interface::Storable is only meant to be used as parent
class for other objects. It provides common methods that are
all implemented on top of two basic methods parse() and output().

=head1 BASE METHODS

Those methods must be provided by the object that wish to inherit
from Dpkg::Interface::Storable so that the methods provided can work.

=over 4

=item $obj->parse($fh, $desc)

This methods initialize the object with the data stored in the
filehandle. $desc is optional and is a textual description of
the filehandle used in error messages.

=item $string = $obj->output($fh)

This method returns a string representation of the object in $string
and it writes the same string to $fh (if it's defined).

=back

=head1 PROVIDED METHODS

=over 4

=item $obj->load($filename)

Initialize the object with the data stored in the file. The file can be
compressed, it will be uncompressed on the fly by using a
Dpkg::Compression::FileHandle object. If $filename is "-", then the
standard input is read (no compression is allowed in that case).

=cut

sub load {
    my ($self, $file, @options) = @_;
    unless ($self->can('parse')) {
	croak ref($self) . ' cannot be loaded, it lacks the parse method';
    }
    my ($desc, $fh) = ($file, undef);
    if ($file eq '-') {
	$fh = \*STDIN;
	$desc = g_('<standard input>');
    } else {
	$fh = Dpkg::Compression::FileHandle->new();
	open($fh, '<', $file) or syserr(g_('cannot read %s'), $file);
    }
    my $res = $self->parse($fh, $desc, @options);
    if ($file ne '-') {
	close($fh) or syserr(g_('cannot close %s'), $file);
    }
    return $res;
}

=item $obj->save($filename)

Store the object in the file. If the filename ends with a known
compression extension, it will be compressed on the fly by using a
Dpkg::Compression::FileHandle object. If $filename is "-", then the
standard output is used (data are written uncompressed in that case).

=cut

sub save {
    my ($self, $file, @options) = @_;
    unless ($self->can('output')) {
	croak ref($self) . ' cannot be saved, it lacks the output method';
    }
    my $fh;
    if ($file eq '-') {
	$fh = \*STDOUT;
    } else {
	$fh = Dpkg::Compression::FileHandle->new();
	open($fh, '>', $file) or syserr(g_('cannot write %s'), $file);
    }
    $self->output($fh, @options);
    if ($file ne '-') {
	close($fh) or syserr(g_('cannot close %s'), $file);
    }
}

=item "$obj"

Return a string representation of the object.

=cut

sub _stringify {
    my $self = shift;
    unless ($self->can('output')) {
	croak ref($self) . ' cannot be stringified, it lacks the output method';
    }
    return $self->output();
}

=back

=head1 CHANGES

=head2 Version 1.00

Mark the module as public.

=head1 AUTHOR

Raphaël Hertzog <hertzog@debian.org>.

=cut

1;
