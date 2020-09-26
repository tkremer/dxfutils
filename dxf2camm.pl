#!/usr/bin/perl

# Convert a DXF file to CAMM-GL III

## Copyright (c) 2019-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

# TODO: For pdf/ps/eps input:
# gs -dBATCH -dSAFER -dNOPAUSE -sDEVICE=pdfwrite -dCompressPages=false -dNoOutputFonts -dCompressStreams=false -dUNROLLFORMS -sOutputFile=foo.pdf testseite.ps
# (ps2write and eps2write are essentially just a pdf-interpreter plus the pdf)

# perl -e 'use strict; use warnings; use CAM::PDF; { package CAM::PDF::Renderer::Dump; sub handler { my $name = shift; return eval q!sub { my $self = shift; my ($x,$y) = $self->userToDevice(@{$self->{last}}); print "$name($x,$y): ".join(",",map $_//"undef", @_)."\n"; $self->!."SUPER::$name".q!(@_); }!; } no strict "refs"; *$_ = handler($_) for qw(w d m l s c); } my $pdf = CAM::PDF->new($ARGV[0]); $pdf->getPageContentTree(1)->render("CAM::PDF::Renderer::Dump");' ~/foo.pdf

use strict;
use warnings;

#use POSIX qw(lround);
use Math::Trig qw(pi);
use DXF;
use CAMM;
use Getopt::Long qw(:config bundling);

sub dxf_extract_polylines {
  my ($dxf) = @_;
  my @res;
  for my $e (@{$dxf->get_sections->{ENTITIES}{children}}) {
    warn("ignoring entity: $e->{name}"),next unless $e->{name} eq "LWPOLYLINE";
    my ($x,$y) = @{$e->{attrs}}{qw(x y)};
    die "invalid number of coordinates in lwpolyline"
      unless ref $x eq "ARRAY" && @$x == @$y && @$x >= 1;
    my $closed = $e->{attrs}{int} & 1;
    my @points = map [0+$$x[$_],0+$$y[$_]], 0..$#$x;
    push @res, [($closed?"closed":"open"),\@points];
  }
  check_polylines(\@res,"extract");
  return \@res;
}

sub check_polylines {
  my ($l,$context) = @_;
  my $pre = defined($context) ? $context.": " : "";
  die $pre."not an array ref" unless ref $l eq "ARRAY";
  for my $line (@$l) {
    die $pre."not a pair" unless ref $line eq "ARRAY" && @$line == 2;
    die $pre."not open|closed" if $$line[0] !~ /^(?:open|closed)$/;
    my $points = $$line[1];
    die $pre."points not an array" unless ref $points eq "ARRAY";
    die $pre."points empty" unless @$points;
    for my $point (@$points) {
      die $pre."point not a pair" unless ref $point eq "ARRAY" && @$point == 2;
      for (0,1) {
        die $pre."coordinate $_ undef" unless defined $$point[$_];
      }
    }
  }
}

# returns -1 if $x is within $y, 1 if $y is within $x, 0 otherwise or equal
sub rect_containment_cmp {
  my ($x,$y) = @_;
  my @possible = (1,1,1); # (less-than, strictly, greater-than)
  for (0..3) {
    my $i = ($$x[$_] <=> $$y[$_])*($_ >= 2 ? 1 : -1);
    $possible[$i+1] = 0;
  }
  #if ($possible[0] != $possible[2]) {
  #  print STDERR $possible[0]-$possible[2]," : [", join(",",map int($_),@$x),"] <=> [",join(",",map int($_),@$y),"]\n";
  #}
  # proves this function correct:
  # my $res = $possible[0]-$possible[2];
  # my $c = 0;
  # if ($$x[0] >= $$y[0] && $$x[1] >= $$y[1] &&
  #     $$x[2] <= $$y[2] && $$x[3] <= $$y[3]) {
  #   $c = -1;
  # }
  # if ($$x[0] <= $$y[0] && $$x[1] <= $$y[1] &&
  #     $$x[2] >= $$y[2] && $$x[3] >= $$y[3]) {
  #   $c = 1;
  # }
  # if ($res != $c) {
  #   print STDERR "$res : [", join(",",map int($_),@$x),"] <$c> [",join(",",map int($_),@$y),"]\n" if $c ne "";
  # }
  #print STDERR ".";
  return $possible[0]-$possible[2];
}

# sort by partial order, O(n^2), inplace
sub partial_sort {
  my ($sub,$array) = @_;
  my @res;
  local $b;
  for $b (@$array) {
    my $i = 0;
    for (;$i<@res;$i++) {
      local $a = $res[$i];
      my $cmp = &$sub();
      #my $cmp = $sub->($res[$i],$e);
      last if $cmp > 0;
    }
    splice @res,$i,0,$b;
  }
  @$array = @res;
}

sub compute_bboxes {
  my ($lines) = @_;
  check_polylines($lines,"bboxes");

  my @bboxes;

  for (@$lines) {
    #my $bbox = [$$_[1][0],$$_[1][0]];
    my @bbox = (undef)x4;
    for my $p (@{$$_[1]}) {
      for (0,1) {
        $bbox[$_] = $$p[$_]
          if !defined $bbox[$_] || $bbox[$_] > $$p[$_];
        $bbox[$_+2] = $$p[$_]
          if !defined $bbox[$_+2] || $bbox[$_+2] < $$p[$_];
      }
    }
    push @bboxes, \@bbox;
  }
  return \@bboxes;
}

sub bbox_union {
  my ($bboxes) = @_;
  my @bbox = (undef)x4;
  for my $b (@$bboxes) {
    for (0..3) {
      my $sign = $_ <= 1 ? 1 : -1;
      $bbox[$_] = $$b[$_]
        if !defined $bbox[$_] || $bbox[$_]*$sign > $$b[$_]*$sign;
    }
  }
  return \@bbox;
}

sub sort_polylines {
  my ($lines,$bboxes,$order) = @_;
  check_polylines($lines,"sort");

  # my @bboxes;

  # for (@$lines) {
  #   my $bbox = [$$_[1][0],$$_[1][0]];
  #   my @bbox = (undef)x4;
  #   for my $p (@{$$_[1]}) {
  #     for (0,1) {
  #       $bbox[$_] = $$p[$_]
  #         if !defined $bbox[$_] || $bbox[$_] > $$p[$_];
  #       $bbox[$_+2] = $$p[$_]
  #         if !defined $bbox[$_+2] || $bbox[$_+2] < $$p[$_];
  #     }
  #   }
  #   push @bboxes, \@bbox;
  # }
  # bboxes are calculated correctly:
  #@$lines = map ["closed",[[@$_[0,1]],[@$_[2,1]],[@$_[2,3]],[@$_[0,3]],[@$_[0,1]]]], @bboxes;

  use sort "stable";
  
  my %h = qw(left 0 bottom 1 right 2 top 3);
  my @criteria = ();
  for (split /,/, $order) {
    if (/^(left|bottom|right|top)(?:-(asc|desc))?$/) {
      my ($i,$f) = ($h{$1}, ($2//"asc") eq "asc" ? 1 : -1);
      #@perm = sort {($bboxes[$a][$i] <=> $bboxes[$b][$i])*$f} @perm;
      push @criteria, [$i,$f];
    } elsif (/^box$/) {
      #@perm = sort {rect_containment_cmp($bboxes[$a],$bboxes[$b])} @perm;
      push @criteria, \&rect_containment_cmp;
    } else {
      die "unknown sort order: \"$_\"";
    }
  }
  return $lines if !@criteria;

  # # FIXED: non-totalness of box sorting kills transitivity of combined sort.
  # @perm = sort {
  #   my $res = 0;
  #   for (@criteria) {
  #     my $res;
  #     if (ref eq "CODE") {
  #       $res = $_->($bboxes[$a],$bboxes[$b]);
  #     } else {
  #       $res = ($bboxes[$a][$$_[0]] <=> $bboxes[$b][$$_[0]])*$$_[1];
  #     }
  #     return $res if $res != 0;
  #   }
  #   return 0;
  # } 0..$#$lines;

  my @perm = 0..$#$lines;
  for my $crit (reverse @criteria) {
    if (ref $crit eq "CODE") {
      partial_sort(sub {$crit->($$bboxes[$a],$$bboxes[$b])},\@perm);
      #@perm = sort {$crit->($bboxes[$a],$bboxes[$b])} @perm;
    } else {
      @perm = sort {($$bboxes[$a][$$crit[0]] <=> $$bboxes[$b][$$crit[0]])*$$crit[1]} @perm;
    }
  }
  return ([@$lines[@perm]],[@$bboxes[@perm]]);
}

sub add_overlap {
  my ($lines,$overlap) = @_;
  check_polylines($lines,"overlap");
  my @res = @$lines;
  for (@res) {
    my $points = $$_[1];
    undef $_, next if @$points < 2;
    $_ = [@$_];
    $points = [@$points];
    $$_[1] = $points;
    my $closed = $$_[0] eq "closed";
    next if !$closed;
    $$_[0] = "open";
    my @add;
    my $p = $$points[0];
    #die "wtf: $p, @$p" if ref $p ne "ARRAY" || @$p != 2 || !defined $$p[0] || !defined $$p[1];
    my $d = 0;
    for my $q (@$points[1..$#$points]) {
      my $d2 = 0;
      #die "wtf2: $q, @$q" if ref $q ne "ARRAY" || @$q != 2 || !defined $$q[0] || !defined $$q[1];
      $d2 += ($$p[$_]-$$q[$_])**2 for 0..1;
      $d2 = sqrt($d2);
      if ($d+$d2 < $overlap*2) {
        # we accept up to 2*overlap, if it means we can end in a corner.
        # -> less calculating, more probable that we actually hit our line.
        push @add,$q;
        $d += $d2;
        last if $d >= $overlap;
      } else {
        # we have to cut the line short.
        my $t = ($overlap-$d)/$d2;
        my @q2 = map $$p[$_]*(1-$t) + $$q[$_]*$t, 0,1;
        push @add,\@q2;
        last;
      }
      $p = $q;
    }
    push @$points, @add;
  }
  return \@res;
}

sub coarsify_polylines {
  my ($lines,$mindist) = @_;
  check_polylines($lines,"coarsify");
  my $min = $mindist**2;
  my @res = @$lines;
  for (@res) {
    my $points = $$_[1];
    undef $_, next if @$points < 2;
    $_ = [@$_];
    $points = [@$points];
    $$_[1] = $points;
    my $closed = $$_[0] eq "closed";
    my $p = $$points[0];
    #die "wtf: $p, @$p" if ref $p ne "ARRAY" || @$p != 2 || !defined $$p[0] || !defined $$p[1];
    for my $q (@$points[1..$#$points-1]) {
      my $d2 = 0;
      #die "wtf2: $q, @$q" if ref $q ne "ARRAY" || @$q != 2 || !defined $$q[0] || !defined $$q[1];
      $d2 += ($$p[$_]-$$q[$_])**2 for 0..1;
      undef $q, next if $d2 < $min;
      $p = $q;
    }
    @$points = grep defined, @$points;
  }
  @res = grep defined, @res;
  return \@res;
}

# input is an array of ["closed"|"open",[p_1,...,p_n]], where p_i are [x,y]-points.
sub combine_polylines {
  my ($lines,$try_join_cycles,$try_reverse_paths) = @_;
  check_polylines($lines,"combine");
  my $first = undef;
  my (%starts,%ends); # end|start => [[points,start,end],...]
  my (@cycles,@noncycles); # [[points,start,end],...]
  #for my $e (@{get_sections($dxf)->{ENTITIES}{children}}) {
  for (@$lines) {
    # @cycles contains all encountered cycles
    # %starts contains all encountered non-cycles by start point
    # %ends contains all encountered non-cycles by end point

    # when adding a new segment, we check if it can continue a previous
    # segment, if it can be continued by a previous segment or both or none.
    my ($type,$_points) = @$_;
    my @points = @$_points;
    my $closed = $type eq "closed";

    my ($start,$end) = map join(";",@$_), @points[0,-1];
    if ($closed && $start ne $end) {
      push @points, $points[0];
      $end = $start;
    }
    my $elem = [\@points,$start,$end];
    if ($start eq $end) {
      push @cycles, $elem;
      next;
    }
    my ($needstart,$needend) = (1,1);
    if ($ends{$start} && @{$ends{$start}}) {
      my $e2 = pop @{$ends{$start}};
      push @{$$e2[0]},@{$$elem[0]};
      $$e2[2] = $end;
      $start = $$e2[1];
      $elem = $e2;
      $needstart = 0;
      if ($start eq $end) {
        @{$starts{$start}} = grep $_ != $elem, @{$starts{$start}};
        push @cycles, $elem;
        next;
      }
    }
    if ($starts{$end} && @{$starts{$end}}) {
      my $e2 = pop @{$starts{$end}};
      if ($needstart) {
        unshift @{$$e2[0]},@{$$elem[0]};
        $$e2[1] = $start;
        $end = $$e2[2];
        $elem = $e2;
        $needend = 0;
      } else {
        # we need to remove $e2 because $elem is already linked in %start
        push @{$$elem[0]},@{$$e2[0]};
        my $end2 = $end;
        $end = $$e2[2];
        @{$starts{$end2}} = grep $_ != $e2, @{$starts{$end2}};
        @{$ends{$end}} = grep $_ != $e2, @{$ends{$end}};
      }
      if ($start eq $end) {
        @{$starts{$start}} = grep $_ != $elem, @{$starts{$start}}
          if !$needstart;
        @{$ends{$end}} = grep $_ != $elem, @{$ends{$end}}
          if !$needend;
        push @cycles, $elem;
        next;
      }
    }
    push @{$starts{$start}}, $elem if $needstart;
    push @{$ends{$end}}, $elem if $needend;
  }
  for (keys %starts) {
    delete $starts{$_} if !@{$starts{$_}};
  }
  for (keys %ends) {
    delete $ends{$_} if !@{$ends{$_}};
  }

  if ($try_reverse_paths) {
    # join paths with same start or end by reversing one.
    my %corners; # end|start => [[[points,start,end],is_end],...]
    for (keys %starts) {
      my $arr = $starts{$_};
      next unless @$arr;
      $corners{$_} = [ map [$_,0], @$arr ];
    }
    for (keys %ends) {
      my $arr = $ends{$_};
      next unless @$arr;
      push @{$corners{$_}}, map [$_,1], @$arr;
    }

    for (values %corners) {
      while (@$_ >= 2) {
        my ($ee1,$ee2) = sort {$$b[1] <=> $$a[1]} splice @$_, 0,2;
        # get start and end
        my $p1 = $$ee1[0][0];
        my $p2 = $$ee2[0][0];
        my $ix1 = $$ee1[1];
        my $ix2 = $$ee2[1];
        my $start = $$ee1[0][2-$ix1];
        my $end = $$ee2[0][2-$ix2];
        my $s1 = $corners{$start};
        my $s2 = $corners{$end};
        # check for loop
        my $is_loop = $start eq $end;
        if (!$ix1) {
          # reverse actual points
          @$p1 = reverse @$p1;
          # change startpoint entry to start if first is reversed
          $$ee1[0][1] = $start;
          for (@$s1) {
            $$_[1] = 0 if $$_[0] == $$ee1[0];
          }
        }
        if ($is_loop) {
          # note: $s1 != $_, $s2 != $_, since we don't have cycles in the hash.
          @$s1 = grep $$_[0] != $$ee1[0], @$s1;
          @$s2 = grep $$_[0] != $$ee2[0], @$s2;
          push @cycles, $$ee1[0];
        } else {
          # change endpoint entry from second to first
          for (@$s2) {
            @$_ = ($$ee1[0],1) if $$_[0] == $$ee2[0];
          }
        }
        if ($ix2) {
          # reverse added points
          $p2 = [reverse @$p2];
        }
        # add points to first, dropping second.
        $$ee1[0][2] = $end;
        push @$p1,@$p2;
      }
    }
    #%starts = ();
    #%ends = ();
    for (keys %corners) {
      my $arr = $corners{$_};
      next unless @$arr;
      push @noncycles, map $$_[0], grep $$_[1] == 0, @$arr;
      #$starts{$_} = [map $$_[0], grep $$_[1] == 0, @$arr];
      #$ends{$_} = [map $$_[0], grep $$_[1] == 1, @$arr];
    }
  } else {
    for (values %starts) {
      push @noncycles, @$_;
    }
  }

  if ($try_join_cycles) {
    # embed cycles into other paths
    my %cyclepoints; # pointstr => [i_th_cycle,k_th_pointincycle]
    # every point gets marked with an unembedded cycle containing it.
    # duplicate points are used to embed cycles immediately into other cycles.
    for my $i (0..$#cycles) {
      next unless defined;
      my $c = $cycles[$i][0];
      for (my $k = 0; $k < $#$c; $k++) {
        my $p = $$c[$k];
        my $ps = join(";",@$p);
        if (defined $cyclepoints{$ps} && $cyclepoints{$ps}[0] != $i) {
          my ($i2,$k2) = @{$cyclepoints{$ps}};
          my @points = @{$cycles[$i2][0]};
          @points = @points[$k2..$#points-1,0..$k2];
          splice @$c, $k, 1, @points;
          undef $cycles[$i2];
        }
        $cyclepoints{$ps} = [$i,$k];
      }
    }
    # non-cycles are scanned for containing cycles.
    for (@noncycles) {
      my $c = $$_[0];
      for (my $j = 0; $j < @$c; $j++) {
        my $p = $$c[$j];
        my $ps = join(";",@$p);
        if (defined $cyclepoints{$ps}) {
          my ($i,$k) = @{$cyclepoints{$ps}};
          next unless defined $cycles[$i];
          my @points = @{$cycles[$i][0]};
          @points = @points[$k..$#points-1,0..$k];
          splice @$c, $j, 1, @points;
          $j += @points-1;
          undef $cycles[$i];
        }
      }
    }
    @cycles = grep defined, @cycles;
  }

  my @paths = (map(["closed",$$_[0]], @cycles),
               map(["open",$$_[0]], @noncycles));

  return \@paths;
}

# option parsing.

my (@opts,%opts,%opts_explained);

sub usage {
  my $ret = shift//0;
  if ($ret != 0) {
    print STDERR "wrong parameter. Left are: ",join(" ",@ARGV),"\n";
  }
  #print join("\n  --",$0,@opts),"\n";
  print STDERR "usage:\n  $0\n";
  for (@opts) {
    my $name = $_ =~ s/[|!=:].*//r;
    my $value = $opts{$name}//"undefined";
    if (ref $value eq "SCALAR") {
      $value = $$value;
    } elsif (ref $value eq "CODE") {
      $value = undef;
    }
    my $explanation = $opts_explained{$name};
    print STDERR "    --",$_,(defined $value ? " (value: $value)":""),"\n",
          defined($explanation) ? "        $explanation\n":"";
    
  }
  print STDERR "    <dxffile>\n";
  print STDERR "        read DXF data from this file instead of stdin.\n";
  exit($ret);
}

%opts = (
  coarsify => 1/4,
  combine => 1,
  combine_cycles => 1,
  combine_reverse => 1,
  align_knife => 1,
  scale => 1,
  help => sub { usage(0); },
);

%opts_explained = (
  output => "Write CAMM data to this file instead of stdout.",
  offset => "Set knive offset to this value (mm).",
  offsetless_start => "Start each polyline without knife offset.",
  bbox => "Add a bounding box with this much spacing.",
  align_knife => "Begin with a small cut at [0,0]->[0,2] to align the knife.",
  overlap => "add this much (mm) of the start of a loop to its end to make it overlap.",
  raw => "Don't emit header/footer commands.",
  relative => "Use relative commands when possible (better compression).",
  epsilon => "jump over line segments of at most this length.",
  shortline => "maximum length of a short line (mm); smoothen corners only for those lines.",
  smallangle => "maximum angle (degrees) considered small; smoothen corners only for those angles.",
  coarsify => "segments smaller than this length (mm) are combined to straight lines.",
  combine => "draw polylines that touch each other in one go.",
  combine_cycles => "Allow embedding cycles into other polylines to combine them.",
  combine_reverse => "Allow reversing of polylines to combine more of them.",
  translate => "Translate everything to this point (\"x,y\")",
  scale => "Scale everything by this factor",
  sort => "Sort order: /(left|bottom|right|top)(|-asc|-desc)|box/, comma-separated",
  help => "Show this help screen.",
);

@opts = qw(output|o=s offset|off=f offsetless_start! bbox=f align_knife! overlap=f raw! relative! epsilon=f shortline=f smallangle=f coarsify=f combine! combine_cycles|cycles! combine_reverse|reverse! translate=s scale=f sort=s help|h|?);

GetOptions(\%opts,@opts) or usage(2);

usage(2) if @ARGV > 1;

$opts{headerfooter} = !$opts{raw};
$opts{offset} *= CAMM::units_per_mm if defined $opts{offset};
$opts{shortline} *= CAMM::units_per_mm if defined $opts{shortline};
$opts{translate} = [split /,/,$opts{translate}] if defined $opts{translate};

# we don't want the bbox to cause negative coordinates.
if ($opts{bbox}) {
  $opts{translate} //= [0,0];
  $opts{translate}[$_] += $opts{bbox} for 0,1;
}

my $dxffile = shift;
## TODO: get paths from dxf in a good way.

my $dxf = File::DXF->new(defined($dxffile)?(file=>$dxffile):(data=>\*STDIN));
$dxf->boil_down(["POINT","LWPOLYLINE"]);
$dxf->filter({_ => "+", INSERT => 1, LWPOLYLINE => 1});
$dxf->flatten;

my $paths = dxf_extract_polylines($dxf);

$paths = combine_polylines($paths,$opts{combine_cycles},$opts{combine_reverse})
  if $opts{combine};

for (@$paths) { # a path
  for my $p (@{$$_[1]}) { # a point
    if (defined $opts{translate}) {
      $$p[$_] += $opts{translate}[$_] for 0,1;
    }
    for (@$p) { # a coordinate
      $_ = $opts{scale}*$_*CAMM::units_per_mm;
      #$_ = lround($opts{scale}*$_*CAMM::units_per_mm);
    }
  }
}

$paths = coarsify_polylines($paths,$opts{coarsify}*CAMM::units_per_mm)
  if $opts{coarsify};

my $bboxes = compute_bboxes($paths);
my $bbox = bbox_union($bboxes);

($paths,$bboxes) = sort_polylines($paths,$bboxes,$opts{sort})
  if defined $opts{sort};

unshift @$paths, ["open",[[0,0],[0,2*CAMM::units_per_mm]]]
  if $opts{align_knife};

if (defined $opts{bbox}) {
  my @box = @$bbox;
  $box[$_] -= $opts{bbox}*CAMM::units_per_mm*($_ <= 1 ? 1 : -1) for 0..3;
  push @$paths, ["closed",[map [@box[2*($_&1),($_&2)+1]], 0,1,3,2,0]];
}

$paths = add_overlap($paths,$opts{overlap}*CAMM::units_per_mm)
  if $opts{overlap};

my $camm = CAMM->from_polylines($paths,%opts);
#headerfooter=>1,offset=>10*$CAMM::units_per_mm);

my $out;
if (defined $opts{output}) {
  open($out,">",$opts{output}) or die "cannot open $opts{output}: $!";
} else {
  $out = \*STDOUT;
}

print $out $camm;

