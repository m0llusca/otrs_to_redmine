# Minimal OTRS boundary double for standalone bridge tests.
package Kernel::System::VariableCheck;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(IsStringWithData IsHashRefWithData IsArrayRefWithData IsNumber);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );
sub IsStringWithData { defined $_[0] && !ref $_[0] && length $_[0] }
sub IsHashRefWithData { ref $_[0] eq 'HASH' && scalar keys %{ $_[0] } }
sub IsArrayRefWithData { ref $_[0] eq 'ARRAY' && scalar @{ $_[0] } }
sub IsNumber { defined $_[0] && !ref $_[0] && $_[0] =~ /\A\d+\z/ }
1;
