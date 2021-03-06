package Yote::IO::Mongo;

############################################
# Storage engine using the Mongo database. #
############################################

use strict;
use warnings;
no warnings 'uninitialized';
no warnings 'recursion';

use MongoDB;

use vars qw($VERSION);

$VERSION = '0.038';

# ------------------------------------------------------------------------------------------
#      * INIT METHODS *
# ------------------------------------------------------------------------------------------
sub new {
    my $pkg = shift;
    my $class = ref( $pkg ) || $pkg;
    my $args = ref( $_[0] ) ? $_[0] : { @_ };

    my $self = {
        args => $args,
    };
    bless $self, $class;
    $self->_connect( $args );
    return $self;
} #new


# ------------------------------------------------------------------------------------------
#      * PUBLIC CLASS METHODS *
# ------------------------------------------------------------------------------------------


sub commit_transaction {}

sub _db_act {
    my( $self, $act, @args ) = @_;
    for(0..2) {
	my $res;
	eval {
	    $res = $self->{ OBJS }->$act( @args );
	};
	if( $@=~ /not connected/ ) {
	    $self->_connect;
	}
	else {
            die $@ if $@ && $@ !~ /^missed|error getting database response|temporarily|please try again|couldn.t get response to throw out/;
	}
	return $res unless $@;
	die "MongoDB attempt 3 failed with error : $@ ( giving up )" if $_ == 2;
	sleep(1);
    }
} #_db_act

sub _find_one {
    my( $self, @args ) = @_;
    return $self->_db_act( 'find_one', @args );
} #_find_one
sub _find {
    my( $self, @args ) = @_;
    return $self->_db_act( 'find', @args );
} #_find
sub _insert {
    my( $self, @args ) = @_;
    return $self->_db_act( 'insert', @args );
} #_insert
sub _remove {
    my( $self, @args ) = @_;
    return $self->_db_act( 'remove', @args );
} #_remove
sub _update {
    my( $self, @args ) = @_;
    return $self->_db_act( 'update', @args );
} #_update

sub container_type {
    my( $self, $host_id, $container_name ) = @_;

    my $mid = MongoDB::OID->new( value => $host_id );
    my $obj = $self->_find_one( { _id => $mid } );
    return '' if $obj->{ c } eq 'ARRAY';
    my $c_obj = $self->_find_one( { _id => MongoDB::OID->new( value => $obj->{ d }{$container_name} )  } );
    if( $c_obj ) {
	return $c_obj->{ c };
    }
    return '';
} #container_type;


#
# Returns the number of entries in the list of the given id.
#
sub count {
    my( $self, $container_id, $args ) = @_;
    my $mid = MongoDB::OID->new( value => $container_id );
    my $obj = $self->_find_one( { _id => $mid } );
    my @search_terms = @{ $args->{search_terms} || [] };
    if( $args->{search_fields} && @search_terms ) {
	my @ors;
	for my $field ( @{ $args->{ search_fields } } ) {
	    for my $term ( @search_terms ) {
		push @ors, { "d.$field" => { '$regex'=> "$term", '$options' => 'i'  } };
	    }
	}
        for my $hash_term ( @{ $args->{ hashkey_search } || [] } ) {
            push @ors, { "d.$hash_term" => { '$regex'=> "/./"  } };
        }
	my $cands = $obj->{ c } eq 'ARRAY' ? [ @{$obj->{ d }} ] : [ values %{$obj->{ d }} ];
	my $query = {
	    _id => { '$in' => [ map { MongoDB::OID->new( value => $_ )  } grep { index( $_, 'v' ) != 0 } @$cands] },
	    '$or' => \@ors,
	};
	my $curs = $self->_find( $query );

	return $self->_find( $query )->count();
    }
    my @hashkey_search = @{ $args->{ hashkey_search } || [] };
    if( @search_terms || @hashkey_search ) {
        if( $obj->{ c } eq 'ARRAY' ) {
            my $count = 0;
            for my $key ( keys %{ $obj->{ d } } ) {
                ++$count if scalar( grep { $obj->{ d }{ $_ } } @search_terms );
            }
            return $count;
        }
        elsif( $obj->{ c } eq 'HASH' ) {
            my $count = 0;
            for my $key ( keys %{ $obj->{ d } } ) {
                ++$count if  scalar( grep { $key =~ /$_/i } @hashkey_search ) || scalar( grep { $obj->{ d }{ $key } =~ /$_/i } @search_terms );
            }
            return $count;
        }
    }

    if( $obj->{ c } eq 'ARRAY' ) {
	return scalar( @{$obj->{ d } } );
    }
    return scalar( keys %{$obj->{ d } } );
} #count

sub database {
    return shift->{ DB };
}

sub disconnect {} #there is no way to explicitly disconnect from the database, see perldoc for MongoDB

sub ensure_datastore {
    # we use a single mongo collection, objects
    # The documents in this database have the following structure :
    #  {
    #   _id : mongo id for this document ( indexed by default )
    #    d   : JSONDATA of object
    #    r   : [] list of referenced ids ( indexed )
    #    c   : class of object
    #  }
    #
    # There is also a collection that exists soley to have a single document that
    # contains the id of the root object. This collection is called 'root'.
    #
    #
    my $self = shift;
    $self->{ OBJS } = $self->{ DB }->get_collection( "objects" );
    $self->{ OBJS }->ensure_index( { 'r' => 1 } );
    my $root = $self->{ DB }->get_collection( "root" );
    my $root_node = $root->find_one( { root => 1 } );
    if( $root_node ) {
	$self->{ ROOT_ID } = $root_node->{ root_id };
    } else {
	my $root_id = MongoDB::OID->new;
	my $xid = $root->insert( { root => 1, root_id => $root_id->{ value } } );
	$self->{ ROOT_ID } = $root_id->{ value };
    }
} #ensure_datastore

#
# Returns a single object specified by the id. The object is returned as a hash ref with id,class,data.
#
sub fetch {
    my( $self, $id ) = @_;
    my $data = $self->_find_one( { _id => MongoDB::OID->new( value => $id ) } );
    return unless $data;
    if( $data->{ c } eq 'ARRAY' ) {
	return [ $id, $data->{ c }, $data->{d} ];
    } else {
	my $unescaped_data = {};
	for my $key ( keys %{$data->{d}} ) {
	    my $val = $data->{d}{$key};
	    $key =~ s/\\/\./g;
	    $unescaped_data->{$key} = $val;
	}
	return [ $id, $data->{ c }, $unescaped_data ];
    }
} #fetch

#
# Returns the first ID that is associated with the root Root object
#
sub first_id {
    my $self = shift;
    return $self->{ ROOT_ID };
} #first_id

#
# Returns a new ID to assign.
#
sub get_id {
    my( $self ) = @_;
    my $new_id = MongoDB::OID->new();
    return $new_id->{value};
} #get_id


sub hash_delete {
    my( $self, $hash_id, $key ) = @_;
    my $mid = MongoDB::OID->new( value => $hash_id );
    $key =~ s/\./\\/g;
    my $obj = $self->_find_one( { _id => $mid } );
    if( $obj ) {
	die "hash_delete must be called for hash" if $obj->{ c } ne 'HASH';
	delete $obj->{ d }{ $key };
	$self->_update( { _id => $mid, }, $obj );
    }
    return;
} #hash_delete

sub hash_fetch {
    my( $self, $hash_id, $key ) = @_;
    $key =~ s/\./\\/g;
    my $hash = $self->_find_one( { _id => MongoDB::OID->new( value => $hash_id ) } );
    return $hash->{ d }->[ $key ] if $hash->{ c } ne 'HASH';
    return $hash->{ d }->{ $key } if $hash;
} #hash_fetch

sub hash_has_key {
    my( $self, $hash_id, $key ) = @_;
    $key =~ s/\./\\/g;
    my $hash = $self->_find_one( { _id => MongoDB::OID->new( value => $hash_id ) } );
    return defined( $hash->{ d }->{$key} );
} #hash_has_key

sub hash_insert {
    my( $self, $hash_id, $key, $val ) = @_;
    $key =~ s/\./\\/g;
    my $mid = MongoDB::OID->new( value => $hash_id );
    my $obj = $self->_find_one( { _id => $mid } );
    if( $obj ) {
	die "hash_insert must be called for hash" if $obj->{ c } ne 'HASH';
	$obj->{ d }{ $key } = $val;
	if( $obj ) {
	    $self->_update( { _id => $mid, }, $obj );
	}
    }
    else {
	$self->_insert( { _id => $mid, d => { $key => $val },
			  c => 'HASH', refs => index( $val, 'v' ) == 0 ? [] :
			      [ $val ] } );
    }
    return;
} #hash_insert


sub list_delete {
    my( $self, $list_id, $val, $idx ) = @_;
    my $mid = MongoDB::OID->new( value => $list_id );
    my $obj = $self->_find_one( { _id => $mid } );
    if( $obj ) {
	die "list_delete must be called for list" if $obj->{ c } ne 'ARRAY';
	my $actual_index;
	if( $val ) {
	    ( $actual_index ) = grep { $obj->{d}[$_] eq $val } ( 0..$#{$obj->{d}} );
	} else {
	    $actual_index = $idx;
	}
	if( defined( $actual_index ) ) {
	    splice @{$obj->{ d }}, $actual_index, 1;
	    $self->_update( { _id => $mid, }, $obj );
	}
    }
    return;
} #list_delete


sub list_fetch {
    my( $self, $list_id, $idx ) = @_;
    my $list = $self->_find_one( { _id => MongoDB::OID->new( value => $list_id ) } );

    return undef unless $list;

    if( $list->{ c } ne 'ARRAY' ) {
	return $list->{ d }{ $idx };
    }


    return $list->{ d }->[ $idx ] if $list;
}  #list_fetch

sub list_insert {
    my( $self, $list_id, $val, $idx ) = @_;
    my $mid = MongoDB::OID->new( value => $list_id );
    my $list_obj = $self->_find_one( { _id => $mid } );
    if( $list_obj ) {
	die "list_insert must be called for list" if $list_obj->{ c } ne 'ARRAY';
	if( defined( $idx ) && $idx <= @{$list_obj->{d}} ) {
	    splice @{$list_obj->{ d }}, $idx > @{$list_obj->{d}} ? scalar(@{$list_obj->{d}}) : $idx, 0, $val;
	}
	else {
	    push @{$list_obj->{ d }}, $val;
	}
	$self->stow( $list_id, 'ARRAY', $list_obj->{ d } );
    }
    else {
	$self->stow( $list_id, 'ARRAY', [ $val ] );
    }
    return;
} #list_insert

sub paginate {
    my( $self, $obj_id, $args ) = @_;

    my $obj = $self->_find_one( { _id => MongoDB::OID->new( value => $obj_id ) } );
    die "data structure $obj_id not found" unless $obj;

    # must cover the cases of
    #  args has search fields
    #  args has search terms but no fields

    my @search_fields = @{ $args->{ search_fields } || [] };
    my @search_terms = @{ $args->{ search_terms } || [] };
    my @hashkey_search = @{ $args->{ hashkey_search } || [] };

    my @sort_fields = @{ $args->{ sort_fields } || [] };
    my $reversed_orders = $args->{ reversed_orders } || [];

    my $limit = $args->{ limit };
    my $skip = $args->{ skip } || 0;

    my( @list_items, %hash_items );

    if( @sort_fields || (@search_fields && @search_terms) ) {  #must be searching through or sorting by objects
	my( $query, $query_args );

	if( $obj->{c} eq 'ARRAY' ) {
	    $query = { _id => { '$in' => [ map { MongoDB::OID->new( $_ ) } grep { index($_,'v') != 0 } @{$obj->{d}} ] } };
	}
	else {
	    $query = { _id => { '$in' => [ map { MongoDB::OID->new( $_ ) } grep { index($_,'v') != 0 } values %{$obj->{d}} ] } };
	}

        my @ors;
	if( @search_fields && @search_terms) { #search fields must be objects
	    for my $field ( @search_fields ) {
		for my $term ( @search_terms ) {
		    push @ors, { "d.$field" => { '$regex'=> "$term", '$options' => 'i'  } };
		}
	    }
	} # if search fields
        for my $hash_term ( @hashkey_search ) {
            push @ors, { "d.$hash_term" => { '$regex'=> "/./"  } };
        }
        $query->{'$or'} = \@ors if @ors;

	if( @sort_fields ) {
	    for my $i (0..$#sort_fields) {
		$query_args->{ sort_by }{ "d.$sort_fields[ $i ]" } = $reversed_orders->[ $i ] ? -1 : 1;
	    }
	}
	my $curs = $self->_find( $query, $query_args );

	if( defined( $limit ) ) {
	    if( $skip ) {
		$curs->skip( $skip );
	    }
	    $curs->limit( $limit );
	}

	if( $args->{ return_hash } ) {
	    my %id2key = reverse %{ $obj->{ d } };
	    return { map { $id2key{ $_->{ _id }{ value } } => $_->{ _id }{ value } } $curs->all };
	}

	return [map { $_->{ _id }{ value } } $curs->all ];

    } #if searching through or sorting by objects


    if( @search_terms || @hashkey_search ) {
	if( $obj->{c} eq 'ARRAY' ) {
	    for my $item (grep { index( $_, 'v' ) == 0 } @{ $obj->{ d } } ) {
		for my $term ( @search_terms ) {
		    if( $item =~ /$term/i ) {
			push @list_items, $item;
			last;
		    }
		}
	    }
	}
	else { #hash
	    for my $key (keys %{ $obj->{ d } } ) {
                if( grep { $key =~ /$_/i } @hashkey_search ) {
                    $hash_items{ $key } = $obj->{ d }{ $key };
                }
                elsif( grep { $obj->{ d }{ $key } =~ /^v.*$_/i } ( @search_terms ) ) {
                    $hash_items{ $key } = $obj->{ d }{ $key };
                }
	    }
	}
    } #with search terms

    elsif( $obj->{c} eq 'ARRAY' ) {
	@list_items = @{ $obj->{ d } };
    }

    else {
	%hash_items = %{ $obj->{ d } };
    }


    if( $obj->{c} eq 'ARRAY' ) {
	if( $args->{ sort } ) {
	    @list_items = sort @list_items;
	}
	if( $args->{ reverse } ) {
	    @list_items = reverse @list_items;
	}
	if( $limit ) {
	    my $end = $skip + $limit - 1;
	    $end = $end > $#list_items ? $#list_items : $end;
	    @list_items = @list_items[ $skip..$end ];
	}

	if( $args->{ return_hash } ) {
	    return { map { ($skip+$_) => $list_items[$_] } (0..$#list_items) };
	}

	return \@list_items;
    }

    my( @hash_keys ) = sort keys %hash_items;

    if( $args->{ reverse } ) {
	@hash_keys = reverse @hash_keys;
    }
    if( $limit ) {
	my $end = $skip + $limit - 1;
	$end = $end > $#hash_keys ? $#hash_keys : $end;
	@hash_keys = @hash_keys[ $skip..$end ]; # < --- make sure there is a test for this TODO
    }
    if( $args->{ return_hash } ) {
	return { map { $_ => $hash_items{$_} } @hash_keys };
    }

    return [ map { $hash_items{ $_ } } @hash_keys ];

} #paginate

sub recycle_object {
    my( $self, $obj_id ) = @_;
    $self->_remove( { _id => MongoDB::OID->new( value => $obj_id ) } );
    # not going to remove the referenced links from a recycled object, as those links
    # by definition show up in other recycleable objects.
} #recycle_object

sub recycle_objects {
    my $self = shift;

    my $cursor = $self->_find( { l => { '$gt' => 0 } } );

    my $rec_count = 0;
    while( my $obj = $cursor->next ) {
	my $id = $obj->{ _id }{ value };
	unless( $self->_has_path_to_root( $id ) ) {
	    $self->recycle_object( $id );
	    $rec_count++;
	}
    }
    return $rec_count;
} #recycle_object


sub start_transaction {}


sub stow {
    my( $self, $id, $class, $data ) = @_;

    #
    # tease out references from the data, which can be either an array ref or a hash ref
    #
    my( @refs );
    if( $class eq 'ARRAY' ) {
	@refs = grep { index( $_, 'v' ) != 0 } @$data;
    } else {
	@refs = grep { index( $_, 'v' ) != 0 } values %$data;
	my $escaped_data = {};
	for my $key (keys %$data ) {
	    my $val = $data->{$key};
	    $key =~ s/\./\\/g;
	    $escaped_data->{$key} = $val if defined($key);
	}
	$data = $escaped_data;
    }

    my $mid = MongoDB::OID->new( value => $id );
    if( $self->_find_one( { _id => $mid } ) ) {
	$self->_update( { _id => $mid, },
			{
			    d   => $data,
			    c   => $class,
			    r   => \@refs,
			    l   => time, #last updated
			} );
    }
    else {
	my $ins = $self->_insert( { _id => $mid,
				    d   => $data,
				    c   => $class,
				    r   => \@refs,
				    l   => time, #last updated
				  } );
    }
    return;
} #stow

sub stow_all {
    my( $self, $objs ) = @_;
    for my $objd ( @$objs ) {
	$self->stow( @$objd );
    }
} #stow_all

# ------------------------------------------------------------------------------------------
#      * PRIVATE METHODS *
# ------------------------------------------------------------------------------------------

sub _connect {
    my $self  = shift;
    $self->{args} ||= ref( $_[0] ) ? $_[0] : { @_ };
    my $args = $self->{args};
    my $host = $args->{ host } || 'localhost';
    $host .= ':' . ($args->{ engine_port } || 27017);
    my %mongo_args = (
	host => $host,
	);
    $mongo_args{ password } = $args->{ password } if $args->{ password };
    $mongo_args{ username } = $args->{ user } if $args->{ user };
    $self->{MONGO_CLIENT} = MongoDB::MongoClient->new( %mongo_args );
    $self->{DB} = $self->{MONGO_CLIENT}->get_database( $args->{ store } || 'yote' );
} #_connect

#
# Returns true if the given object traces back to the root. Objects that have not been completely
# written to disk are considered to have a path to root ( at least a potential one ).
#
sub _has_path_to_root {
    my( $self, $obj_id, $seen ) = @_;
    return 1 if $obj_id eq $self->first_id();
    $seen ||= { $obj_id => 1 };

    my $curs = $self->_find( { r => $obj_id } );
    while( my $obj = $curs->next ) {
	return 1 unless $obj->{ l } > 0;
	my $o_id = $obj->{ _id }{ value };
	next if $seen->{ $o_id }++;
	if( $self->_has_path_to_root( $o_id, $seen ) ) {
	    return 1;
	}
    }
    return 0;
} #_has_path_to_root


1;
__END__

=head1 NAME

Yote::IO::Mongo - A Mongo persistance engine for Yote.

=head1 DESCRIPTION

Yote::ObjProvider can be configured to use this engine. This is not meant to be used or accessed directly; this can be considered a private class.

=head1 CONFIGURATION

The package name is used as an argument to the Yote::ObjProvider package which also takes the configuration parameters for Yote::IO::Mongo.

Yote::ObjProvider::init( engine => 'Yote::IO::Mongo', engine_port => 27017, store => 'yote_db', user => 'yote_db_user', password => 'yote_db_password' );

=head1 PUBLIC METHODS

=over 4

=item commit_transaction( )

=item container_type( host_id, container_name )

returns the class name of the given container from a host class.

=item count( container_id )

returns the number of items in the given container

=item database( )

Provides a database handle. Used only in testing.

=item disconnect( )

=item ensure_datastore( )

Makes sure that the datastore has the correct table structure set up and in place.

=item fetch( id )

Returns a hash representation of a yote object, hash ref or array ref by id. The values of the object are in an internal storage format and used by Yote::ObjProvider to build the object.

=item first_id( id )

Returns the id of the first object in the system, the Root.

=item get_id( obj )

Returns the id for the given hash ref, array ref or yote object. If the argument does not have an id assigned, a new id will be assigned.

=item hash_delete( hash_id, key )

Removes the key from the hash given by the id

=item hash_fetch( hash_id, key )

=item hash_has_key( hash_id, key )

=item hash_insert( hash_id, key, value )

=item list_delete( list_id, idx )

=item list_fetch( list_id, idx )

=item list_insert( list_id, val, idx )

Inserts the item into the list with an optional index. If not given, this inserts to the end of the list.

=item new

=item paginate( container_id, args )

Returns a paginated list or hash. Arguments are

=over 4

* search_fields - a list of fields to search for in collections of yote objects
* search_terms - a list of terms to search for
* sort_fields - a list of fields to sort by for collections of yote objects
* reversed_orders - a list of true or false values corresponding to the sort_fields list. A true value means that field is sorted in reverse
* limit - maximum number of entries to return
* skip - skip this many entries before returning the list
* return_hash - return the result as a hashtable rather than as a list
* reverse - return the result in reverse order

=back

=item recycle_object( obj_id )

Sets the available for recycle mark on the object entry in the database by object id and removes its data.

=item recycle_objects( start_id, end_id )

Recycles all objects in the range given if they cannot trace back a path to root.

=item start_transaction( )

=item stow( id, class, data )

Stores the object of class class encoded in the internal data format into the data store.

=item stow_all( )

Stows all objects that are marked as dirty. This is called automatically by the application server and need not be explicitly called.


=back

=head1 AUTHOR

Eric Wolf
coyocanid@gmail.com
http://madyote.com

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2011 Eric Wolf

This module is free software; it can be used under the same terms as perl
itself.

=cut
