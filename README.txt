DXF utilities and CAMM-GL III converters

To convert a DXF file to CAMM-GL (which is apparently basically just HP-GL):

$ perl -I. ./dxf2camm.pl --sort box,bottom,left camm-test.dxf > camm-test.camm

To see, what is being plotted, the file can be converted to SVG (colors represent order, going from red to violet):

$ perl -I. ./camm2svg.pl camm-test.camm > camm-test.svg

For the XML tools you need the perl module XML::DOM (package "libxml-dom-perl" in Debian)

