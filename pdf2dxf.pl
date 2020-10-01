#!/usr/bin/perl

# Convert a PDF/PS/EPS file to DXF
# All color and style information is dropped.

## Copyright (c) 2020 by Thomas Kremer
## License: GPL ver. 2 or 3

# This script requires CAM::PDF and ghostscript.

use strict;
use warnings;
use File::Temp;
use CAM::PDF;
use DXF;

# Ghostscript does all text work for us.
sub do_gs {
  my ($infile,$outfile) = @_;
  my @cmd = (qw(gs -q -dBATCH -dSAFER -dNOPAUSE -sDEVICE=pdfwrite
               -dCompressPages=false -dNoOutputFonts -dCompressStreams=false
               -dUNROLLFORMS),"-sOutputFile=$outfile",$infile);
  my $res = system(@cmd);
  die "gs returned an error" unless $res == 0;
}

# I do not recommend CAM::PDF. That code really stinks of eval.
# But the alternatives are just impotent.
{
  package CAM::PDF::Renderer::DXF;
  use base "CAM::PDF::GS";
  BEGIN {
    sub handler {
      my $name = shift;
      return eval q!sub {
        my $self = shift;
        #my ($x,$y) = $self->userToDevice(@{$self->{last}});
        #print STDERR "$name($x,$y): ".join(",",map $_//"undef", @_)."\n";
        $self->!."SUPER::$name".q!(@_);
        $self->do_push($name,@_);
      }!;
    }
    no strict "refs";
    *$_ = handler($_) for qw(l h v y c re); #qw(w d m l s c);
  }
  # # We want to catch all pdf commands, so we can notice the missing ones:
  # sub AUTOLOAD {
  #   my $sub = handler($AUTOLOAD);
  #   *$AUTOLOAD = $sub;
  #   goto &$sub;
  # }
  # sub can {
  #   return 1;
  # }
  my %ignored_commands;
  $ignored_commands{$_} = 1 for qw(
    i j J ri Tc TL Tr Ts Tw w
    g G rg RG k K cm d m
    S s F f fstar B Bstar b bstar n
    renderText TJ Tj quote doublequote
    BT Tf Tstar Tz Td TD Tm
    gs
  );
  sub do_push {
    my ($self,$name,@args) = @_;
    my @p = $self->userToDevice(@{$self->{last}});
    my @p1 = $self->userToDevice(@{$self->{current}});
    my @entities = ();
    if ($name eq "l" || $name eq "h") { #lineto, closepath
      @entities = (
        DXF::lol(LINE => { x=>$p[0],y=>$p[1],x1=>$p1[0],y1=>$p1[1] })
      );
    } elsif ($name =~ /^[cvy]$/) { # cubics...
      my @q1 = $self->userToDevice(@args[0,1]);
      my @q2 = @q1;
      if ($name eq "c") {
        @q2 = $self->userToDevice(@args[2,3]);
      } elsif ($name eq "v") { # yes, that is how they are specified. m-(
        @q1 = @p;
      } else {
        @q2 = @p1;
      }
      #$q1[$_] = $q1[$_]*2/3+$p[$_]*1/3 for 0..$#q1;
      #$q2[$_] = $q2[$_]*2/3+$p1[$_]*1/3 for 0..$#q2;
      my @points = (\@p,\@q1,\@q2,\@p1);
      my @x = map $_->[0], @points;
      my @y = map $_->[1], @points;
      @entities = (
        DXF::lol(SPLINE => { x=>\@x,y=>\@y,int1=>3,int=>8 }) # open,planar
      );
    } elsif ($name eq "re") { #rectangle
      my @points = (map [@args[0,1]],0..3);
      $_->[0] += $args[2] for @points[1,2];
      $_->[1] += $args[3] for @points[2,3];
      $_ = [$self->userToDevice(@$_)] for @points;
      my @x = map $_->[0], @points;
      my @y = map $_->[1], @points;
      @entities = (
        DXF::lol(LWPOLYLINE => {x => \@x, y => \@y, int => 1})
      );
    #} elsif ($name eq "wdmlsc") {
    } else {
      die "unsupported command \"$name\"" unless $ignored_commands{$name};
    }
    push @{$self->{refs}{dxf}}, @entities if @entities;
  }

  sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{refs}{dxf} = [];
    return $self;
  }

  sub get_dxf {
    my $self = shift;
    my $dxf = File::DXF->new;
    $dxf->add_entities($self->{refs}{dxf});
    return $dxf;
  }
}

my $tempfile = File::Temp->new;
do_gs($ARGV[0],$tempfile->filename);
my $pdf = CAM::PDF->new($tempfile->filename);
my $gs = $pdf->getPageContentTree(1)->traverse("CAM::PDF::Renderer::DXF");
my $dxf = $gs->get_dxf;
print $dxf->to_dxf;

