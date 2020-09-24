#!/usr/bin/perl

# simplifies a DXF by converting everything using a given set of DXF primitives.

## Copyright (c) 2018-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

# usage:
#   dxf_simplify.pl infile.dxf POINT,LINE > outfile.dxf
#   dxf_simplify.pl infile.dxf > outfile.dxf
#   dxf_simplify.pl < infile.dxf > outfile.dxf

use strict;
use warnings;

use DXF;

my ($dxffile,$set) = @ARGV;
my $f;

if (defined $dxffile) {
  open($f,"<",$dxffile) or die "cannot open dxf \"$dxffile\": $!";
} else {
  $f = \*STDIN;
}

$set //= "POINT,LWPOLYLINE";
$set = [split /,/, $set];

my $dxf = DXF::parse_dxf($f);

DXF::canonicalize($dxf);
#DXF::boil_down($dxf,["POINT","LWPOLYLINE","CIRCLE"]);
#DXF::filter($dxf,{_=>"+", INSERT => 1, LWPOLYLINE => 1, POINT => 1, CIRCLE => 1});
#DXF::flatten_dxf($dxf);
#my $copy = DXF::deep_copy($dxf);
DXF::boil_down($dxf,$set);
DXF::flatten($dxf);
DXF::strip($dxf);

print DXF::lol2dxf($dxf);
#print DXF::lol2xml($dxf)->toString;

