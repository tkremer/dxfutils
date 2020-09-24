#!/usr/bin/perl

# converts a DXF file to XML for viewing and editing.

## Copyright (c) 2018-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

# usage:
#   dxf2xml.pl infile.dxf > outfile.xml
#   dxf2xml.pl < infile.dxf > outfile.xml

use strict;
use warnings;

use DXF;
use XML::DOM;
use IO::Handle;

my $file = shift;
my $f;
if (defined $file) {
  open($f, "<", $file) or die "cannot open file";
} else {
  $f = \*STDIN;
}
my $lol = DXF::parse_dxf($f);
my $xml = DXF::lol2xml($lol);
print $xml->toString;

