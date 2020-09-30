#!/usr/bin/perl

# Module to read/write DXF files

## Copyright (c) 2018-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

package DXF;

use strict;
use warnings;

use List::Util qw(max);
use Math::Trig qw(pi);
use POSIX qw(floor);
use IO::Handle;
# xml related methods will require XML::DOM at runtime.
#use XML::DOM;

# --- internal stuff ---

# 9: variable name identifier.
our %dxf_node_ids = (0 => 1, 9 => 1);
our %dxf_end_nodes = (
  "ENDSEC" => "SECTION",
  "ENDTAB" => "TABLE",
  "EOF"    => "dxf",
  "ENDBLK" => "BLOCK", # ENDBLK has additional parameters?!
  "SEQEND" => "POLYLINE",
);

our %dxf_attr_names = (
   1 => "text",
   2 => "name",
   3 => "text2",
   4 => "text3",
   5 => "handle", # entity handle, up to 16 hex digits.
   6 => "linetype",
   7 => "textstyle",
   8 => "layer",
  # 10..18: x, 20..28: y, 30..37: z
  38 => "elevation",
  39 => "thickness",
# 40 = radius of circle, but other floats in other contexts...
#  40 => "r", # 40-48: floating point values...
  48 => "linetype_scale",
  49 => "values", # multiple values that make up a list, need a repeat count (7x) before!
  # 50..58: angles in degrees
  60 => "invisibile", # 1 for invisible, 0 or undef for visible
  62 => "color",
  66 => "entities_follow", # flag. what for?
  67 => "space", # model- or paper-space
  # 70-78: integer values, such as repeat counts, flag bits or modes
  # 90-98: 32-bit integer values
  100 => "subclass", # required if object is derived from another concrete class
  102 => "control_string", # application defined stuff
  105 => "dimvar_handle",
  210 => "extrusion_direction_x",
  220 => "extrusion_direction_y",
  230 => "extrusion_direction_z",

  999 => "comment",

  # we ignore anything above 999 here for now.

  # TODO: object-specific attribute names. Sometimes sensible...

# TABLE: 2, 70
# LAYER: 2, 6, 62, 70
# LTYPE: 3, 40, 70, 72, 73
);

my @dxf_groupcode_typeranges = (
  [10,9,"x"],[20,9,"y"],[30,8,"z"],
  [40,8,"float"],
  [50,9,"angle"],
  [70,9,"int"],[90,9,"int_32"],[280,10,"int_8"],
  [290,10,"bool"],[300,10,"textstring"],[310,10,"blob"],
  [320,10,"obj_handle"],[330,10,"softptr"],[340,10,"hardptr"],
  [350,10,"softowner"],[360,10,"hardowner"],
# ...
  [370,10,"lineweight"],[380,10,"plotstyle"],[390,10,"plotstyle_handle"],
  [400,10,"int_16"],
  [410,10,"string"],
);

# Attributes that are preserved when substituting an entity by
#  one or more simpler entities in boil_down().
our @general_attributes = qw(
  linetype
  textstyle
  layer
  elevation
  thickness
  linetype_scale
  invisibile
  color
  space
  comment
);

for my $range (@dxf_groupcode_typeranges) {
  my $name = $$range[2];
  my $start = $$range[3]//0;
  my $sep = substr($name,-1) =~ /^\d$/ ? "_" : "";
  for (0..$$range[1]) {
    my $i = $start+$_;
    $dxf_attr_names{$$range[0]+$_} = $name.($i == 0 ? "" : $sep.$i);
  }
}


our %dxf_attr_ids = reverse %dxf_attr_names;
our %dxf_node_ends = reverse(%dxf_end_nodes);#, "dxf" => "EOF");
#$dxf_attr_ids{$dxf_attr_names{$_}} = $_ for keys %dxf_attr_names;

sub dxf_node_id { $_[0] =~ /^\$/ ? 9 : 0 }


# my %dxf_node_id0 = (
#   SECTION => 1,
#   TABLE => 1,
#   dxf => 1,
#   VPORT => 1,
#   LTYPE => 1,
# 
# );

# -- basic parsing and construction --

sub parse_dxf {
  my $fh = shift;
  if (ref $fh eq "") {
    my $s = $fh;
    $fh = undef;
    open ($fh, "<", \$s) or die "cannot open memory file";
  }
  my $root = {name => "dxf", attrs => {}, children => []};
  my @contents = ($root);
  while (my $id = <$fh>) {
    my $param = <$fh>;
    chomp $id;
    if ($id =~ /^\s*(\d+)\s*$/) {
      $id = $1;
    } else {
      die "id \"$id\" is not numeric as expected";
    }
    chomp $param;
    $param =~ s/\r$//;
    if ($dxf_node_ids{$id}) {
#      print STDERR "$param => $id\n" if $id == 9;
      push @contents, {name => $param, attrs => {}, children => []};
    } else {
      my $attr = $dxf_attr_names{$id}//"i$id";
      my $att = \$contents[-1]{attrs}{$attr};
      if (!defined($$att)) {
        $$att = $param;
      } elsif (ref $$att eq "ARRAY") {
        push @$$att, $param;
      } else {
        $$att = [$$att,$param];
      }
      #$contents[-1]{attrs}{$attr} = $param;
    }
  }
  for (my $i = 0; $i <= $#contents; $i++) {
    my $start = $dxf_end_nodes{$contents[$i]{name}};
    if (defined $start) {
      my $begin = undef;
      for (my $j = $i-1; $j >= 0; $j--) {
        if ($contents[$j]{name} eq $start && !$contents[$j]{_completed}) {
          $begin = $j;
          last;
        }
      }
      if (!defined $begin) {
        warn "end tag found without matching starting \"$start\"";
        splice @contents,$i,1;
        $i--;
        next;
      }
      my $parent = $contents[$begin];
      my @children = splice(@contents,$begin+1,$i-$begin);
      
      # Preserve the endtag, as it may have individual attributes and
      #  we don't want to drop any information at this stage.
      $parent->{endtag} = pop @children;
      for (@children) {
        delete $_->{_completed};
      }
      $parent->{children} = \@children;
      $parent->{_completed} = 1;
      $i = $begin;
    }
  }
  for (@contents) {
    delete $_->{_completed};
  }
#  if ($contents[-1]{name} eq "EOF") {
#    pop @contents;
#  } else {
#    warn "EOF tag is missing.";
#  }
  if (@contents != 1) {
    die "EOF tag is missing (or worse).";
  }
  if ($contents[0] != $root) {
    die "something went terribly wrong!";
  }
  #my $root = {name => "dxf", attrs => {}, children => \@contents};
  return $root;
}

sub lol2xml {
  my ($lol,$doc,$indent) = @_;
  my $name = $lol->{name}//"dxf";
  $name =~ s/\$/_/g;
  my $node;

  $indent = "" unless defined $indent;

  if (!defined $doc) {
    require XML::DOM;
    $doc = XML::DOM::Parser->new->parse("<$name></$name>");
    $node = $doc->getDocumentElement;
    #$doc = XML::DOM::Document->new();
  } else {
    $node = $doc->createElement($name);
  }

  my @attrs = keys %{$lol->{attrs}};
  @attrs = sort
     {
       ($a =~ /^i(\d+)$/ ? $1 : $dxf_attr_ids{$a}) <=>
       ($b =~ /^i(\d+)$/ ? $1 : $dxf_attr_ids{$b})   
     } @attrs;
  for (@attrs) {
    my $attr = $_;
    my $value = $lol->{attrs}{$attr};
    # XML doesn't accept multiple attributes of the same name, but DXF does.
    if (ref $value eq "ARRAY") {
      $value = join(" ",@$value);
      $attr .= "-array";
    }
    $node->setAttribute($attr,$value);
#    for (ref ($value) eq "ARRAY" ? @$value : $value) {
#      $node->setAttribute($attr,$_);
#    }
  }
  my @children = @{$lol->{children}};
#  my $i = 0;
  for (@children) {
    $node->appendChild($doc->createTextNode("\n  ".$indent));
    $node->appendChild(lol2xml($_,$doc,$indent."  "));
#    $node->appendChild($doc->createTextNode("\n".($i == $#children ? "" : "  ").$indent));
#    $i++;
  }
  my $emit_endtag = defined $lol->{endtag} && %{$lol->{endtag}{attrs}};
  if ($emit_endtag) {
    $node->appendChild($doc->createTextNode("\n  ".$indent));
    my $s = lol2xml($lol->{endtag},$doc,"")->toString;
    $s =~ s/^</ /;
    $s =~ s/\/>$/ /;
    $node->appendChild($doc->createComment($s));
  }
  $node->appendChild($doc->createTextNode("\n".$indent)) if @children || $emit_endtag;
  return $node;
}

sub lol {
  my ($type,$attr,$content) = @_;
  if (@_ == 2) {
    if (ref $attr eq "HASH") {
      $content = [];
    } elsif (ref $attr eq "ARRAY") {
      $content = $attr;
      $attr = {};
    } else {
      die "invalid lol";
    }
  } elsif (@_ == 1) {
    $attr = {};
    $content = [];
  } elsif (@_ == 3) {
    die "invalid lol" unless ref $attr eq "HASH" && ref $content eq "ARRAY";
  } else {
    die "invalid lol";
  }
  return { name => $type, attrs => $attr, children => $content};
}

sub minimal_header_lol {
  return
    lol("SECTION",{name=>"HEADER"},[
      lol("\$ACADVER",{text=>"AC1014"}), # "caption"? where did it come from?
      lol("\$HANDSEED",{handle=>"FFFF"}), # i5
      lol("\$MEASUREMENT",{int=>1}) # i70
    ]);
}

sub drawing2dxflol {
  my (%layers) = @_;
  my @lines;
  for my $layer (keys %layers) {
    my $paths = $layers{$layer};
    for (@$paths) {
      if (ref($_) eq "ARRAY") {
        next if @$_ < 2;
#        my $type = ...
        my $p = $$_[0];
        for my $i (1..$#$_) {
          my $q = $$_[$i];
          push @lines, lol(LINE => {x=>$$p[0], y=>$$p[1],x1=>$$q[0],y1=>$$q[1], layer => $layer});
          $p = $q;
        }
      }
    }
  }
  
  my $lol = lol("dxf",[
    minimal_header_lol(),
#     lol("SECTION",{name=>"HEADER"},[
#       lol("\$ACADVER",{text=>"AC1014"}), # "caption"? where did it come from?
#       lol("\$HANDSEED",{handle=>"FFFF"}), # i5
#       lol("\$MEASUREMENT",{int=>1}) # i70
#     ]),
    lol(SECTION => {name => "BLOCKS"}),
    lol(SECTION => {name => "ENTITIES"},[
      @lines
    ]),
    lol(SECTION => {name => "OBJECTS"},[lol("DICTIONARY")])
  ]);
  return $lol;
}

sub lol2dxf {
  my ($lol,$pr) = @_;
  my $res = "";
  if (!defined $pr) {
    $pr = sub { $res .= $_ for @_; };
  }

  my ($name,$attrs,$children,$endtag) = @$lol{qw(name attrs children endtag)};

  my $node_id = dxf_node_id($name);
  $pr->(sprintf "%3d\n%s\n", $node_id, $name) if $name ne "dxf";
  my %seen;
  for my $attr (sort
#     {
#       ($a =~ /^i(\d+)$/ ? $1 : $dxf_attr_ids{$a}) <=>
#       ($b =~ /^i(\d+)$/ ? $1 : $dxf_attr_ids{$b})   
#     }
       keys %$attrs) {
    next if $seen{$attr};
    my $param = $attrs->{$attr};
    my $id = $attr =~ /^i(\d+)$/ ? $1 : $dxf_attr_ids{$attr};
    die "invalid attribute \"$attr\" in node \"$name\" (value \"".($param//"undef")."\")" unless defined $id;

    if ($id >= 10 && $id < 20 && ref($param) eq "ARRAY") {
      # special case: coordinates of multiple points must be interleaved.
      my $y = $dxf_attr_names{$id+10};
      my $z = $dxf_attr_names{$id+20};
      my @x = @$param;
      my $_y = $attrs->{$y}//[];
      my $_z = $attrs->{$z}//[];
      my @y = ref $_y ? @$_y : ($_y);
      my @z = ref $_z ? @$_z : ($_z);
      my $max = max($#x,$#y,$#z);
      my @p = map [$x[$_],$y[$_],$z[$_]], 0..$max;
      for (@p) {
        for my $i (0..2) {
          $pr->(sprintf "%3d\n%s\n", $id+$i*10, $$_[$i]) if defined $$_[$i];
        }
      }
      $seen{$y} = 1;
      $seen{$z} = 1;
    } else {
      for (ref ($param) eq "ARRAY" ? @$param : $param) {
        $pr->(sprintf "%3d\n%s\n", $id, $_);
      }
    }
  }
  for (@$children) {
    lol2dxf($_,$pr);
  }
  if (defined $endtag) {
    lol2dxf($endtag,$pr);
  } else {
    my $nodeend = $dxf_node_ends{$name};
    $pr->(sprintf "%3d\n%s\n", $node_id, $nodeend) if defined $nodeend;
  }
  return $res;
}

sub drawing2dxf {
  return lol2dxf(drawing2dxflol(@_));
}

sub xml2lol {
  my $node = shift;
  my $name = $node->getTagName;
  $name =~ s/^_/\$/;
  my @xmlattrs = $node->getAttributes->getValues;
  my %attrs;
  for (@xmlattrs) {
    my $aname = $_->getName;
    my $aval = $_->getValue;
    if ($aname =~ s/-array$//) {
      $aval = [split / /,$aval];
    }
    $attrs{$aname} = $aval;
  }
  my @children;
  for ($node->getChildNodes) {
    require XML::DOM;
    if ($_->getNodeType == XML::DOM::ELEMENT_NODE()) {
      push @children, xml2lol($_);
    }
  }
  return lol($name => \%attrs,\@children);
}

# -- modification and filters --

sub deep_copy {
  my ($x,$prefilter,$postfilter) = @_;
  my $ctx = {};
  if (defined $prefilter) {
    $x = $prefilter->($x,$ctx);
  }
  my $r = ref $x;
  if (($r//"") eq "") {
    $x = $postfilter->($x,$ctx) if defined $postfilter;
    return $x;
  }
  if ($r eq "SCALAR") {
    my $pv = deep_copy($$x);
    my $v = \$pv;
    $v = $postfilter->($v,$ctx) if defined $postfilter;
    return $v;
  } elsif ($r eq "ARRAY") {
     my $v = [@$x];
     $_ = deep_copy($_) for @$v;
     $v = $postfilter->($v,$ctx) if defined $postfilter;
     return $v;
  } elsif ($r eq "HASH") {
    my $v = {%$x};
    $$v{$_} = deep_copy($$v{$_}) for keys %$v;
    $v = $postfilter->($v,$ctx) if defined $postfilter;
    return $v;
  } else {
    die "cannot deep_copy type \"$r\".";
  }
}

# To make calling conventions more clear we let argument-modifying
#   procedural subs below explicitly return 1.

#sub sample_prefilter {
#  my $arr = shift;
#  @$arr = (@$arr,@$arr);
#  $$arr[0]{attrs}{comment} = "Has been visited and duplicated";
#  return (1,1);
#}

# each filter gets an array, may modify that
#  array, but must return 1 iff it did.
# Additionally it gets a hashref that can be used to transfer information
#  from prefilter to postfilter.
# prefilter may return a second value, indicating whether to skip
#  the node's contents.
# prefilter's array always contains exactly 1 element.
# postfilter gets the array the way prefilter leaves it.
sub tree_walk {
  my ($node,$prefilter,$postfilter) = @_;
  my $list = $node->{children};
  return if !defined $list || !@$list;
  for (my $i = 0; $i <= $#$list; $i++) {
    my @x = ($$list[$i]);
    my $ctx = {};
    my ($mod,$skip) = (defined $prefilter && $prefilter->(\@x,$ctx));
    if (!$skip) {
      for (@x) {
        tree_walk($_,$prefilter,$postfilter);
      }
    }
    $mod ||= (defined $postfilter && $postfilter->(\@x,$ctx));
    if ($mod) {
      splice(@$list,$i,1,@x);
      $i += @x-1;
    }
  }
  return 1;
}

sub get_sections {
  my ($dxf,$croak_on_duplicates) = @_;
  my %sections;
  for (@{$dxf->{children}}) {
    if ($_->{name} eq "SECTION") {
      my $n = $_->{attrs}{name};
      if (defined $sections{$n}) {
        die "duplicate section \"$n\"" if $croak_on_duplicates;
        push @{$sections{$n}{children}}, @{$_->{children}};
      } else {
        $sections{$n} = $_;
      }
    }
  }
  return \%sections;
}

# - keep all objects.
# - merge duplicate sections.
# - remove stored end tags.
# modifies the input.
sub canonicalize {
  my $dxf = shift;
  my $sections = get_sections($dxf);
  for (qw(CLASSES TABLES BLOCKS ENTITIES OBJECTS)) {
    $$sections{$_} //= lol(SECTION => {name => $_});
  }
  $$sections{HEADER} //= minimal_header_lol();
  $dxf->{children} = [@$sections{qw(HEADER CLASSES TABLES BLOCKS ENTITIES OBJECTS)}];
 
  tree_walk($dxf,sub { delete $_[0][0]{endtag}; });
  return 1;
}

# strip comments, tables, objects
# modifies the input.
sub strip {
  my $dxf = shift;
  my %delete_sections = ( TABLES => 1, CLASSES => 1);
  my %clear_sections = ( BLOCKS => 1, OBJECTS => 1);

  @{$dxf->{children}} = grep !$delete_sections{$_->{attrs}{name}//""}, @{$dxf->{children}};
  for (@{$dxf->{children}}) {
    if ($clear_sections{$_->{attrs}{name}//""}) {
      $_->{children} = [];
    }
  }
  delete $dxf->{attrs}{comment};
  tree_walk($dxf,sub { delete $_[0][0]{attrs}{comment}; });
  return 1;
}

# makes a copy and removes superfluous data.
sub clean_dxf {
  my $dxf = deep_copy(shift());
  strip($dxf);
  return $dxf;
#  my %delete_sections = ( TABLES => 1);
#  my %clear_sections = ( BLOCKS => 1, OBJECTS => 1);
#
#  @{$dxf->{children}} = grep !$delete_sections{$_->{attrs}{name}//""}, @{$dxf->{children}};
#  for (@{$dxf->{children}}) {
#    if ($clear_sections{$_->{attrs}{name}//""}) {
#      $_->{children} = [];
#    }
#  }
#  return $dxf;
}

# gets an array of entities that belong to a given block and transforms them according to an <INCLUDE> node.
# $blocks is a hashref of known blocks, $node is the INCLUDE node.
sub get_block_replacement {
  my ($blocks,$node) = @_;
  my ($insblock,$x,$y,$z,$xscale,$yscale,$zscale,$rot,$cols,$rows,$colspace,$rowspace) = @{$node->{attrs}}{qw(name x y z float1 float2 float3 angle int int1 float4 float5)};
  die "undefined block used" unless defined $blocks->{$insblock};
  die "incomplete block usage" unless $blocks->{$insblock}{finished}; 
  my @anchor = @{$blocks->{$insblock}{block}{attrs}}{qw(x y z)};
  $_ //= 0 for @anchor,$colspace,$rowspace;
  $_ //= 1 for $cols,$rows;
  my @p = ($x//0,$y//0,$z//0);
  my @s = ($xscale//1,$yscale//1,$zscale//1);
  my ($c,$s) = (cos($rot/180*pi),sin($rot/180*pi));

  my $inserted = $blocks->{$insblock}{objects};
  my %supported = (
    LINE => 1,
    SPLINE => 1,
    POINT => 1,
    LWPOLYLINE => 1,
  );
  #print STDERR "inserting: ".Dumper($inserted);
  my @res;
  #die "not implemented" if ($cols//1) != 1 || ($rows//1) != 1;
  for my $row (0..$rows-1) {
    for my $col (0..$cols-1) {
      my @pos = @p;
      $pos[0] += $col*$colspace;
      $pos[1] += $row*$rowspace;
      for (@$inserted) {
        die "not implemented" unless $supported{$_->{name}};
        my %a = %{$_->{attrs}};
        die "unexpected child" if @{$_->{children}};
        for (0..9) {
          my ($x,$y,$z) = @DXF::dxf_attr_names{10+$_,20+$_,30+$_};
          if (defined $a{$x}) {
            my @v = @a{$x,$y,$z};
            if (!defined $v[2]) {
              $v[2] = ref($v[0]) eq "ARRAY" ? [(0)x@{$v[0]}] : 0;
            }
            if (ref $v[0] eq "ARRAY") {
              $_ = [@$_] for @v;
              for my $i (0..$#{$v[0]}) {
                $v[$_][$i] -= $anchor[$_] for 0..2;
                $v[$_][$i] *= $s[$_] for 0..2;
                ($v[0][$i],$v[1][$i]) = ($v[0][$i]*$c-$v[1][$i]*$s,
                                         $v[0][$i]*$s+$v[1][$i]*$c);
                $v[$_][$i] += $pos[$_] for 0..2;
              }
              @a{$x,$y,$z} = @v;
            } else {
              $v[$_] -= $anchor[$_] for 0..2;
              $v[$_] *= $s[$_] for 0..2;
              ($v[0],$v[1]) = ($v[0]*$c-$v[1]*$s,$v[0]*$s+$v[1]*$c);
              $v[$_] += $pos[$_] for 0..2;
              @a{$x,$y,$z} = @v;
            }
            #print STDERR "changed $x/$y/$z\n";
          }
          #print STDERR "tried $x/$y/$z\n";
        }
        push @res, DXF::lol($_->{name},\%a);
      }
    }
  }
  return \@res;
}

# TODO: safe recursion
sub flatten {
  my $dxf = shift;
  my @blocksecs = grep $_->{attrs}{name} eq "BLOCKS", @{$dxf->{children}};
  my %blocks;
  for (@blocksecs) {
    for (@{$_->{children}}) {
      die "non-block in blocks section" unless $_->{name} eq "BLOCK";
      my $n = $_->{attrs}{name};
      die "duplicate block \"$n\"" if defined $blocks{$n};
      $blocks{$n} = { finished => 1, block => $_, objects => $_->{children} };
    }
  }
  tree_walk($dxf,sub {
    my ($x,$ctx) = @_;
    return (0,1)
      if $$x[0]{name} eq "SECTION" &&
         $$x[0]{attrs}{name} !~ /^BLOCKS$|^ENTITIES$|^OBJECTS$/;
    if ($$x[0]{name} eq "BLOCK") {
      my $n = $$x[0]{attrs}{name};
      $blocks{$n}{finished} = 0;
      $ctx->{name} = $n;
    }
    if ($$x[0]{name} eq "INSERT") {
      my $n = $$x[0]{attrs}{name};
      my $insobjects = get_block_replacement(\%blocks,$$x[0]);
      @$x = @$insobjects;
      # FIXME: recursion protection done right.
      #$blocks{$n}{finished} = 0;
      #$ctx->{name} = $n;  
      return 1;
    }
  },sub {
    my ($x,$ctx) = @_;
    if (defined $ctx->{name}) {
      $blocks{$ctx->{name}}{finished} = 1;
    }
    #if (@$x && $$x[0]{name} eq "BLOCK") {
    #  $blocks{$$x[0]{attrs}{name}}{finished} = 1;
    #}
  });
  return 1;
}

# removes superfluous garbage and flattens all INCLUDEs.
sub flatten_dxf {
  my $dxf = deep_copy(shift());
  canonicalize($dxf);
  flatten($dxf);
  strip($dxf);
  my $sections = get_sections($dxf);
  $$sections{BLOCKS} = DXF::lol(SECTION => {name => "BLOCKS"});
    # actually we may even drop the whole section.
  $dxf = DXF::lol("dxf",[@$sections{qw(HEADER BLOCKS ENTITIES OBJECTS)}]);
  return $dxf;
}

## removes superfluous garbage and flattens all INCLUDEs.
#sub flatten_dxf {
#  my $dxf = deep_copy(shift());
#  delete $dxf->{attrs}{comment};
#  for (@{$dxf->{children}}) {
#    undef $_, next if $_->{name} ne "SECTION";
#    undef $_, next if !defined $_->{attrs}{name};
#    delete $_->{attrs}{comment};
#    delete $_->{attrs}{comment} for @{$_->{children}//[]};
#  }
#  my (%sections,%blocks,@entities,@objects);
#  @entities = ([],[]);
#  for (@{$dxf->{children}}) {
#    next unless defined;
#    if ($_->{attrs}{name} eq "BLOCKS") {
#      my $blocks = $_->{children};
#      my $current_block = "";
#      my $objects;
#      for my $i (0..$#$blocks) {
#        if ($blocks->[$i]{name} eq "BLOCK") {
#          $current_block = $blocks->[$i]{attrs}{name};
#          $objects = [];
#          $blocks{$current_block} =
#             { finished => 0, start => $i, objects => $objects};
#        } elsif ($blocks->[$i]{name} eq "ENDBLK") {
#          @{$blocks{$current_block}}{qw(finished end)} = (1,$i);
#          $objects = undef;
##          print STDERR "finished block $current_block:\n".Dumper(\%blocks);
#          $current_block = "";
#        } else {
#          if ($blocks->[$i]{name} eq "INSERT") {
#            my $insobjects = get_block_replacement(\%blocks,$blocks->[$i]);
#            push @$objects, @$insobjects;
#          } else {
#            push @$objects, $blocks->[$i];
#          }
#        }
#      }
##      undef $_;
#    } elsif ($_->{attrs}{name} eq "ENTITIES" ||
#             $_->{attrs}{name} eq "OBJECTS") {
#      my $type = $_->{attrs}{name} eq "ENTITIES" ? 0 : 1;
#      for (@{$_->{children}}) {
#        if ($_->{name} eq "INSERT") {
#          my $insobjects = get_block_replacement(\%blocks,$_);
##          print STDERR "inserted block ".$_->{attrs}{name}.":\n".Dumper($insobjects);
#          push @{$entities[$type]},@$insobjects;
#        } else {
#          push @{$entities[$type]},$_;
#        }
#      }
##      undef $_;
#    } else {
#      push @{$sections{$_->{attrs}{name}}}, $_;
#    }
#  }
#  for (keys %sections) {
#    my $all = $sections{$_};
#    my $first = shift @$all;
#    for (@$all) {
#      push @{$first->{children}}, @{$_->{children}};
#    }
#    $sections{$_} = $first;
#  }
#  #my @sections = grep defined, @{$dxf->{children}};
#  $sections{ENTITIES} = DXF::lol(SECTION => {name => "ENTITIES"},$entities[0]);
#  $sections{OBJECTS} = DXF::lol(SECTION => {name => "OBJECTS"},$entities[1]);
#  $sections{BLOCKS} = DXF::lol(SECTION => {name => "BLOCKS"}); # actually we may even drop the whole section.
#  if (!defined $sections{HEADER}) {
#    $sections{HEADER} = DXF::minimal_header_lol();
#  }
#  $dxf = DXF::lol("dxf",[@sections{qw(HEADER BLOCKS ENTITIES OBJECTS)}]);
#  return $dxf;
#}

sub merge_dxf {
  my ($dxf1,$dxf2) = @_;

  # ignore BLOCKS, we can't handle them anyway.
  # delete TABLES. They will not be up-to-date.
  # join ENTITIES. That's what we're interested in.
  # what are OBJECTS anyway? Better delete them, there are some dictionaries there...
  my ($e1) = grep(($_->{attrs}{name}//"") eq "ENTITIES", @{$dxf1->{children}});
  my @e2 = grep(($_->{attrs}{name}//"") eq "ENTITIES", @{$dxf2->{children}});
  
  push @{$e1->{children}}, map @{$_->{children}}, @e2;
  return $dxf1;
}

sub colorize_dxf {
  my ($dxf,$color) = @_;
  #my @e = grep(($_->{attrs}{name}//"") eq "ENTITIES", @{$dxf->{children}});
  for (@{$dxf->{children}}) {
    if (($_->{attrs}{name}//"") eq "ENTITIES") {
      for (@{$_->{children}}) {
        $_->{attrs}{color} = $color;
      }
    }
  }
  return $dxf;
}

# POINT, LINE, SPLINE, POLYLINE, LWPOLYLINE, CIRCLE, ARC, ELLIPSE, TEXT, INCLUDE, 

#                                  POLYLINE
# SPLINE---------------------->       v
#       \---> ARC -> ELLIPSE -> LWPOLYLINE <---> LINE
# CIRCLE------^

# spline -> circle:
#      p1 ---p2    p3    
#      |            |
#      |      __-- p4
#      X--M2--
#      |
#      M1
#
#  [p1,p2,p3,p4] -> arc(p1-M1-q,r=r1),arc(q-M2-p4,r=r2)
#  a := |p1,X|, x := |X,M1|; b := |p4,X|, y := |X,M2|; phi := deg(p1,X,p4)
#  r1 = a+x, r2 = b-y, l := a-b, r1-r2 = |M1,M2| = |[y*cos(phi)+x,y*sin(phi)]|
#  r1-r2 = a-b+x+y = |[y*cos(phi)+x,y*sin(phi)]|
#                  = sqrt((y*c+x)^2+y^2*(1-c^2))
#                  = sqrt(y^2*c^2+x^2 +2*y*c*x +y^2-y^2*c^2)
#          l+x+y = sqrt(x^2+y^2 +2*x*y*c)
#  l^2+x^2+y^2+2*x*y+2*l*(x+y) = x^2+y^2 +2*x*y*c
#  l^2 + 2*l*(x+y) + 2*x*y*(1-c) = 0
#  l^2 + 2*l*x + 2*l*y + 2*x*y*(1-c) = 0
#  y = -(l^2 + 2*l*x)/(2*l + 2*x*(1-c))
#  m := r1/r2 = (a+x)/(b-y)
#  y = b-(a+x)/m 
#  b-(a+x)/m = -(l^2 + 2*l*x)/(2*l + 2*x*(1-c))
#  (b-(a+x)/m)*(2*l + 2*x*(1-c)) = -(l^2 + 2*l*x)
#  2*(b*m-a-x)*(l + x*(1-c)) + l^2*m = -2*l*x*m
#  2*(b*m-a)*l + 2*(b*m-a)*x*(1-c) - 2*x*l - 2*x^2*(1-c) + l^2*m + 2*l*x*m = 0
#  -2*(1-c)*x^2 + 2*((b*m-a)*(1-c) + l*(m-1))*x + (2*b*m+l*m-2*a)*l = 0

# TODO: code 70: open and closed splines and polylines.
# dest => source => sub{}
my %replacers = (
  LWPOLYLINE => {
    SPLINE => sub {
      my $node = shift;
      my (@x,@y);
      my @sx = @{$node->{attrs}{x}};
      my @sy = @{$node->{attrs}{y}};
      my $deg = $node->{attrs}{int1}//3;
      my $flags = $node->{attrs}{int}//8;
      my $closed = $flags & 1;
      my $planar = $flags & 8;
      die "degrees other than 3 are not implemented" unless $deg == 3;
      warn "spline not marked as planar. Using it anyway" unless $planar;
      die "invalid spline"
        unless @sx == @sy && (@sx % 3) == 1;
      push @x, $sx[0];
      push @y, $sy[0];
      my $fn = 20;
      while (@sx >= 4) {
        # TODO: subdivide by angle first. Estimate curvature.
        for my $i (1..$fn-1) {
          my $t = $i/$fn;
          my $x1 =   $sx[0]*(1-$t)**3  + 3*$sx[1]*(1-$t)**2*$t
                 + 3*$sx[2]*(1-$t)*$t**2 + $sx[3]*$t**3;
          my $y1 =   $sy[0]*(1-$t)**3  + 3*$sy[1]*(1-$t)**2*$t
                 + 3*$sy[2]*(1-$t)*$t**2 + $sy[3]*$t**3;
          push @x, $x1;
          push @y, $y1;
          #push @coords,$x1,$y1;
          #@p = ($x1,$y1);
        }
        push @x, $sx[3]; # want to avoid any rounding errors
        push @y, $sy[3];
        splice @sx,0,3;
        splice @sy,0,3;
      }
      return lol(LWPOLYLINE => {x => \@x, y => \@y, int => $closed?1:0});
    },
    POLYLINE => sub {
      my $node = shift;
      my (@x,@y);
      my $flags = $node->{attrs}{int}//0;
      my $closed = $flags & 1;
      for (@{$node->{children}}) {
        die "invalid POLYLINE" unless $_->{name} eq "VERTEX";
        push @x, $_->{attrs}{x};
        push @y, $_->{attrs}{y};
      }
      return lol(LWPOLYLINE => {x => \@x, y => \@y, int => $closed?1:0});
    },
    # DONE: Test whether my idea of an ellipse is the same as librecad's.
    ELLIPSE => sub {
      my $node = shift;
      my (@x,@y);
      my($x,$y,$x1,$y1,$min,$a1,$a2) = @{$node->{attrs}}{qw(x y x1 y1 float float1 float2)};
      # f(t) = [$x,$y]+scale($min along [$y1,-$x1])turn($a1+($a2+$a1)*t)[$x1,$y1]
      my $incl = atan2($y1,$x1);
      my $r1 = sqrt($x1**2+$y1**2);
      my $r2 = $min*$r1;
      # f(t) = [$x,$y]+turn(incl)[cos(a)*$r1,sin(a)*$r2]

      # Not sensible, but this is how it's interpreted by librecad:
      while ($a2 < $a1) {
        $a2 += 2*pi;
      }# 0.000000005
      while ($a2 > $a1+2*pi+0.000000005) { # constant estimated by experimentation.
        $a2 -= 2*pi;
      }
      my $rounds = ($a2-$a1)/pi/2;
      my $closed = $rounds-floor($rounds) < 0.001;

      my $fn = floor(($a2-$a1)*$r1); # 1mm minimum
      $fn = 20 if $fn < 20;

      for my $i (0..$fn) {
        my $t = $i/$fn;
        my $angle = $a1+($a2-$a1)*$t;
        my ($px,$py) = (cos($angle)*$r1,sin($angle)*$r2);
        my ($qx,$qy) = ($x+$px*cos($incl)-$py*sin($incl),
                        $y+$px*sin($incl)+$py*cos($incl));
        push @x, $qx;
        push @y, $qy;
      }
      return lol(LWPOLYLINE => {x => \@x, y => \@y, int => $closed?1:0});
    },
    LINE => sub {
      my $node = shift;
      my (@x,@y);
      @x = @{$node->{attrs}}{qw(x x1)};
      @y = @{$node->{attrs}}{qw(y y1)};
      return lol(LWPOLYLINE => {x => \@x, y => \@y, int => 0});
    },
  },
  ELLIPSE => {
    ARC => sub {
      my $node = shift;
      my($x,$y,$r,$a1,$a2) = @{$node->{attrs}}{qw(x y float angle angle1)};
      return lol(ELLIPSE => {x => $x, y => $y, x1 => $r, y1 => 0,
                    float => 1, float1 => $a1*pi/180, float2 => $a2*pi/180});
    }
  },
  ARC => {
    CIRCLE => sub {
      my $node = shift;
      my($x,$y,$r) = @{$node->{attrs}}{qw(x y float)};
      return lol(ARC => {x => $x, y => $y, float => $r,
                         angle => 0, angle1 => 360});
    },
#    SPLINE => sub {
#      # TODO: approximate (reasonably small/simple) spline with two arcs,
#      #       maintaining smoothness of the curve.
#      ...
#    }
  },
  LINE => {
    LWPOLYLINE => sub {
      my $node = shift;
      my @x = @{$node->{attrs}{x}};
      my @y = @{$node->{attrs}{y}};
      die "invalid polyline"
        unless @x == @y && @x >= 1;
      my @lines = map lol(LINE => {x => $x[$_], y => $y[$_],
                                  x1 => $x[$_+1], y1 => $y[$_+1] }), 0..$#x-1;
      return @lines;
    }
  },
);

sub boil_down {
  my ($dxf,$acceptable,$to_replace) = @_;
  $to_replace //= [map keys %$_, values %replacers];
  $acceptable //= ["POINT","LINE"];
  my (%accept,%replace);
  $accept{$_} = 1 for @$acceptable;
  $replace{$_} = 1 for @$to_replace;
  delete $replace{$_} for @$acceptable;
  $to_replace = [keys %replace];
  my %paths;
  my $good = $acceptable;
  $paths{$_} = [] for @$good;
  # find shortest path for any object to replace.
  OUTER: while (@$good) {
    my @more = ();
    for my $g (@$good) {
      my $p = $paths{$g};
      for (keys %{$replacers{$g}}) {
        my $p2 = $paths{$_};
        if (!defined $p2) { # || @$p2 > @$p)
          $paths{$_} = [@$p,[$_,$replacers{$g}{$_}]];
          push @more, $_;
          delete $replace{$_};
          last OUTER if !%replace;
        }
      }
    }
    $good = \@more;
  }
  if (%replace) {
    die "unable to boil down these objects: ".join(",",sort keys %replace);
  }

  %replace = map {$_ => [reverse @{$paths{$_}}]} @$to_replace;

# FIXED: particularly wrong.
  #return deep_copy($dxf,sub{ my $x = shift; my $r = $replace{$x}; return $x unless defined $r; for (@$r) { $x = $r->($x); } return $x; });

  tree_walk($dxf,sub {
    my ($x,$ctx) = @_;
    return (0,1)
      if $$x[0]{name} eq "SECTION" &&
         $$x[0]{attrs}{name} !~ /^BLOCKS$|^ENTITIES$|^OBJECTS$/;
    my $r = $replace{$$x[0]{name}};
    return 0 unless defined $r;
    my %attrs = %{$$x[0]{attrs}};
    for my $entry (@$r) {
      my ($n,$sub) = @$entry;
      @$x = map $_->{name} eq $n ? $sub->($_) : $_, @$x;
    }
    my @gen_attrs = grep defined $attrs{$_}, @general_attributes;
    for my $entity (@$x) {
      for (@gen_attrs) {
        $entity->{attrs}{$_} //= $attrs{$_};
      }
    }
    return 1;
  });
}

sub parse_property_criteria {
  my ($criteria,$name) = @_;
  if (ref $criteria eq "") {
    $criteria =~ /^([-+])?([^=]*=)?(.*)$/s or die "cannot happen";
    my ($type,$nname,$ent) = ($1//"-",$2//$name,$3);
    #$criteria = {_ => $type, $ent => 1};
    $criteria = $type eq "+" ? sub { $_[1]{attrs}{$nname} eq $ent; }
                             : sub { $_[1]{attrs}{$nname} ne $ent; };
  } elsif (ref $criteria eq "HASH") {
    my ($type,$hash) = ($criteria->{_}//"-",$criteria);
    $type =~ /^([-+])?(.*)$/s or die "cannot happen";
    $name = $2 if $2 ne "";
    $type = $1//"-";
    $criteria = $type eq "+" ? sub {  $$hash{$_[1]{attrs}{$name}}; }
                             : sub { !$$hash{$_[1]{attrs}{$name}}; };
  }
  die "criteria must be scalar, hash or coderef."
    if (ref $criteria ne "CODE");
  return $criteria;
}

# criteria can be an entity type, a hashtable of (entity type => 1) or a sub.
# the type may be prefixed with "+" or "-", the hashtable may
# contain _ => ("+"|"-"), to specify inclusion or exclusion filters.
# default is exclusion.
# the sub gets ($entity->{name},$entity) as parameters.
sub filter {
  my ($dxf,$criteria) = @_;
  if (ref $criteria eq "") {
    $criteria =~ /^([-+])?(.*)$/s or die "cannot happen";
    my ($type,$ent) = ($1//"-",$2);
    #$criteria = {_ => $type, $ent => 1};
    $criteria = $type eq "+" ? sub { $_[0] eq $ent; } : sub { $_[0] ne $ent };
  } elsif (ref $criteria eq "HASH") {
    my ($type,$hash) = ($criteria->{_}//"-",$criteria);
    $criteria = $type eq "+" ? sub { $$hash{$_[0]}; } : sub { !$$hash{$_[0]} };
  }
  die "criteria must be scalar, hash or coderef."
    if (ref $criteria ne "CODE");

  my $sections = get_sections($dxf,1);
  my $blocks = ($sections->{BLOCKS}//{})->{children}//[];

  my @base = (@$blocks,grep defined, @$sections{qw(ENTITIES OBJECTS)});
  for (@base) {
    tree_walk($_,sub {
      my ($x,$ctx) = @_;
      my $keep = $criteria->($$x[0]{name},$$x[0]);
      return 0 if $keep;
      @$x = ();
      return 1;
    });
  }
}

sub filter_by_layer {
  my ($dxf,$layers) = @_;
  filter($dxf,parse_property_criteria($layers,"layer"));
}

sub filter_by_color {
  my ($dxf,$colors) = @_;
  filter($dxf,parse_property_criteria($colors,"color"));
}

sub filter_by {
  my ($dxf,$crit) = @_;
  filter($dxf,parse_property_criteria($crit,""));
}

sub deparse {
  my ($dxf,$sub) = @_;
  my @stack = ([]);
  tree_walk($dxf,sub {
      my ($x,$ctx) = @_;
      my $prune = $sub->("prune",$$x[0]);
      push @stack,[];
      return (0,1) if $prune;
      return 0;
    },
    sub {
      my ($x,$ctx) = @_;
      my $content = pop @stack;
      my $res = $sub->("collect",$$x[0],$content);
      push @{$stack[-1]},$res;
    }
  );
  die "WTF" if @stack != 1;
  my $content = pop @stack;
  my $res = $sub->("collect",$dxf,$content);
  return $res;
}






# --- interface ---
# much TODO
# DONE: flatten
# TODO: bbox
# DONE: filter by layer
# DONE: filter by color

package File::DXF;

sub new {
  my ($class,%args) = @_;
  if (defined $args{copy}) {
    return $args{copy}->copy;
  }
  my $self = bless {}, ref $class || $class;
  if (defined $args{file}) {
    $self->parsefile($args{file});
  } elsif (defined $args{data}) {
    $self->parse($args{data});
  } elsif (defined $args{tree}) {
    $self->load_tree($args{tree});
  } elsif (defined $args{xml}) {
    $self->from_xml($args{xml});
  } else {
    $self->load_tree(DXF::lol("dxf"));
  }
  return $self;
}

sub copy {
  my $self = shift;
  my %new = %$self;
  for (keys %new) {
    $new{$_} = DXF::deep_copy($new{$_});
  }
  return bless \%new, ref $self;
}

sub drop_caches {
  my ($self) = @_;
  delete @$self{qw(sections header tables blocks bboxes)};
}

sub get_sections {
  my $self = shift;
  my $res = $self->{sections};
  if (!defined $res) {
    $res = DXF::get_sections($self->{tree},1);
    $self->{sections} = $res;
  }
  return $res;
}

sub _need_vars_and_types {
  my ($self) = @_;
  return if defined $self->{header};
  my (%vars,%types,%nodes);
  for (@{$self->get_sections->{HEADER}{children}}) {
    my $name = $_->{name};
    $name =~ s/^$//;
    my @k = keys %{$_->{attrs}};
    
    my ($type,$value) = @k == 1 ? ($k[0],$_->{attrs}{$k[0]}) :
                @k == 0 ? () :
       defined $_->{attrs}{x} ? ("point",[@{$_->{attrs}}{qw(x y z)}]) :
         do { warn "variable \"$name\" has multiple values"; (); };
    $vars{$name} = $value;
    $types{$name} = $type;
    $nodes{$name} = $_;
  }
  @$self{header} = {vars => \%vars, types => \%types, nodes => \%nodes};
}

sub tree {
  my $self = shift;
  return $self->{tree};
}

sub get_vars {
  my $self = shift;
  $self->_need_vars_and_types;
  return $self->{header}{vars};
}

sub get_vartypes {
  my $self = shift;
  $self->_need_vars_and_types;
  return $self->{header}{types};
}

sub get_blocks {
  my $self = shift;
  my $res = $self->{blocks};
  if (!defined $res) {
    $res = {};
    for (@{$self->get_sections->{BLOCKS}{children}}) {
      die "not a block: $$_{name}, but in BLOCKS."
        unless $_->{name} eq "BLOCK";
      $$res{$_->{attrs}{name}} = $_;
    }
    $self->{blocks} = $res;
  }
  return $res;
}

sub get_tables {
  my $self = shift;
  my $res = $self->{tables};
  if (!defined $res) {
    $res = {};
    for (@{$self->get_sections->{TABLES}{children}}) {
      die "not a table: $$_{name}, but in TABLES."
        unless $_->{name} eq "BLOCK";
      $$res{$_->{attrs}{name}} = $_;
    }
    $self->{tables} = $res;
  }
  return $res;
}

sub get_bboxes {
  my $self = shift;
  die "not implemented yet";
  my $res = $self->{bboxes};
  if (!defined $res) {
    my $sections = $self->get_sections;
    my $ent = $sections->{ENTITIES};
    my @blocks = $sections->{BLOCKS}{children};

    for (@blocks) {
    }
    $self->{bboxes} = $res;
  }
  return $res;
}

sub load_tree { # load a complete DXF::lol()-based tree
  my ($self,$tree,$no_copy_needed) = @_;
  # can be used as a constructor, too.
  $self = $self->new if ref $self eq "";
  $tree = DXF::deep_copy($tree) unless $no_copy_needed;
  DXF::canonicalize($tree);
  my $sections = DXF::get_sections($tree,1);
  $self->drop_caches;
  $self->{tree} = $tree;
  return $self;
}

sub parse { # scalar data or file handle.
  my ($self,$data) = @_;
  # can be used as a constructor, too.
  $self = $self->new if ref $self eq "";
  my $tree = DXF::parse_dxf($data);
  return $self->load_tree($tree,1);
}

*from_dxf = \&parse;

sub parsefile { # filename
  my ($self,$fname) = @_;
  # can be used as a constructor, too.
  $self = $self->new if ref $self eq "";
  open(my $f,"<",$fname) or die "cannot open \"$fname\": $!";
  my $tree = DXF::parse_dxf($f);
  return $self->load_tree($tree,1);
}

sub get_var {
  my ($self,$name) = @_;
  return $self->get_vars->{$name};
}

sub get_var_type {
  my ($self,$name) = @_;
  return $self->get_vartypes->{$name};
}

sub set_var {
  my ($self,$name,$type,$value) = @_;
  die "set_var needs a type" if @_ < 4;
  my $types = $self->get_vartypes;
  my $vars  = $self->get_vars;
  my $nodes = $self->{header}{nodes};

  my %dxfval = $type ne "point" ? ($type => $value)
               : map (("x","y","z")[$_] => $$value[$_], 0..$#$value);
  # (x => $$value[0], y => $$value[1], z => $$value[2])
  if (exists $$types{$name}) {
    if ($$types{$name} ne $type) {
      warn "warning: changing header variable type.";
      $types->{$name} = $type;
    }
    $nodes->{$name}{attrs} = \%dxfval;
    $vars->{$name} = $value;
  } else {
    my $s = $self->get_sections;
    my $node = DXF::lol("\$$name" => \%dxfval);
    push @{$s->{HEADER}{children}}, $node;
    $nodes->{$name} = $node;
    $types->{$name} = $type;
    $vars->{$name} = $value;
  }
  1;
}

sub change_var {
  my ($self,$name,$value) = @_;
  my $types = $self->get_vartypes;
  die "varaiable \"$name\" does not yet exist" unless exists $$types{$name};
  $self->set_var($name,$$types{$name},$value);
}

sub fulfill_version_requirements {
  my ($self,$ver_str) = @_;
  die "cannot set version: specs not yet fully implemented";
  my $s = $self->get_sections;
  if ($ver_str =~ /^AC(\d+)$/) {
    my $num = $1;
    my @req_sections = $num <= 1009 ? ("ENTITIES") :
      (qw(HEADER CLASSES TABLES ENTITIES OBJECTS));
    if (!defined $s->{ENTITIES}) {
      my $node = lol(SECTION => {name => "ENTITIES"});
      $s->{ENTITIES} = $node;
      push @{$s->{tree}{children}}, $node;
    }
    for (@req_sections) {
      if (!defined $s->{$_}) {
        my $node = lol(SECTION => {name => $_});
        $s->{$_} = $node;
        push @{$s->{tree}{children}}, $node;
      }
    }
    if ($num > 1009) {
      # >= R13
      die "versions >= R13 are not yet implemented";
      # see https://ezdxf.readthedocs.io/en/master/dxfinternals/filestructure.html for detailed requirements.
    }
  } else {
    die "cannot fulfill version requirements for version \"$ver_str\"";
  }
}

# AC1006 = R10
# AC1009 = R11 and R12
# AC1012 = R13
# AC1014 = R14
# AC1015 = AutoCAD 2000
# AC1018 = AutoCAD 2004
# AC1021 = AutoCAD 2007
# AC1024 = AutoCAD 2010
# AC1027 = AutoCAD 2013
# AC1032 = AutoCAD 2018
 
sub version {
  my ($self,$newver) = @_;
  if (@_ > 1) {
    $self->set_var("ACADVER",text => $newver);
    $self->fulfill_version_requirements($newver);
  }
  return $self->get_var("ACADVER");
}

sub add_entities {
  my ($self,$entities) = @_;
  push @{$self->get_sections->{ENTITIES}{children}}, @$entities;
  delete $self->{bboxes};
}

sub boil_down {
  my ($self,$acceptable,$to_replace) = @_;
  DXF::boil_down($self->{tree},$acceptable,$to_replace);
  $self->drop_caches;
}

sub flatten {
  my ($self) = @_;
  DXF::flatten($self->{tree});
  $self->drop_caches;
}

sub strip {
  my ($self) = @_;
  DXF::strip($self->{tree});
  $self->drop_caches;
}

sub filter {
  my ($self,$criteria) = @_;
  DXF::filter($self->{tree},$criteria);
  $self->drop_caches;
}

sub filter_by_layer {
  my ($self,$criteria) = @_;
  DXF::filter_by_layer($self->{tree},$criteria);
  $self->drop_caches;
}

sub filter_by_color {
  my ($self,$criteria) = @_;
  DXF::filter_by_color($self->{tree},$criteria);
  $self->drop_caches;
}

sub filter_by {
  my ($self,$criteria) = @_;
  DXF::filter_by($self->{tree},$criteria);
  $self->drop_caches;
}

sub to_dxf {
  my ($self) = @_;
  return DXF::lol2dxf($self->{tree});
}

sub to_xml_doc {
  my ($self) = @_;
  return DXF::lol2xml($self->{tree});
}

sub to_xml {
  my ($self) = @_;
  return DXF::lol2xml($self->{tree})->toString;
}

sub from_xml {
  my ($self,$doc) = @_;
  # can be used as a constructor, too.
  $self = $self->new if ref $self eq "";
  my $disp = 0;
  if (!ref $doc) {
    require XML::DOM;
    $doc = XML::DOM::Parser->new->parse($doc);
    $disp = 1;
  }
  my $lol = DXF::xml2lol($doc->getDocumentElement);
  $doc->dispose if $disp;
  $self->load_tree($lol,1);
}


#my $file = shift;
#my $f;
#if (defined $file) {
#  open($f, "<", $file) or die "cannot open file";
#} else {
#  $f = \*STDIN;
#}
#my $lol = parse_dxf($f);
#my $dxf2 = lol2dxf($lol);
##print $dxf2;
#use Data::Dumper;
##print Dumper($lol);
#my $xml = lol2xml($lol);
#print $xml->toString;



