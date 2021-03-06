package Yote::Test::Hello;

use strict;

use warnings;

use Yote::Obj;

use parent 'Yote::AppRoot';

use vars qw($VERSION);

$VERSION = '0.02';

sub _init {
    my $self = shift;

    $self->set_testfield(int(rand(10)));
    $self->get_list( [ 1, "Bagel" ] );
    $self->get_hash( { one=>1, food => "Bagel" } );
    $self->get_my_hash( { store => { AnObject => new Yote::Obj( { flavor => 'blueberry' } ) } } );

    my( @arry ) = ( "A" .. "Z" );
    $self->set_foo_array( [ @arry ] );
    $self->set_foo_hash( { map { $_ => $arry[$_] } ( 0..$#arry ) } );
    $self->set__foo_array( [ @arry ] );
    $self->set__foo_hash( { map { $_ => $arry[$_] } ( 0..$#arry ) } );
}

sub _load {
    my $self = shift;
    $self->set_my_hash( { store => { AnObject => new Yote::Obj( { flavor => 'blueberry' } ) } } );
    my( @arry ) = ( "A" .. "Z" );
    $self->get_foo_array( [ @arry ] );
    $self->get_foo_hash( { map { $_ => $arry[$_] } ( 0..$#arry ) } );
    $self->get__foo_array( [ @arry ] );
    $self->get__foo_hash( { map { $_ => $arry[$_] } ( 0..$#arry ) } );
    $self->get_bar_hash( { map { $_ => 1 }  @arry } );
}

# needed to test non-room access of underscore variables.
sub _check_access { return 1; }

sub hello {
    my( $self, $data, $acct ) = @_;
    $self->set_count( 1 + $self->get_count( 0 ) );
    return "hello there '".$data->{name}."'. I have said hello ".$self->get_count()." times.";
}

sub hash {
    my( $self, $hash ) = @_;
    return $hash->{foo};
}

sub list {
    my( $self, $list ) = @_;
    return scalar( @{ $list } );
}


sub hello_scalar {
  return "Hello"
}
sub hello_array {
    return [ "A", "B", 33 ];
}
sub hello_hash {
    return { Foo => "BAR", 
	     Baz => "BAF" }
}
sub hello_nothing {}

1;

__END__

=head1 PUBLIC METHODS

=over 4

=item hello

=item hash

=item list

=item hello_scalar

=item hello_array

=item hello_hash

=item hello_nothing

=back

=head1 AUTHOR

Eric Wolf

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2011 Eric Wolf

This module is free software; it can be used under the same terms as perl
itself.

=cut
