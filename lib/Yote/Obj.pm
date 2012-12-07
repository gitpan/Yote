package Yote::Obj;

#
# This is base Yote Object class. 
#
# It is a container class with fields and methods.
#
# On the server side :
#
#   The fields can be accessed with get_, like 'get_foo();' or 'get_foo( $initializer )'
#      A getter takes an optional initialization object 
#      that is only used if the field has not yet been defined
#
#   The fields can be set with set_ like 'set_foo( "value" )'.
#    
#   Lists can be added by by add_to_, like 'add_to_mylist( 'a', 2, $obj );'
#  
#   Items can be removed from lists with remove_from_,  like 'remove_from_list( 2 );'        
#
# On the client side :
#
#   methods may be invoked if they do not start with an underscore.
#
#   data may be accessed if it does not start with an underscore
#
#   data may be written to if it starts with a capitol letter
#

use strict;

use Yote::ObjProvider;

use vars qw($VERSION);

$VERSION = '0.011';

# ------------------------------------------------------------------------------------------
#      * INITIALIZATION *
# ------------------------------------------------------------------------------------------

sub new {
    my( $pkg, $id_or_hash ) = @_;
    my $class = ref($pkg) || $pkg;

    my $obj;

    if( ref( $id_or_hash ) eq 'HASH' ) {
	$obj = bless {
	    ID       => undef,
	    DATA     => {},
	}, $class;
    } 
    else {
	$obj = bless {
	    ID       => $id_or_hash,
	    DATA     => {},
	}, $class;
    }

    my $needs_init = ! $obj->_id;

    $obj->{ID} ||= Yote::ObjProvider::get_id( $obj );
    $obj->_init() if $needs_init;
    $obj->_load();
    
    if( ref( $id_or_hash ) eq 'HASH' ) {
	for my $key ( %$id_or_hash ) {
	    $obj->{DATA}{$key} = Yote::ObjProvider::xform_in( $id_or_hash->{ $key } );
	}
    }


    return $obj;
} #new

sub _id { $_[0]->{ID} } # same as $self->{ID} but faster (this is called a lot)

#
# Called the very first time this object is created. It is not called
# when object is loaded from storage.
# 
sub _init {}

#
# Called each time the object is loaded from the data store.
#
sub _load {}

# ------------------------------------------------------------------------------------------
#      * UTILITY METHODS *
# ------------------------------------------------------------------------------------------


#
# Takes the entire key/value pairs of data as field/value pairs attached to this.
#
sub _absorb {
    my $self = shift;
    my $data = ref( $_[0] ) ? $_[0] : { @_ };

    my $updated_count = 0;
    for my $fld (keys %$data) {
        my $inval = Yote::ObjProvider::xform_in( $data->{$fld} );
        Yote::ObjProvider::dirty( $self, $self->_id ) if $self->{DATA}{$fld} ne $inval;
        $self->{DATA}{$fld} = $inval;
        ++$updated_count;
    } #each field
    return $updated_count;
} #_absorb

# returns true if the object passsed in is the same as this one.
sub _is {
    my( $self, $obj ) = @_;
    return ref( $obj ) && ref( $obj ) eq ref( $self ) &&
        Yote::ObjProvider::get_id( $obj ) == Yote::ObjProvider::get_id( $self );
}

# 
# Returns the xpath for this object.
#
sub _path_to_root {
    my $self = shift;
    return Yote::ObjProvider::path_to_root( $self );
}

# ------------------------------------------------------------------------------------------
#      * UTILITY METHODS *
# ------------------------------------------------------------------------------------------

#
# These methods are not part of the public API
#

#
# Converts scalar, yote object, hash or array to data for returning.
#
sub __obj_to_response {
    my( $self, $to_convert, $login, $xform_out, $guest_token ) = @_;
    my $ref = ref($to_convert);
    my $use_id;
    if( $ref ) {
        my( $m, $d );
        if( $ref eq 'ARRAY' ) {
            my $tied = tied @$to_convert;
            if( $tied ) {
                $d = $tied->[1];
                $use_id = Yote::ObjProvider::get_id( $to_convert );
                return $use_id unless $xform_out;
            } else {
                $d = $self->__transform_data_no_id( $to_convert, $login, $guest_token );
            }
        } 
        elsif( $ref eq 'HASH' ) {
            my $tied = tied %$to_convert;
            if( $tied ) {
                $d = $tied->[1];
                $use_id = Yote::ObjProvider::get_id( $to_convert );
                return $use_id unless $xform_out;
            } else {
                $d = $self->__transform_data_no_id( $to_convert, $login, $guest_token );
            }
        } 
        else {
            $use_id = Yote::ObjProvider::get_id( $to_convert );
            return $use_id unless $xform_out;
            $d = { map { $_ => $to_convert->{DATA}{$_} } grep { $_ && $_ !~ /^_/ } keys %{$to_convert->{DATA}}};

	    $m = Yote::ObjProvider::package_methods( $ref );
        }
	if( $login && $use_id ) {
	    #maybe replace LOGIN_OBJECTS with a token rather than id
	    $Yote::ObjProvider::LOGIN_OBJECTS->{ $login->{ID} }{ $use_id } = 1;
	} elsif( $use_id && $guest_token ) {
	    $Yote::ObjProvider::GUEST_TOKEN_OBJECTS->{ $guest_token }{ $use_id } = 1;
	}
	return $m ? { a => ref( $self ), c => $ref, id => $use_id, d => $d, 'm' => $m } : { a => ref( $self ), c => $ref, id => $use_id, d => $d };
    } # if a reference
    return "v$to_convert" if $xform_out;
    return $to_convert;
} #__obj_to_response

#
# Transforms data structure but does not assign ids to non tied references.
#
sub __transform_data_no_id {
    my( $self, $item, $login, $guest_token ) = @_;
    if( ref( $item ) eq 'ARRAY' ) {
        my $tied = tied @$item;
        if( $tied ) {
            return Yote::ObjProvider::get_id( $item ); 
        }
        return [map { $self->__obj_to_response( $_, $login, 1, $guest_token ) } @$item];
    }
    elsif( ref( $item ) eq 'HASH' ) {
        my $tied = tied %$item;
        if( $tied ) {
            return Yote::ObjProvider::get_id( $item ); 
        }
        return { map { $_ => $self->__obj_to_response( $item->{$_}, $login, 1, $guest_token ) } keys %$item };
    }
    elsif( ref( $item ) ) {
        return  Yote::ObjProvider::get_id( $item ); 
    }
    else {
        return "v$item"; #scalar case
    }
} #__transform_data_no_id


# ------------------------------------------------------------------------------------------
#      * PUBLIC METHODS *
# ------------------------------------------------------------------------------------------

sub load_direct_descendents {
    my( $self, $data, $account ) = @_;
    my @ret;
    for my $fld (grep { $_ !~ /^_/ } keys %{$self->{DATA}}) {
        my $val = $self->{DATA}{$fld};
        next unless $val > 0;
        push( @ret, Yote::ObjProvider::xform_out( $val ) );
    }
    return \@ret;
} #load_direct_descendents 

sub paginate {
    my( $self, $data, $account ) = @_;
    
    my( $list_name, $number, $start ) = @$data;

    return Yote::ObjProvider::paginate_xpath_list( $self->_path_to_root() . "/$list_name", $number, $start );

} #paginate

#
# Updates the object but only for capitolized keys that already exist.
# public client method.
#
sub update {
    my( $self, $data, $account ) = @_;
    my $updated = {};
    for my $fld (keys %$data) {
        next unless $fld =~ /^[A-Z]/ && defined( $self->{DATA}{$fld} );
        my $inval = Yote::ObjProvider::xform_in( $data->{$fld} );
        Yote::ObjProvider::dirty( $self, $self->_id ) if $self->{DATA}{$fld} ne $inval;
        $self->{DATA}{$fld} = $inval;
        $updated->{$fld} = $inval;
    }
    return $updated;
} #update

#
# Defines get_foo, set_foo, add_to_list, remove_from_list
#
sub AUTOLOAD {
    my( $s, $arg ) = @_;
    my $func = our $AUTOLOAD;

    if( $func =~/:add_to_(.*)/ ) {
        my( $fld ) = $1;
        no strict 'refs';
        *$AUTOLOAD = sub {
            my( $self, @vals ) = @_;
            my $get = "get_$fld";
            my $arry = $self->$get([]); # init array if need be
	    push( @$arry, @vals );
        };
        use strict 'refs';
        goto &$AUTOLOAD;
    } #add_to
    elsif( $func =~/:add_once_to_(.*)/ ) {
        my( $fld ) = $1;
        no strict 'refs';
        *$AUTOLOAD = sub {
            my( $self, @vals ) = @_;
            my $get = "get_$fld";
            my $arry = $self->$get([]); # init array if need be
	    for my $val ( @vals ) {
		unless( grep { $val eq $_ } @$arry ) {
		    push( @$arry, $val ) unless grep { $val eq $_ } @$arry;
		}
	    }
	};
        use strict 'refs';
        goto &$AUTOLOAD;
    } #add_once_to
    elsif( $func =~ /:remove_from_(.*)/ ) { #removes the first instance of the target thing from the list
        my $fld = $1;
        no strict 'refs';
        *$AUTOLOAD = sub {
            my( $self, @vals ) = @_;
            my $get = "get_$fld";
            my $arry = $self->$get([]); # init array if need be
	    for my $val (@vals ) {
		for my $i (0..$#$arry) {
		    if( $arry->[$i] eq $val ) {
			splice @$arry, $i, 1;
			last;
		    }
		}
	    }
        };
        use strict 'refs';
        goto &$AUTOLOAD;
    }
    elsif( $func =~ /:remove_all_from_(.*)/ ) { #removes the first instance of the target thing from the list
        my $fld = $1;
        no strict 'refs';
        *$AUTOLOAD = sub {
            my( $self, @vals ) = @_;
            my $get = "get_$fld";
            my $arry = $self->$get([]); # init array if need be
	    for my $val (@vals) {
		my $count = grep { $_ eq $val } @$arry;
		while( $count ) {
		    for my $i (0..$#$arry) {
			if( $arry->[$i] eq $val ) {
			    --$count;
			    splice @$arry, $i, 1;
			    last unless $count;
			}
		    }
		}
	    }
        };
        use strict 'refs';
        goto &$AUTOLOAD;
    }
    elsif ( $func =~ /:set_(.*)/ ) {
        my $fld = $1;
        no strict 'refs';
        *$AUTOLOAD = sub {
            my( $self, $val ) = @_;
            my $inval = Yote::ObjProvider::xform_in( $val );
            Yote::ObjProvider::dirty( $self, $self->_id ) if $self->{DATA}{$fld} ne $inval;
            $self->{DATA}{$fld} = $inval;
        };
        goto &$AUTOLOAD;
    }
    elsif( $func =~ /:get_(.*)/ ) {
        my $fld = $1;
        no strict 'refs';
        *$AUTOLOAD = sub {
            my( $self, $init_val ) = @_;
            if( ! defined( $self->{DATA}{$fld} ) && defined($init_val) ) {
                $self->{DATA}{$fld} = Yote::ObjProvider::xform_in( $init_val );
                if( ref( $init_val ) ) {
                    Yote::ObjProvider::dirty( $init_val, $self->{DATA}{$fld} );
                }
                Yote::ObjProvider::dirty( $self, $self->_id );
            }
            return Yote::ObjProvider::xform_out( $self->{DATA}{$fld} );
        };
        use strict 'refs';
        goto &$AUTOLOAD;
    }
    else {
        die "Unknown Yote::Obj function '$func'";
    }

} #AUTOLOAD

sub DESTROY {}

1;
__END__

=head1 NAME

Yote::Obj - Base class for all persistant Yote objects.

=head1 DESCRIPTION

Yote::Obj is the base class for all stateful Yote objects that have an API presence 
and will be stored in persistant. 

This is a container class and all objects of this class have automatic getter and
setter methods for scalar and list entries. Invoking '$yote_obj->set_foo( "bar" );'
will cause a variable named 'foo' to be attached to this object and assigned the value
of "bar". The values that can be assigend are any number, string, hash, list or Yote::Obj
object. Calling 'my $val = $yote_obj->get_baz( "fred" )' will return the value of the 
variable 'baz', and if none is defined, assigns the value "fred" to 'baz' and returns it.

Additionally, '$yote_obj->add_to_foo( "a", "b", "c", "c" )' will add the values 'a', 'b', 'c' and 'c' 
to the list with the variable name 'foo' that is attached to this object. If no such variable
exists, a list will be created and assigned to it. If there already is a 'foo' that is not a list,
and error will not result. There are a counterpart methods '$yote_obj->remove_from_foo( "c" )' which
removes the first instance of c from the foo list, and '$yote_obj->remove_all_from_foo( "b" )' which 
will remove all the "b" values from the 'foo' list.

All Yote objects have public api methods. These are methods that connect to javascript objects 
and are invoked by clients. All the public api methods have the same signature :

All Yote objects except YoteRoot are attached to an application or descent of the Yote::AppRoot
class.

=over 2

public_api_method( $data, $account )

Where $data is either a scalar value, a list, hash or yote object. $account is the account assigned
to the user for the app that this yote object belongs to. $account may be undefined if the method
may be called by someone not logging in.

=back

=head2 A NOTE ON METHODS

There are different method types for yote :

=over 2

=item Public API methods

These methods are called automatically by the yote system and are not meant to be called by other subs. 
The yote system automatically passes data given to the API and passes in the account of the logged in 
user (if any), so the signature for these methods is always the same.


=item Automatic container methods

These are the methods that are automatic to any yote object. The 'foo', is of course, a stand in for
any data name.

* set_foo

* get_foo

* add_to_foo

* remove_from_foo

=item Utility methods

=item Initialization methods

These methods begin with an underscore. The underscore signals to yote to not broadcast this method to the 
javascript proxy objects. The yote convention is a single underscore for a utility method that is called
by other methods in all packages, and a double underscore for 'private' methods.

=back

=head2 A NOTE ON DATA

Yote has 3 behaviors for data fields of Yote objects

=over 2

=item read only through api

If a field begins with a lowercase letter, the yote server will be transmitted it the javascript proxy
object, and will ignore any requests from the client to update its value.

=item read/write through api

If a field begins with a capital letter, it will be transmitted to the javascript proxy object, which 
may send updates of its value back to the yote server.

=item private data field

If a field starts with an underscore, the yote server will not transmit it to the javascript proxy, and
will ignore any requests from the client to update its value.

=back

=head2 UTILITY METHODS

=over 4

=item _absorb

This takes a hash reference as an argument and uses the key/value entries in this hash to set
values for the fields corresponding to the hash keys.

=item _is

Returns true if the single object argument passed in is equivalent to this one. 

=item _path_to_root

Returns the xpath string that locates this object in the object tree.

=back

=head2 INITIALIZATION METHODS

=over 4

=item new

New takes an optional hash as an argument. If given a hash, it populates the object with the key value
pairs in the hash, as long as those are text/numbers,lists,hashes or yote objects. Note that while this
does not start with an underscore, it is still not exposed to the javascript yote objects.

=item _init

This is called once : only the very first time a Yote object is created. It is used to set up initial data.

=item _load

This method is called each time an object is loaded from the data store. 

=back

=head2 PUBLIC API METHODS

=over 4

=item load_direct_descendents

This method takes no arguments and does not need an account to function. This method
returns a list of objects that are directly attached to this one.

=item paginate

This method takes a list ref with three entries : [field_name, number of items to return, starting point]. 
The starting point is optional and defaults to 0. Returns a subset of the list that is specified by the
field name and attached to this object.

This will throw an error if the value of the field name is defined as something other than a list.

=item update

This method is called automatically by a client javascript objet when its _send_update method is called.
It takes a hash ref filled with field name value pairs and updates the values that are read/write 
( first character is a capital letter ).

=back

=head1 AUTHOR

Eric Wolf

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2011 Eric Wolf

This module is free software; it can be used under the same terms as perl
itself.

=cut
