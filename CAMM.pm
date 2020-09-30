#!/usr/bin/perl

# Module to read/write CAMM-GL III content

## Copyright (c) 2019-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

package CAMM;

# This implements (a subset of) the CAMM-GL III instruction set "mode 2".

use strict;
use warnings;

use Math::Trig qw(pi);
#use POSIX qw(lround);

use overload '""' => "content";

use constant units_per_mm => 40;
our $units_per_mm = 40;

# escape character for writing strings:
#our $escape_char = "\003";
# examplary slow and fast speed settings:
our $slow = 2;
our $fast = 30;

# named arguments:
#  escape_char: string terminator for text (default: "\003" aka END-OF-TEXT)
#  relative, down, speed, char_size, char_slant, tool,
#    force, p: current state of the machine (is not set automatically).
#  outfile: a file to open for writing (overwrites "f")
#  f: a file to write to (overwrites "output")
#  output: a scalar ref to append commands or a ref to a subroutine
#          (or object) to call for writing commands. (default: new scalar ref)
#  no_timeouts: disable timeout detection that checks the tool after inactivity.

sub new {
  my ($class,%args) = shift;
  if (defined $args{outfile}) {
    open($args{f},">",$args{outfile}) or die "cannot open $args{outfile}: $!";
  }
  if (defined $args{f}) {
    my $f = $args{f};
    $args{output} = sub {
      print $f @_;
    };
  }
  $args{output} //= \(my $s = "");
  $args{$$_[0]} //= $$_[1] for (["relative",0],["escape_char","\x03"],["down",0]);
  return bless \%args, ref $class || $class;
}

sub copy {
  my $self = shift;
  return bless {%$self}, ref $self;
}

package CAMM::Commands {
  # This is a list of bare, stateless commands with parameters,
  # so mostly sprintf-like functions returning CAMM code.
  # Their state logic is managed by the parent module.

  #our $escape_char = "\003";
  sub header { # escape_char
    my $escape_char = $_[0]//"\003";
    "\003\015\012\015\012\015\012\015\012\015\012".
    ";IN;PU;PA0,0;IW0,0,47000,64000;VS30;DT$escape_char;\n";
    # PA isn't a good idea:
    #";IN;PA0,0;IW0,0,47000,64000;VS30;DT$escape_char;\n";
  }
  sub set_escape_char {
    my $escape_char = $_[0];
    "DT$escape_char;\n";
  }
  sub footer {
    moveto(0,0);
  }
  sub tool_up {
    "PU;\n";
  }
  sub tool_down {
    "PD;\n";
  }
  sub set_relative {
    "PR;\n";
  }
  sub set_absolute {
    "PA;\n";
  }
  sub moveto { # x,y
    sprintf "PU%.2f,%.2f;\n", @_;
  }
  sub lineto { # x,y
    sprintf "PD%.2f,%.2f;\n", @_;
  }
  sub polylineto { # x1,y1,x2,y2,...
    "PD".join(",",map {sprintf "%.2f",$_} @_).";\n";
  }
  sub set_speed { # v=2..30 is normal; cm/sec; max 85cm/sec
    sprintf "VS%d;\n", $_[0];
  }
  sub circle { # r; current point is center.
    sprintf "CI%.2f;\n", $_[0];
  }
  sub arc { # Mx,My,angle; radius is such that it includes the current point.
    sprintf "AA%.2f,%.2f,%.2f;\n", @_;
    # FIXED: datasheet says "*1"(float), but other angles are "*3"(float)...
  }
  sub arc_relative { # Mx,My,angle; Mx,My are relative to current point.
    sprintf "AR%.2f,%.2f,%.2f;\n", @_;
    # FIXED: datasheet says "*1"(float), but other angles are "*3"(float)...
  }
  sub moveto_relative { # x,y
    sprintf "PR;PU%.2f,%.2f;\n", @_;
  }
  sub lineto_relative { # x,y
    sprintf "PR;PD%.2f,%.2f;\n", @_;
  }
  sub polylineto_relative { # x1,y1,x2,y2,...
    "PR;PD".join(",",map {sprintf "%.2f",$_} @_).";\n";
  }
  sub set_char_size { # w,h in *cm*
    sprintf "SI%.5f,%.5f;\n", @_;
  }
  sub set_char_slant { # tan(angle)
    sprintf "SL%.2f;", $_[0];
  }
  sub text { # text,escape_char; text must not contain escape_char
    sprintf "LB%s%s\n", $_[0],($_[1]//"\003"); #$escape_char;
  }
  sub tool_change {
    sprintf "SP%d;\n", $_[0];
  }
  sub set_force {
    sprintf "!FS %d\n", floor($_[0]/10)*10;
  }
}

BEGIN {
  # name ? precondition ! postcondition
  # -> to invoke <name>, <precondition> has to be guaranteed.
  # Afterwards, state has changed to establish <postcondition>.
  my @cmdspec = qw(
    header!relative=0!down=0
    footer?relative=0!down=0
    tool_up!down=0
    tool_down!down=1
    moveto?relative=0!down=0
    lineto?relative=0!down=1
    polylineto?relative=0!down=1
    circle?down=1
    arc?down=1!relative=0
    arc_relative?down=1!relative=1
    moveto_relative!relative=1!down=0
    lineto_relative!relative=1!down=1
    polylineto_relative!relative=1!down=1
  );
  #  set_absolute!relative=0
  #  set_relative!relative=1
  #   set_speed
  #   set_char_size
  #   set_char_slant
  #   tool_change
  #   set_force

  my %setters = (
    speed       => \&CAMM::Commands::set_speed,
    char_size   => \&CAMM::Commands::char_size,
    char_slant  => \&CAMM::Commands::char_slant,
    tool        => \&CAMM::Commands::tool_change,
    force       => \&CAMM::Commands::set_force,
    escape_char => \&CAMM::Commands::set_escape_char,
    down => sub { $_[0] ?
        CAMM::Commands::tool_down
      : CAMM::Commands::tool_up;
    },
    relative => sub { $_[0] ?
        CAMM::Commands::set_relative
      : CAMM::Commands::set_absolute;
    },
  );

  # sub set_escape_char {
  #   my ($self,$c) = @_;
  #   $self->{escape_char} = $c;
  #   local $CAMM::Commands::escape_char = $c;
  #   $self->emit(CAMM::Commands::set_escape_char($c));
  # }
  
  # getters, setters.
  for my $name (keys %setters) {
    my $sub = sub {
      return $_[0]->{$name};
    };
    my $settersub = sub {
      $_[0]->set($name,$_[1]);
    };
    my $get_name = "get_$name";
    my $set_name = "set_$name";
    no strict "refs";
    *$name = $sub;
    *$get_name = $sub;
    *$set_name = $settersub;
  }

  sub set {
    my ($self,$name,$value) = @_;
    #   if ($name eq "down") {
    #     $self->emit(
    #       $value ?
    #           CAMM::Commands::tool_down
    #         : CAMM::Commands::tool_up);
    #   } elsif ($name eq "abs") {
    #     $self->emit(
    #       $value ?
    #           CAMM::Commands::set_absolute
    #         : CAMM::Commands::set_relative);
    #  } els
    if (defined $setters{$name}) {
      $self->emit($setters{$name}($value));
    } else {
      die "unknown variable \"$name\"";
    }
    $self->{$name} = $value;
  }

#my $global_object = __PACKAGE__->new;

  for (@cmdspec) {
    my @spec = split /(?=[!?])/, $_;
    my $name = shift @spec;
    my $command = do {
      no strict "refs";
      \&{"CAMM::Commands::$name"};
    };
    my @reqs;
    my @sets;
    for (@spec) {
      if (/^([?!])(\w+)=(\d+)/) {
        my $arr = $1 eq "?" ? \@reqs : \@sets;
        push @$arr, [$2,0+$3];
      } else {
        die "invalid internal spec";
      }
    }
    my $sub = sub {
      #my $self = (@_ && ref $$_[0] eq __PACKAGE__) ? shift : $global_object;
      my $self = shift;
      for (@reqs) {
        if (($self->{$$_[0]}//"-1") != $$_[1]) {
          $self->set($$_[0],$$_[1]);
        }
      }
      $self->emit($command->(@_));
      for (@sets) {
        $self->{$$_[0]} = $$_[1];
      }
    };
    {
      no strict "refs";
      *$name = $sub;
    }
  }

}

sub text {
  #my $self = (@_ && ref $$_[0] eq __PACKAGE__) ? shift : $global_object;
  my $self = shift;
  #local $CAMM::Commands::escape_char = $self->{escape_char};
  $self->emit(CAMM::Commands::text($_[0],$self->{escape_char}));
}

sub emit {
  my ($self,$code) = @_;
  my $out = $self->{output};
  if (ref $out eq "SCALAR") {
    $$out .= $code;
#  } elsif (ref $out eq "CODE") {
  } else {
    # if we've been idle for a couple of seconds, the tool has been upped
    # automatically, so we have to down it again. This only applies to
    # real-time usage and doesn't hurt otherwise, so we just use it in
    # all direct-io cases.
    my $lt = \$self->{lasttime};
    my $t = time;
    if ($$lt+10 > $t && $self->{down} && !$self->{no_timeouts}) {
      $code = CAMM::Commands::tool_down().$code;
    }
    $$lt = $t;
    $out->($code);
  }
}

sub flush {
  my $self = shift;
  my $output = $self->{output};
  if (ref $output eq "SCALAR") {
    my $s = $$output;
    $$output = "";
    return $s;
  }
  return;
}

sub content {
  my $self = shift;
  my $output = $self->{output};
  if (ref $output eq "SCALAR") {
    my $s = $$output;
    return $s;
  }
  return;
}

# $paths = [$polyline,...]
# $polyline = ["open"|"closed",[point,...]]
# options:
#   boolean: header, footer, headerfooter, relative
#   float: epsilon, offset, shortline, smallangle

sub from_polylines {
  my $self = shift;
  $self = $self->new unless ref $self;
  #my $self = (@_ && ref $$_[0] eq __PACKAGE__) ? shift : $global_object;
  my ($paths,%options) = @_;
  @options{qw(header footer)} = (1,1) if $options{headerfooter};
  $self->header() if $options{header};
  my $eps = $options{epsilon}//0.00001;
  # since the knife follows the machine's current (pen) position by an offset,
  # we need to keep track of the knife's position as well as the pen position.
  my $knife = [0,0]; # current position of knife
  my $pen = [0,0];   # current position of pen/knife-holder
  my $last_dp = undef; # last point[i]-point[i-1] (=something*(pen-knife))
  # Note, that we cannot know the starting direction of the knife.
  # DONE: make a "calibration" line at the start to determine the knife direction.
  for (@$paths) {
    my $points = $$_[1];
    if ($options{offset}) { # if offset = 0, use the other code as well.
      my $offs = $options{offset};
      my $short_line = $options{shortline}//80; # 1.5mm is small.
      my $small_angle = $options{smallangle}//10; # 10° is small.
      # DONE: maybe add ($pen-$knife) here
      # TODO: does the knife keep its direction during movetos?
      $last_dp = undef if $options{offsetless_start};
      $knife = $$points[0];
      if (defined $last_dp) {
        my $l = sqrt($$last_dp[0]**2+$$last_dp[1]**2);
        $pen = [map $$knife[$_]+$$last_dp[$_]*($offs/$l), 0,1];
      } else {
        $pen = $knife;
      }
      $self->moveto(@$pen);
      for (my $i = 1; $i < @$points; $i++) {
        my ($pt,@q,$l);
        for (;$i < @$points;$i++) {
        #for my $j ($i+1 .. $#$points) { # implicit $i < $#$points
          $pt = $$points[$i];
          @q = ($$pt[0]-$$knife[0],$$pt[1]-$$knife[1]);
          $l = sqrt($q[0]**2+$q[1]**2);
          last if $l > $eps;
          # $i++, next unless $l > $eps;
        }
        last if $i >= @$points;
        # TODO: since arcs are rather slow, we might want to avoid real
        # arcs here and use a polyline approximation instead.
        # arg(q2/q1) = arg(q2*conj(q1))
        if (defined $last_dp) {
          my $angle = 180/pi*
               atan2($q[1]*$$last_dp[0]-$q[0]*$$last_dp[1], $q[0]*$$last_dp[0]+$q[1]*$$last_dp[1]);
          # if the angle is small and the next line is short, we assume an
          # interpolated curved line. No need to emphasize the corners.
          if (abs($angle) > $small_angle || $l > $short_line) {
            $self->arc(@$knife,$angle);
          }
          $pen = [map $$knife[$_]+$q[$_]*($offs/$l), 0,1];
        }
        # now:
        #   knife is at $knife = $points[k] for some k < i
        #   pen is at $knife+$offs*(points[i]-$knife)°

        my @r = @q;
        if (!defined $last_dp) {
          $_ *= 1+$offs/$l for @q;
        }
        $_ *= $offs/$l for @r;
        $knife = $pt;
        $last_dp = \@q;

        # sadly, we can't use relative coordinates here, because we don't
        # know how arc end coordinates are rounded by the device.

        #$res .= CAMM::lineto_relative(@q);
        #$res .= CAMM::lineto($$pt[0],$$pt[1]);
        $pen = [map $$knife[$_]+$r[$_], 0,1];
        $self->lineto(@$pen);
        # now:
        #   knife is at $knife = $pt = $points[i]
        #   pen is at $knife+$offs*($knife-points[k])° for last k<i
      }
    } else {
      $self->moveto(@{$$points[0]});
      my @coords;
      if ($options{relative}) {
        my @p = @{$$points[0]};
        for (@$points[1..$#$points]) {
          push @coords, $$_[0]-$p[0],$$_[1]-$p[1];
          @p = @$_;
        }
        $self->polylineto_relative(@coords);
      } else {
        @coords = map @$_[0,1], @$points[1..$#$points];
        #$res .= "# ".scalar(@coords)." points;\n";
        $self->polylineto(@coords);
      }
    }
  }
  $self->footer() if $options{footer};
  #return $self->flush();
  return $self;
}

# parsing

my $florex = qr/[-+]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][-+]?\d+)?/;

sub _take_token {
  my ($camm,$esc) = @_;
  $$camm =~ s/^\s+//;
  my ($cmd,@args);
  my $check_numeric = 0;
  if ($$camm =~ s/^(?:\^[ \t]*)?([A-Z]{2})//) {
    # mode 2
    $cmd = $1;
    if ($cmd eq "LB" || $cmd eq "WD") {
      my $i = index($$camm,$esc);
      die "unterminated \"$cmd\"." if $i == -1;
      @args = (substr($$camm,0,$i-1));
      substr($$camm,0,$i) = "";
      # $$camm =~ s/^(.*)\Q$esc\E//s;...
    } elsif ($cmd eq "DT") {
      @args = (substr($$camm,0,1));
      $$camm =~ s/^.[^;\n]*;//s;
    } elsif ($$camm =~ s/^([^;]*);//) {
      my $argstr = $1;
      die "line break in argument to \"$cmd\"" if $argstr =~ /\n/;
      @args = split /,/,$argstr;
      $check_numeric = 1;
    } else {
      die "missing semicolon in command \"$cmd\".";
    }
  } elsif ($$camm =~ s/^(![A-Z]{2})(.*)//) { # implicit /$/
    # mode 1 & 2 common
    ($cmd,@args) = ($1,$2);
    $check_numeric = 1;
  } elsif ($$camm =~ s/^\e(\.[A-Z@])//) {
    # device control instructions over RS-232
    $cmd = $1;
    if ($$camm =~ s/^([^:\n]*)://) {
      @args = split /;/, $1;
    }
    $check_numeric = 1;
  } elsif ($$camm =~ s/^([A-Z])//) {
    # mode 1
    $cmd = $1;
    if ($$camm =~ s/^(.*)//) {
      @args = $cmd eq "P" ? ($1) : split /,/,$1;
      $check_numeric = 1 if $cmd ne "P";
    }
  } else {
    return;
  }
  if ($check_numeric) {
    for (@args) {
      if (/^\s*($florex)\s*$/) {
        $_ = $1;
      } else {
        die "non-numerical argument \"$_\" in command \"$cmd\".";
      }
    }
  }
  return ($cmd,\@args);
}

# FIXED: PA,PR,AA,AR don't up/down the pen!
# FIXED: Idleness makes the machine up the pen and not down it again!
#   (therefore we use PU/PD whenever possible.)
# FIXED: The machine can do floating point!
# FIXED: PA/PR influence absoluteness/relativity of PU/PD!
# Note: arcs turn positively leftways (as expected).

our %camm2svg_commands;
{
  my $unimplemented = sub {
    warn "command \"$_[1]\" is not implemented yet.";
  };
  %camm2svg_commands = (
   # command => sub ($context,$command,@arguments)
   #      $context = { p => [$x,$y], d => "", escape_char => "\003" }
    IN => sub {
            @{$_[0]{p}} = (0,0);
            $_[0]{escape_char} = "\003";
            $_[0]{d} .= "M 0,0 ";
          },
    DT => sub { $_[0]{escape_char} = $_[2]; },
    PA => sub {
            $_ = 0+$_ for @_[2..$#_];
            my ($ctx,$cmd,@xy) = @_;
            my $i = {PA=>0,PR=>1,PU=>2,PD=>3}->{$cmd};
            $ctx->{$i&2?"down":"relative"} = $i&1;
            pop @xy if @xy%2 != 0;
            return if !@xy;
            
            my $p = $ctx->{p};
            my $letter = $ctx->{down} ? "l" : "m";
            if ($ctx->{relative}) {
              for (0..$#xy) {
                $$p[$_%2] += $xy[$_];
              }
            } else {
              @$p = @xy[-2,-1];
              $letter = uc($letter);
            }
            $_[0]{d} .= "$letter ".join(",",@xy)." ";
          },
#     PU => sub {
#             $_[0]{down} = 0;
#             pop if @_%2 != 0;
#             return if @_ <= 2;
#             $_ = 0+$_ for @_[2..$#_];
#             @{$_[0]{p}} = @_[-2,-1];
#             $_[0]{d} .= "M ".join(",",@{$_[0]{p}})." ";
#           },
#     PD => sub {
#             $_[0]{down} = 1;
#             pop if @_%2 != 0;
#             return if @_ <= 2;
#             $_ = 0+$_ for @_[2..$#_];
#             @{$_[0]{p}} = @_[-2,-1];
#             $_[0]{d} .= "L ".join(",",@_[2..$#_])." ";
#           },
#     PR => sub {
#             $_[0]{relative} = 1;
#             pop if @_%2 != 0;
#             return if @_ <= 2;
#             $_ = 0+$_ for @_[2..$#_];
#             my $p = $_[0]{p};
#             for (2..$#_) {
#               $$p[$_%2] += $_[$_];
#             }
#             $_[0]{d} .= "l ".join(",",@_[2..$#_])." ";
#           },
    #AA => alias for AR,
    AR => sub {
            $_ = 0+$_ for @_[2..$#_];
            my ($ctx,$cmd,$x,$y,$ang) = @_;
            my $p = $ctx->{p};
            if ($cmd eq "AA") {
              $x -= $$p[0];
              $y -= $$p[1];
            }
            my $r = sqrt($x**2+$y**2);
            my $a1 = atan2(-$y,-$x);
            my $a2 = $a1+$ang/180*pi;
            my $longarc = $ang > 180 ? 1 : 0;
            my $rightways = $ang < 0 ? 0 : 1; # FIXME: svg coord system is left-handed, but we manually flip the y axis to make do....
            my @dp = ($r*(cos($a2)-cos($a1)),$r*(sin($a2)-sin($a1)));
            $$p[$_] += $dp[$_] for 0,1;
            if ($ctx->{down}) {
              $ctx->{d} .= "a $r,$r,0,$longarc,$rightways,".join(",",@dp)." ";
            } else {
              $ctx->{d} .= "m ".join(",",@dp)." ";
            }
          },
    CI => sub {
            return unless $_[0]{down};
            $_ = 0+$_ for @_[2..$#_];
            my $r = $_[2];
            $_[0]{d} .= "m $r,0 a $r,$r,0,0,0,".(-2*$r).",0 ".
                         "a $r,$r,0,0,0,".(2*$r).",0 z m ".(-$r).",0 ";
          },

    IW => sub { # need to implement this because it is in our header.
            my ($ctx,$cmd,@args) = @_;
            $ctx->{input_window} = [@args];
            #"IW0,0,47000,64000;";
          },
    map({$_ => 0} qw(
      OA OC OE OF OH OI OO OP OS OW SS SP VS
      !FS !NR !PG !ST
      .B .M .N .H .I .@ .O .E .L .J .K .R) # actual no-ops
    ),
    map({$_ => $unimplemented} qw(
        H D M I R L B X P S Q N C E A G K T
        CA CP CS DF DI DR EA ER EW FT IM IP LB LT
        PT RA RO RR SA SC SI SL SM SR TL UC WD WG XT YT
      ) # unimplemented ops
    ),
  );
  my @aliases = qw(
    PD PA
    PU PA
    PR PA
    AA AR
    H IN
    D PD
    M PU
    I PR
  );
  for (0..@aliases/2-1) {
    $camm2svg_commands{$aliases[2*$_]} = $camm2svg_commands{$aliases[2*$_+1]};
  }
  # maybe: !PG
}

#  <path d="%s" style='stroke:black; stroke-width: 40px; fill:#000000; fill-opacity:0.2;' />
our $svg_template = <<'EOSVG';
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="%f" height="%f">
<g transform='scale(%f,%f) translate(%f,%f)' style='stroke-width: 40px; fill:#000000; fill-opacity:0.1;'>
%s
</g>
</svg>
EOSVG

our $svg_path_template = <<'EOSVG';
  <path d="%s" style='stroke:%s;' />
EOSVG

sub to_svgpath {
  my ($self,$camm,$splittable) = @_;
  $self = $self->new unless ref $self;
  my %defcontext = (
    escape_char => "\003",
    p => [0,0],
    d => "",
  );
  $self->{$_} //= $defcontext{$_} for keys %defcontext;
  while ($camm ne "") {
    my ($cmd,$args) = _take_token(\$camm,$self->{escape_char});
    if (!defined $cmd) {
      $camm =~ s/^[^;\n]*[;\n]//;
      next;
    }
    my $handler = $camm2svg_commands{$cmd};
    if (defined $handler) {
      $handler->($self,$cmd,@$args) if $handler != 0;
      if ($splittable && !$self->{down}) {
        $self->{d} .= " M ".join(",",@{$self->{p}})." ";
      }
    } else {
      warn "ignoring unknown command \"$cmd\"";
    }
  }
  my $d = $self->{d};
  delete $self->{d};
  return $d;
}

# DONE: convert mm to pixels
# 96 px = 1 in = 25.4 mm

my $units_per_px = $units_per_mm * 25.4/96; #$mm_per_in * $in_per_px

sub to_svg {
  my ($self,$camm,$split,$colored) = @_;
  #$self = $self->new unless ref $self;
  $self = $self->new(output => sub {});
  my $d = $self->to_svgpath($camm,$split);
  my $win = $self->{input_window};
  my @origin = (0,0);
  my @size = (100,100);
  my $scale = 1/$units_per_px;
  if (defined $win) {
    @origin = @$win[0,3];
    $_ = -$_ for @origin;
    @size = (($$win[2]-$$win[0])*$scale,($$win[3]-$$win[1])*$scale);
  }
  my $color = "black";
  my @paths;
  if ($split) {
    @paths = grep !/^M $florex,$florex *$/, split /(?=M )/, $d;
    my $i = 0;
    for (@paths) {
      $color = sprintf "#%02x%02x%02x", map 127*(1+cos(($i/@paths*5/6-$_/3)*2*pi)),0..2
        if $colored;
      $_ = (sprintf $svg_path_template, $_, $color);
      $i++;
    }
  } else {
    @paths = (sprintf $svg_path_template, $d, $color);
  }
  return sprintf $svg_template, @size, $scale, -$scale, @origin, join("",@paths);
}

1;

