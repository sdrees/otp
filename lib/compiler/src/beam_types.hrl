%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2019. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%% Common term types for passes operating on beam SSA and assembly. Helper
%% functions for wrangling these can be found in beam_types.erl
%%
%% The type lattice is as follows:
%%
%%  any                  Any Erlang term (top element).
%%
%%    - #t_atom{}        Atom, or a set thereof.
%%    - #t_bitstring{}   Bitstring.
%%    - #t_bs_context{}  Match context.
%%    - #t_fun{}         Fun.
%%    - #t_map{}         Map.
%%    - number           Any number.
%%       -- float        Floating point number.
%%       -- integer      Integer.
%%    - list             Any list.
%%       -- cons         Cons (nonempty list).
%%       -- nil          The empty list.
%%    - #t_tuple{}       Tuple.
%%
%%  none                 No type (bottom element).
%%
%% We also use #t_union{} to represent conflicting types produced by certain
%% expressions, e.g. the "#t_atom{} or #t_tuple{}" of lists:keyfind/3, which is
%% very useful for preserving type information when we would otherwise have
%% reduced it to 'any'. Since few operations can make direct use of this extra
%% type information, types should generally be normalized to one of the above
%% before use.

-define(ATOM_SET_SIZE, 5).

-record(t_atom, {elements=any :: 'any' | [atom()]}).
-record(t_fun, {arity=any :: arity() | 'any'}).
-record(t_integer, {elements=any :: 'any' | {integer(),integer()}}).
-record(t_bitstring, {unit=1 :: pos_integer()}).
-record(t_bs_context, {slots=0 :: non_neg_integer(),
                       valid=0 :: non_neg_integer()}).
-record(t_map, {elements=#{} :: map_elements()}).
-record(t_tuple, {size=0 :: integer(),
                  exact=false :: boolean(),
                  elements=#{} :: tuple_elements()}).

%% Known element types, unknown elements are assumed to be 'any'. The key is
%% a 1-based integer index for tuples, and a plain literal for maps (that is,
%% not wrapped in a #b_literal{}, just the value itself).

-type tuple_elements() :: #{ Key :: pos_integer() => type() }.
-type map_elements() :: #{ Key :: term() => type() }.

-type elements() :: tuple_elements() | map_elements().

-type normal_type() :: any | none |
                       list | number |
                       #t_atom{} | #t_bitstring{} | #t_bs_context{} |
                       #t_fun{} | #t_integer{} | #t_map{} | #t_tuple{} |
                       'cons' | 'float' | 'nil'.

-type record_key() :: {Arity :: integer(), Tag :: normal_type() }.
-type record_set() :: ordsets:ordset({record_key(), #t_tuple{}}).
-type tuple_set() :: #t_tuple{} | record_set().

-record(t_union, {atom=none :: none | #t_atom{},
                  list=none :: none | list | cons | nil,
                  number=none :: none | number | float | #t_integer{},
                  tuple_set=none :: none | tuple_set(),
                  other=none :: normal_type()}).

-type type() :: #t_union{} | normal_type().
