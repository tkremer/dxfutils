#!/usr/bin/perl

# converts a DXF in XML format back to DXF.

## Copyright (c) 2018-2020 by Thomas Kremer
## License: GPL ver. 2 or 3

# usage:
#   xml2dxf.pl infile.xml > outfile.dxf
#   xml2dxf.pl < infile.xml > outfile.dxf

use strict;
use warnings;

use DXF;
use XML::DOM;
use IO::Handle;

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
    if ($_->getNodeType == XML::DOM::ELEMENT_NODE) {
      push @children, xml2lol($_);
    }
  }
  return DXF::lol($name => \%attrs,\@children);
}

my $file = shift;
my $f;
if (defined $file) {
  open($f, "<", $file) or die "cannot open file";
} else {
  $f = \*STDIN;
}

$/ = undef;
my $content = <$f>;

my $xmldoc = XML::DOM::Parser->new->parse($content);
my $lol = xml2lol($xmldoc->getDocumentElement);
$xmldoc->dispose;
DXF::lol2dxf($lol,sub {print @_;});

