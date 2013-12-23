#!/usr/bin/perl
use strict;
use warnings;

use Test::More;

use Data::Dumper 'Dumper';
use DBI ();
use FindBin ();
use IO::Handle ();
use List::Util 'min';
use Memoize 'memoize';
use POSIX 'ceil';

memoize('fetch');
memoize('attach', NORMALIZER => sub { join(':', map { $_->{pId} } @_) });

my %GLIDER_RLE = (
  gl_ne => 'b2o$obo$2bo!',
  gl_nw => '2o$obo$o!',
);
my %GLIDER_CELLS = map { $_ => g_parse($GLIDER_RLE{$_}) } keys %GLIDER_RLE;

my $TEST = 0;

my $dsn = "dbi:SQLite:dbname=$FindBin::Bin/helix.sqlite3";
my ($user, $password) = ('', '');
my $dbh = DBI->connect($dsn, $user, $password, { RaiseError => 1, PrintError => 0 });

open my $outfile, '>', g_getdir('data') . 'patterns.out';
$outfile->autoflush(1);
open STDOUT, '>&', $outfile;
open STDERR, '>&', $outfile;

run_tests() if $TEST;

g_new('');

my @p = map { fetch($_) } split ':', g_getstring('');
my $r = shift @p;
while (@p) {
  $r = attach($r, shift @p);
}
g_putcells($r->{cells});
g_exit("$r->{dt} $r->{dx} $r->{dy}");

sub fetch {
  my ($id) = @_;
  my $sth = $dbh->prepare(<<'__QUERY__');
SELECT p.pId, p.rle, p.sizeX, p.sx, p.sy, r.dt, r.dx, r.dy, r.object
FROM pattern p INNER JOIN result r ON r.pId = p.pId
WHERE p.pId = ? AND p.start = 'gl_ne' AND r.object IN (?, ?)
__QUERY__
  $sth->execute($id, 'gl_ne', 'gl_nw');
  my $pattern = $sth->fetchrow_hashref;
  if (!$pattern) {
    g_exit("Couldn't find $id.");
  }

  $pattern->{cells} = g_parse(delete $pattern->{rle});

  return $pattern;
}

sub attach {
  my ($last, $next) = @_;

  my $axx = $last->{object} eq 'gl_ne' ? 1 : -1;

  my $last_cells = g_transform( $last->{cells}, ($axx < 1 ? $last->{sizeX} - 1 : 0), 0, $axx );
  my $next_cells = remove_start_glider($next);

  my $dt = $last->{dt};
  my $dx = $last->{dx};
  my $dy = $last->{dy};

  # Calculate glider's end position...
  my $ex = $last->{sx} + $dx;
  my $ey = $last->{sy} + $dy;
  if ($axx < 0) {
    $ex = $last->{sizeX} - 1 - $ex;
  }

  my ($found, $result);
  OFFSET:
  for (my $g = 0; $g < 100; $g++, $dt += 4, $dx += $axx, $dy--, $ex++, $ey--) {
    # Paste new pattern without start glider...
    my $x0 = $ex - $next->{sx};
    my $y0 = $ey - $next->{sy} + ceil($dt/4)*2;
    my $next_cells0 = g_transform($next_cells, $x0, $y0);
    $next_cells0 = g_evolve($next_cells0, (-$dt) % 4);

    # Blend previous pattern in...
    $result = g_join($last_cells, $next_cells0);
    next OFFSET if @$result != @$last_cells + @$next_cells0;

    # Check if result emits a glider in the right place...
    my $end = g_evolve($result, $dt + $next->{dt});
    my $glider = $GLIDER_CELLS{ $next->{object} };
    $x0 = $ex + $next->{dx} - ($next->{object} eq 'gl_ne' ? 2 : 0);
    $y0 = $ey + $next->{dy};
    $glider = g_transform($glider, $x0, $y0);
    $end = subtract($end, $glider);
    next OFFSET if !$end;

    $found++;
    last OFFSET;
  }

  my ($xmin, $ymin, $xmax) = bounding_box($result);
  my $sizeX = $xmax - $xmin + 1;
  $result = g_transform($result, $sizeX - 1, 0, $axx) if $axx < 0;

  my $sx = $last->{sx} + ($axx > 0 ? 0 : $sizeX - $last->{sizeX});

  if (!$found) {
    warn("Couldn't attach $next->{pId} to $last->{pId}.\n");
    return;
  }

  return {
    pId    => "$last->{pId}:$next->{pId}",
    cells  => $result,
    sizeX  => $sizeX,
    sx     => $sx,
    sy     => $last->{sy},
    dt     => $dt + $next->{dt},
    dx     => $dx + $axx * $next->{dx},
    dy     => $dy + $next->{dy},
    object => ($axx > 0 xor $next->{object} eq 'gl_ne') ? 'gl_nw' : 'gl_ne',
  };
}

sub subtract {
  my ($cells, $sub) = @_;

  my %sub;
  for (my $i = 0; $i < @$sub; $i += 2) {
    $sub{ $sub->[$i] }{ $sub->[$i+1] }++;
  }

  my $ret = [];
  for (my $i = 0; $i < @$cells; $i += 2) {
    next if $sub{ $cells->[$i] }{ $cells->[$i+1] };

    push @$ret, @$cells[$i, $i+1];
  }

  return if @$cells != @$ret + @$sub;

  return $ret;
}

sub normalize {
  my ($cells) = @_;

  my @pairs;
  for (my $i = 0; $i < @$cells; $i += 2) {
    push @pairs, [ @$cells[$i, $i + 1] ];
  }

  return [ map { @$_ } sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @pairs ];
}

sub bounding_box {
  my ($cells) = @_;
  my ($xmin, $ymin, $xmax, $ymax);
  for (my $i = 0; $i < @$cells; $i += 2) {
    $xmin = $cells->[$i] if !defined($xmin) || $cells->[$i] < $xmin;
    $xmax = $cells->[$i] if !defined($xmax) || $cells->[$i] > $xmax;
    $ymin = $cells->[$i + 1] if !defined($ymin) || $cells->[$i + 1] < $ymin;
    $ymax = $cells->[$i + 1] if !defined($ymax) || $cells->[$i + 1] > $ymax;
  }
  return ($xmin, $ymin, $xmax, $ymax);
}

sub remove_start_glider {
  my ($pattern) = @_;

  my $cells = $pattern->{cells};

  # Remove the glider...
  my $x0   = $pattern->{sx} - 2; # refers to glider's prow
  my $y0   = $pattern->{sy};
  my $sub  = g_transform($GLIDER_CELLS{gl_ne}, $x0, $y0);
  my $diff = subtract($cells, $sub);

  if (!$diff) {
    g_exit("Couldn't remove start glider in $pattern->{pId}.");
  }

  return $diff;
}

sub run_tests {
  my %test_data = (
    straight  => {'cells' => g_parse('7bo$6b3o$6bob2o3b3o$b2o4b3o3bo2bo$obo4b2o4bo$2bo10bo3bo$13bo3bo$13bo$14bobo!'),'object' => 'gl_ne','dt' => '20','sizeX' => '18','dx' => '13','sy' => '3','dy' => '-10','sx' => '2'},
    odd       => {'cells' => g_parse('5b2o$4bobo$6bo3$4b3o$4bo2bo$4bo$4bo$5bobo5$3o$o2bo$o$o3bo$o$bobo!'),'object' => 'gl_ne','dt' => '35','sizeX' => '8','dx' => '0','sy' => '0','dy' => '3','sx' => '6'},
    turn      => {'cells' => g_parse('11b3o$11bo2bo$11bo$11bo3bo$5b2o4bo3bo$4bobo4bo$6bo5bobo$bo$3o$ob2o$b3o$b2o!'),'object' => 'gl_nw','dt' => '21','sizeX' => '16','dx' => '-6','sy' => '4','dy' => '-7','sx' => '6'},
    sparky    => {'cells' => g_parse('b2o4b3o$obo4bo2bo$2bo4bo$7bo3bo$7bo3bo$7bo$8bobo5$9bo$8b3o$7b2obo$7b3o$8b2o!'),'object' => 'gl_nw','dt' => '43','sizeX' => '12','dx' => '2','sy' => '0','dy' => '-14','sx' => '2'},
  );
  $test_data{$_}{pId} = $_ foreach keys %test_data;

  my %tests = (
    'straight:straight' => {
      cells  => g_parse('7bo$6b3o12bo$6bob2o3b3o4b3o$b2o4b3o3bo2bo3bob2o3b3o$obo4b2o4bo7b3o3bo2bo$2bo10bo3bo3b2o4bo$13bo3bo9bo3bo$13bo13bo3bo$14bobo10bo$28bobo!'),
      sizeX  => 32,
      sx     => 2,
      sy     => 3,
      dt     => 44,
      dx     => 27,
      dy     => -21,
      object => 'gl_ne',
    },
    'straight:odd' => {
      cells  => g_parse('7bo$6b3o$6bob2o3b3o$b2o4b3o3bo2bo$obo4b2o4bo$2bo10bo3bo$13bo3bo$13bo$14bobo4$17b3o$17bo2bo$17bo$17bo$18bobo5$13b3o$13bo2bo$13bo$13bo3bo$13bo$14bobo!'),
      sizeX  => 21,
      sx     => 2,
      sy     => 3,
      dt     => 71,
      dx     => 17,
      dy     => -11,
      object => 'gl_ne',
    },
    'odd:straight' => {
      cells => g_parse('5b2o$4bobo$6bo3$4b3o$4bo2bo$4bo$4bo$5bobo5$3o$o2bo$o$o3bo$o$bobo7b3o$11bo2bo4bo$11bo6b3o$11bo5b2obo$12bobo2b3o$17b3o$17b3o$18b2o!'),
      sizeX  => 21,
      sx     => 6,
      sy     => 0,
      dt     => 59,
      dx     => 14,
      dy     => -8,
      object => 'gl_ne',
    },
    'straight:turn' => {
      cells => g_parse('7bo$6b3o$6bob2o3b3o$b2o4b3o3bo2bo$obo4b2o4bo$2bo10bo3bo$13bo3bo9b3o$13bo13bo2bo$14bobo10bo$27bo3bo$27bo3bo$27bo$28bobo$17bo$16b3o$16bob2o$17b3o$17b2o!'),
      sizeX  => 32,
      sx     => 2,
      sy     => 3,
      dt     => 69,
      dx     => 14,
      dy     => -24,
      object => 'gl_nw',
    },
    'turn:straight' => {
      cells => g_parse('26b3o$26bo2bo$26bo$26bo3bo$20b2o4bo3bo$19bobo4bo$8b3o10bo5bobo$2bo5bo2bo4bo$b3o4bo6b3o$2obo4bo6bob2o$3o6bobo4b3o$3o13b2o$3o$b2o!'),
      sizeX  => 31,
      sx     => 21,
      sy     => 4,
      dt     => 45,
      dx     => -20,
      dy     => -18,
      object => 'gl_nw',
    },
    'straight:sparky' => {
      cells => g_parse('7bo$6b3o$6bob2o3b3o$b2o4b3o3bo2bo3b3o$obo4b2o4bo6bo2bo$2bo10bo3bo2bo$13bo3bo2bo3bo$13bo6bo3bo$14bobo3bo$21bobo5$22bo$21b3o$20b2obo$20b3o$21b2o!'),
      sizeX  => 25,
      sx     => 2,
      sy     => 3,
      dt     => 63,
      dx     => 15,
      dy     => -24,
      object => 'gl_nw',
    },
    'sparky:straight' => {
      cells => g_parse('12b2o4b3o$11bobo4bo2bo$13bo4bo$18bo3bo$18bo3bo$18bo$19bobo$7b3o$bo4bo2bo$3o6bo$ob2o5bo$b3o2bobo11bo$b3o15b3o$b3o14b2obo$b2o15b3o$19b2o!'),
      sizeX  => 23,
      sx     => 13,
      sy     => 0,
      dt     => 71,
      dx     => -13,
      dy     => -26,
      object => 'gl_nw',
    },
  );
  $tests{$_}{pId} = $_ foreach keys %tests;

  plan tests => 2 * keys %tests;

  while (my ($test, $expected) = each %tests) {
    my $expected_cells = delete $expected->{cells};

    my $result = attach(@test_data{split ':', $test});
    my $cells = delete $result->{cells};

    is_deeply $result, $expected, $test;
    is_deeply normalize($cells), normalize($expected_cells), "$test, cells";
  }
}
