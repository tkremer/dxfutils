#!/usr/bin/perl

# convert a CAMM-GL III file to SVG to see what is being plotted
# Line colors represent the order of plotting (red to violet)

## Copyright (c) 2019-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

# usage:
#   camm2svg.pl infile > outfile
#   camm2svg.pl < infile > outfile

use strict;
use warnings;
use CAMM;

local $/ = undef;

my $camm = <>;

my $svg = CAMM->to_svg($camm,1,1);

print $svg;
