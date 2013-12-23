#!/usr/bin/perl
use strict;
use warnings;

use Data::Dumper 'Dumper';
use DBI ();
use FindBin ();
use Memoize 'memoize';

memoize('get_straights');
memoize('get_turns');

my ($dsn, $user, $password) = ("dbi:SQLite:dbname=$FindBin::Bin/helix.sqlite3", '', '');
my $dbh = DBI->connect($dsn, $user, $password);

my $NO_STRAIGHTS = 1;
my $MAX_FACTOR   = 30;
my $MAX_LENGTH   = 2;

my $FUZZINESS_STRAIGHTS = 4;
my $FUZZINESS_TURNS     = 0;

die "usage: helix.pl [dt] [dx] [dy]\n" if @ARGV < 3;

my ($T, $X, $Y) = @ARGV;

$|++;
my %seen;
my $found = 0;
foreach my $n (1..$MAX_FACTOR) {
  print "n=$n\n";
  %seen = ();
  bt($T*$n, $X*$n, $Y*$n, 1, 0);
}

sub g {
  my ($c) = @_;
  return ($c->{dx} > 0 ? '>' : '<')
    . join('-', @$c{'t', 'x', 'y'})
    . ($c->{f} ? '!' : '');
}

sub bt {
  my ($t, $x, $y, $dx, $turns, @p) = @_;
  my $g = join(':', sort map { g($_) } @p);
  if ($seen{$g}) {
    return;
  }
  $seen{$g}++;

  if ($t/4 + $y == 0 && abs($x) <= -$y && $x % 2 == $y % 2 && $dx == 1) {
    print join(':', map { $_->{id} } @p), "\n";
    $found++;
  }

  return unless $t > 0;
  return if defined($MAX_LENGTH) && @p > $MAX_LENGTH - 1;

  foreach my $c (find_all($t, $x, $y, $dx, $turns)) {
    my $new_turn = ($c->{dx} != $dx) ? 1 : 0;
    bt($t - $c->{t}, $x - $c->{x}, $y - $c->{y}, $c->{dx}, $turns + $new_turn, @p, $c);
  }
}

sub find_all {
  my ($t, $x, $y, $dx, $turns) = @_;

  my @all = map { +{ %$_, dx => $dx, x => $dx * $_->{x} } } get_straights($t, $y);
  return @all if -$y/$t > -$Y/$T+0.01 || $turns >= 2;

  push @all, map { +{ %$_, dx => -$dx, x => $dx * $_->{x} } } get_turns($t, $y);
  return @all;
}

sub get_straights {
  my ($t, $y) = @_;

  return if $NO_STRAIGHTS;

  my $f = $FUZZINESS_STRAIGHTS;

  # Forward...
  my $sql = <<'__QUERY__';
SELECT p.pId, r.dt, r.dx, r.dy, p.sizeX
FROM pattern p INNER JOIN result r ON r.pId = p.pId
WHERE p.start = 'gl_ne'
GROUP BY p.pId
HAVING SUM(r.object = 'gl_ne'
  AND r.dt+(p.sizeX-r.dx-(? + 0))*4 <= ? + 0
  AND (0.0+(p.sizeX-r.dx-(? + 0))-r.dy)/(r.dt+(p.sizeX-r.dx-(? + 0))*4) >= ? + 0) = 1
__QUERY__

  my $sth = $dbh->prepare($sql);
  $sth->execute($f, $t, $f, $f, -$y/$t-0.01);

  my @all;
  while (my $row = $sth->fetchrow_hashref) {
    my $d = $row->{sizeX} - $row->{dx} - $f;
    my $c = {
      't'  => $row->{dt} + $d*4,
      'x'  => $row->{dx} + $d,
      'y'  => $row->{dy} - $d,
      'id' => $row->{pId},
      'dx' => 1,
      'f'  => 0,
    };
    if ($t - $c->{t} == 0) {
      next if $y - $c->{y} != 0;
    }
    else {
      next if -($y - $c->{y})/($t - $c->{t}) > 0.4584;
    }

    push @all, $c;
  }

  return @all;
}

sub get_turns {
  my ($t, $y) = @_;

  my $f = $FUZZINESS_TURNS;

  # Turn...
  my $sql = <<'__QUERY__';
SELECT p.pId, r.dt, r.dx, r.dy, p.sx
FROM pattern p INNER JOIN result r ON r.pId = p.pId
WHERE p.start = 'gl_ne' AND r.dt+(2*p.sx+r.dx-(? + 0))*4 <= (? + 0) AND r.object = 'gl_nw'
GROUP BY p.pId
__QUERY__

  my $sth = $dbh->prepare($sql);
  $sth->execute($f, $t);

  my @all;
  while (my $row = $sth->fetchrow_hashref) {
    my $d = 2*$row->{sx} + $row->{dx} - $f;
    my $c = {
      't'  => $row->{dt} + $d*4,
      'x'  => $row->{dx} + $d,
      'y'  => $row->{dy} - $d,
      'id' => $row->{pId},
      'dx' => -1,
      'f'  => 1,
    };
    if ($t - $c->{t} == 0) {
      next if $y - $c->{y} != 0;
    }
    else {
      next if -($y - $c->{y})/($t - $c->{t}) > 0.4584;
    }

    push @all, $c;
  }

  return @all;
}
