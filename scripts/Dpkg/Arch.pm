# Copyright © 2006-2015 Guillem Jover <guillem@debian.org>
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

package Dpkg::Arch;

use strict;
use warnings;

our $VERSION = '0.01';
our @EXPORT_OK = qw(
    get_raw_build_arch
    get_raw_host_arch
    get_build_arch
    get_host_arch
    get_gcc_host_gnu_type
    get_valid_arches
    debarch_eq
    debarch_is
    debarch_is_wildcard
    debarch_is_concerned
    debarch_to_cpuattrs
    debarch_to_gnutriplet
    debarch_to_debtriplet
    debarch_to_multiarch
    debtriplet_to_debarch
    debtriplet_to_gnutriplet
    gnutriplet_to_debarch
    gnutriplet_to_debtriplet
    gnutriplet_to_multiarch
);

use Exporter qw(import);
use POSIX qw(:errno_h);

use Dpkg ();
use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Util qw(:list);
use Dpkg::BuildEnv;

my (@cpu, @os);
my (%cputable, %ostable);
my (%cputable_re, %ostable_re);
my (%cpubits, %cpuendian);
my %abibits;

my %debtriplet_to_debarch;
my %debarch_to_debtriplet;

{
    my $build_arch;
    my $host_arch;
    my $gcc_host_gnu_type;

    sub get_raw_build_arch()
    {
	return $build_arch if defined $build_arch;

	# Note: We *always* require an installed dpkg when inferring the
	# build architecture. The bootstrapping case is handled by
	# dpkg-architecture itself, by avoiding computing the DEB_BUILD_
	# variables when they are not requested.

	$build_arch = `dpkg --print-architecture`;
	syserr('dpkg --print-architecture failed') if $? >> 8;

	chomp $build_arch;
	return $build_arch;
    }

    sub get_build_arch()
    {
	return Dpkg::BuildEnv::get('DEB_BUILD_ARCH') || get_raw_build_arch();
    }

    sub get_gcc_host_gnu_type()
    {
	return $gcc_host_gnu_type if defined $gcc_host_gnu_type;

	$gcc_host_gnu_type = `\${CC:-gcc} -dumpmachine`;
	if ($? >> 8) {
	    $gcc_host_gnu_type = '';
	} else {
	    chomp $gcc_host_gnu_type;
	}

	return $gcc_host_gnu_type;
    }

    sub get_raw_host_arch()
    {
	return $host_arch if defined $host_arch;

	$gcc_host_gnu_type = get_gcc_host_gnu_type();

	if ($gcc_host_gnu_type eq '') {
	    warning(g_("couldn't determine gcc system type, falling back to " .
	               'default (native compilation)'));
	} else {
	    my (@host_archtriplet) = gnutriplet_to_debtriplet($gcc_host_gnu_type);
	    $host_arch = debtriplet_to_debarch(@host_archtriplet);

	    if (defined $host_arch) {
		$gcc_host_gnu_type = debtriplet_to_gnutriplet(@host_archtriplet);
	    } else {
		warning(g_('unknown gcc system type %s, falling back to ' .
		           'default (native compilation)'), $gcc_host_gnu_type);
		$gcc_host_gnu_type = '';
	    }
	}

	if (!defined($host_arch)) {
	    # Switch to native compilation.
	    $host_arch = get_raw_build_arch();
	}

	return $host_arch;
    }

    sub get_host_arch()
    {
	return Dpkg::BuildEnv::get('DEB_HOST_ARCH') || get_raw_host_arch();
    }
}

sub get_valid_arches()
{
    read_cputable();
    read_ostable();

    my @arches;

    foreach my $os (@os) {
	foreach my $cpu (@cpu) {
	    my $arch = debtriplet_to_debarch(split(/-/, $os, 2), $cpu);
	    push @arches, $arch if defined($arch);
	}
    }

    return @arches;
}

my %table_loaded;
sub load_table
{
    my ($table, $loader) = @_;

    return if $table_loaded{$table};

    local $_;
    local $/ = "\n";

    open my $table_fh, '<', "$Dpkg::DATADIR/$table"
	or syserr(g_('cannot open %s'), $table);
    while (<$table_fh>) {
	$loader->($_);
    }
    close $table_fh;

    $table_loaded{$table} = 1;
}

sub read_cputable
{
    load_table('cputable', sub {
	if (m/^(?!\#)(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/) {
	    $cputable{$1} = $2;
	    $cputable_re{$1} = $3;
	    $cpubits{$1} = $4;
	    $cpuendian{$1} = $5;
	    push @cpu, $1;
	}
    });
}

sub read_ostable
{
    load_table('ostable', sub {
	if (m/^(?!\#)(\S+)\s+(\S+)\s+(\S+)/) {
	    $ostable{$1} = $2;
	    $ostable_re{$1} = $3;
	    push @os, $1;
	}
    });
}

sub abitable_load()
{
    load_table('abitable', sub {
        if (m/^(?!\#)(\S+)\s+(\S+)/) {
            $abibits{$1} = $2;
        }
    });
}

sub read_triplettable()
{
    read_cputable();

    load_table('triplettable', sub {
	if (m/^(?!\#)(\S+)\s+(\S+)/) {
	    my $debtriplet = $1;
	    my $debarch = $2;

	    if ($debtriplet =~ /<cpu>/) {
		foreach my $_cpu (@cpu) {
		    (my $dt = $debtriplet) =~ s/<cpu>/$_cpu/;
		    (my $da = $debarch) =~ s/<cpu>/$_cpu/;

		    next if exists $debarch_to_debtriplet{$da}
		         or exists $debtriplet_to_debarch{$dt};

		    $debarch_to_debtriplet{$da} = $dt;
		    $debtriplet_to_debarch{$dt} = $da;
		}
	    } else {
		$debarch_to_debtriplet{$2} = $1;
		$debtriplet_to_debarch{$1} = $2;
	    }
	}
    });
}

sub debtriplet_to_gnutriplet(@)
{
    my ($abi, $os, $cpu) = @_;

    read_cputable();
    read_ostable();

    return unless defined($abi) && defined($os) && defined($cpu) &&
        exists($cputable{$cpu}) && exists($ostable{"$abi-$os"});
    return join('-', $cputable{$cpu}, $ostable{"$abi-$os"});
}

sub gnutriplet_to_debtriplet($)
{
    my $gnu = shift;
    return unless defined($gnu);
    my ($gnu_cpu, $gnu_os) = split(/-/, $gnu, 2);
    return unless defined($gnu_cpu) && defined($gnu_os);

    read_cputable();
    read_ostable();

    my ($os, $cpu);

    foreach my $_cpu (@cpu) {
	if ($gnu_cpu =~ /^$cputable_re{$_cpu}$/) {
	    $cpu = $_cpu;
	    last;
	}
    }

    foreach my $_os (@os) {
	if ($gnu_os =~ /^(.*-)?$ostable_re{$_os}$/) {
	    $os = $_os;
	    last;
	}
    }

    return if !defined($cpu) || !defined($os);
    return (split(/-/, $os, 2), $cpu);
}

sub gnutriplet_to_multiarch($)
{
    my $gnu = shift;
    my ($cpu, $cdr) = split(/-/, $gnu, 2);

    if ($cpu =~ /^i[4567]86$/) {
	return "i386-$cdr";
    } else {
	return $gnu;
    }
}

sub debarch_to_multiarch($)
{
    my $arch = shift;

    return gnutriplet_to_multiarch(debarch_to_gnutriplet($arch));
}

sub debtriplet_to_debarch(@)
{
    my ($abi, $os, $cpu) = @_;

    read_triplettable();

    if (!defined($abi) || !defined($os) || !defined($cpu)) {
	return;
    } elsif (exists $debtriplet_to_debarch{"$abi-$os-$cpu"}) {
	return $debtriplet_to_debarch{"$abi-$os-$cpu"};
    } else {
	return;
    }
}

sub debarch_to_debtriplet($)
{
    my $arch = shift;

    read_triplettable();

    if ($arch =~ /^linux-([^-]*)/) {
	# XXX: Might disappear in the future, not sure yet.
	$arch = $1;
    }

    my $triplet = $debarch_to_debtriplet{$arch};

    if (defined($triplet)) {
	return split(/-/, $triplet, 3);
    } else {
	return;
    }
}

sub debarch_to_gnutriplet($)
{
    my $arch = shift;

    return debtriplet_to_gnutriplet(debarch_to_debtriplet($arch));
}

sub gnutriplet_to_debarch($)
{
    my $gnu = shift;

    return debtriplet_to_debarch(gnutriplet_to_debtriplet($gnu));
}

sub debwildcard_to_debtriplet($)
{
    my $arch = shift;
    my @tuple = split /-/, $arch, 3;

    if (any { $_ eq 'any' } @tuple) {
	if (scalar @tuple == 3) {
	    return @tuple;
	} elsif (scalar @tuple == 2) {
	    return ('any', @tuple);
	} else {
	    return ('any', 'any', 'any');
	}
    } else {
	return debarch_to_debtriplet($arch);
    }
}

sub debarch_to_cpuattrs($)
{
    my $arch = shift;
    my ($abi, $os, $cpu) = debarch_to_debtriplet($arch);

    if (defined($cpu)) {
        abitable_load();

        return ($abibits{$abi} // $cpubits{$cpu}, $cpuendian{$cpu});
    } else {
        return;
    }
}

sub debarch_eq($$)
{
    my ($a, $b) = @_;

    return 1 if ($a eq $b);

    my @a = debarch_to_debtriplet($a);
    my @b = debarch_to_debtriplet($b);

    return 0 if scalar @a != 3 or scalar @b != 3;

    return ($a[0] eq $b[0] && $a[1] eq $b[1] && $a[2] eq $b[2]);
}

sub debarch_is($$)
{
    my ($real, $alias) = @_;

    return 1 if ($alias eq $real or $alias eq 'any');

    my @real = debarch_to_debtriplet($real);
    my @alias = debwildcard_to_debtriplet($alias);

    return 0 if scalar @real != 3 or scalar @alias != 3;

    if (($alias[0] eq $real[0] || $alias[0] eq 'any') &&
        ($alias[1] eq $real[1] || $alias[1] eq 'any') &&
        ($alias[2] eq $real[2] || $alias[2] eq 'any')) {
	return 1;
    }

    return 0;
}

sub debarch_is_wildcard($)
{
    my $arch = shift;

    return 0 if $arch eq 'all';

    my @triplet = debwildcard_to_debtriplet($arch);

    return 0 if scalar @triplet != 3;
    return 1 if any { $_ eq 'any' } @triplet;
    return 0;
}

sub debarch_is_concerned
{
    my ($host_arch, @arches) = @_;

    my $seen_arch = 0;
    foreach my $arch (@arches) {
        $arch = lc $arch;

        if ($arch =~ /^!/) {
            my $not_arch = $arch;
            $not_arch =~ s/^!//;

            if (debarch_is($host_arch, $not_arch)) {
                $seen_arch = 0;
                last;
            } else {
                # !arch includes by default all other arches
                # unless they also appear in a !otherarch
                $seen_arch = 1;
            }
        } elsif (debarch_is($host_arch, $arch)) {
            $seen_arch = 1;
            last;
        }
    }
    return $seen_arch;
}

1;
