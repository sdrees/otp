%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2007-2020. All Rights Reserved.
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

-module(ssl_session_ticket_SUITE).

-behaviour(ct_suite).

%% Callback functions
-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

%% Testcases
-export([basic/0,
         basic/1,
         basic_anti_replay/0,
         basic_anti_replay/1,
         basic_stateful_stateless/0,
         basic_stateful_stateless/1,
         basic_stateless_stateful/0,
         basic_stateless_stateful/1,
         basic_stateful_stateless_anti_replay/0,
         basic_stateful_stateless_anti_replay/1,
         basic_stateless_stateful_anti_replay/0,
         basic_stateless_stateful_anti_replay/1,
         basic_stateful_stateless_faulty_ticket/0,
         basic_stateful_stateless_faulty_ticket/1,
         basic_stateless_stateful_faulty_ticket/0,
         basic_stateless_stateful_faulty_ticket/1,
         hello_retry_request/0,
         hello_retry_request/1,
         multiple_tickets/0,
         multiple_tickets/1,
         multiple_tickets_2hash/0,
         multiple_tickets_2hash/1]).

-include("tls_handshake.hrl").

-include_lib("common_test/include/ct.hrl").

-define(SLEEP, 500).


%%--------------------------------------------------------------------
%% Common Test interface functions -----------------------------------
%%--------------------------------------------------------------------
all() ->
    [
     {group, 'tlsv1.3'}
    ].

groups() ->
    [{'tlsv1.3', [], [{group, stateful},
                      {group, stateless},
                      {group, mixed}]},
     {stateful, [], session_tests()},
     {stateless, [], session_tests() ++ [basic_anti_replay]},
     {mixed, [], mixed_tests()}].

session_tests() ->
    [basic,
     hello_retry_request,
     multiple_tickets,
     multiple_tickets_2hash].

mixed_tests() ->
    [
     basic_stateful_stateless,
     basic_stateless_stateful,
     basic_stateful_stateless_anti_replay,
     basic_stateless_stateful_anti_replay,
     basic_stateful_stateless_faulty_ticket,
     basic_stateless_stateful_faulty_ticket
    ].

init_per_suite(Config0) ->
    catch crypto:stop(),
    try crypto:start() of
	ok ->
	    ssl_test_lib:clean_start(),
            ssl_test_lib:make_rsa_cert(Config0)
    catch _:_ ->
	    {skip, "Crypto did not start"}
    end.

end_per_suite(_Config) ->
    ssl:stop(),
    application:stop(crypto).

init_per_group(stateful, Config) ->
    [{server_ticket_mode, stateful} | proplists:delete(server_ticket_mode, Config)];
init_per_group(stateless, Config) ->
    [{server_ticket_mode, stateless} | proplists:delete(server_ticket_mode, Config)];
init_per_group(GroupName, Config) ->
    ssl_test_lib:init_per_group(GroupName, Config).

end_per_group(GroupName, Config) ->
    ssl_test_lib:end_per_group(GroupName, Config).

init_per_testcase(_, Config)  ->
    ssl:stop(),
    application:load(ssl),
    ssl:start(),
    ct:timetrap({seconds, 15}),
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Test Cases --------------------------------------------------------
%%--------------------------------------------------------------------

basic() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic(Config) when is_list(Config) ->
    ClientOpts0 = ssl_test_lib:ssl_options(client_rsa_verify_opts, Config),
    ServerOpts0 = ssl_test_lib:ssl_options(server_rsa_verify_opts, Config),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),
    ServerTicketMode = proplists:get_value(server_ticket_mode, Config),

    %% Configure session tickets
    ClientOpts = [{session_tickets, auto}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ClientOpts0],
    ServerOpts = [{session_tickets, ServerTicketMode}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ServerOpts0],

    Server0 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts}]),
    Port0 = ssl_test_lib:inet_port(Server0),

    %% Store ticket from first connection
    Client0 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Full handshake
                                                verify_active_session_resumption,
                                                [false]}},
                                         {from, self()}, {options, ClientOpts}]),
    ssl_test_lib:check_result(Server0, ok, Client0, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [true]}}},

    %% Wait for session ticket
    ct:sleep(100),

    ssl_test_lib:close(Client0),

    %% Use ticket
    Client1 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Short handshake
                                                verify_active_session_resumption,
                                                [true]}},
                                         {from, self()}, {options, ClientOpts}]),
    ssl_test_lib:check_result(Server0, ok, Client1, ok),

    process_flag(trap_exit, false),
    ssl_test_lib:close(Server0),
    ssl_test_lib:close(Client1).

basic_anti_replay() ->
    [{doc,"Test session resumption with stateless session tickets and anti_replay (erlang client - erlang server)"}].
basic_anti_replay(Config) when is_list(Config) ->
    ClientOpts0 = ssl_test_lib:ssl_options(client_rsa_verify_opts, Config),
    ServerOpts0 = ssl_test_lib:ssl_options(server_rsa_verify_opts, Config),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),
    ServerTicketMode = proplists:get_value(server_ticket_mode, Config),

    %% Configure session tickets
    ClientOpts = [{session_tickets, auto}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ClientOpts0],
    ServerOpts = [{session_tickets, ServerTicketMode}, {log_level, debug},
                  {anti_replay, '10k'},
                  {versions, ['tlsv1.2','tlsv1.3']}|ServerOpts0],

    Server0 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts}]),
    Port0 = ssl_test_lib:inet_port(Server0),

    %% Store ticket from first connection
    Client0 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Full handshake
                                                verify_active_session_resumption,
                                                [false]}},
                                         {from, self()}, {options, ClientOpts}]),
    ssl_test_lib:check_result(Server0, ok, Client0, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [true]}}},

    %% Wait for session ticket
    ct:sleep(100),

    ssl_test_lib:close(Client0),

    %% Use ticket
    Client1 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Short handshake
                                                verify_active_session_resumption,
                                                [true]}},
                                         {from, self()}, {options, ClientOpts}]),
    ssl_test_lib:check_result(Server0, ok, Client1, ok),

    process_flag(trap_exit, false),
    ssl_test_lib:close(Server0),
    ssl_test_lib:close(Client1).

basic_stateful_stateless() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic_stateful_stateless(Config) when is_list(Config) ->
    do_test_mixed(Config,
                  [{session_tickets, auto},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateful},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateless},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}]).

basic_stateless_stateful() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic_stateless_stateful(Config) when is_list(Config) ->
    do_test_mixed(Config,
                  [{session_tickets, auto},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateless},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateful},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}]).

basic_stateful_stateless_anti_replay() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic_stateful_stateless_anti_replay(Config) when is_list(Config) ->
    do_test_mixed(Config,
                  [{session_tickets, auto},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateful},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateless},
                   {log_level, debug},
                   {anti_replay, '10k'},
                   {versions, ['tlsv1.2','tlsv1.3']}]).

basic_stateless_stateful_anti_replay() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic_stateless_stateful_anti_replay(Config) when is_list(Config) ->
    do_test_mixed(Config,
                  [{session_tickets, auto},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateless},
                   {log_level, debug},
                   {anti_replay, '10k'},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateful},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}]).

basic_stateful_stateless_faulty_ticket() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic_stateful_stateless_faulty_ticket(Config) when is_list(Config) ->
    do_test_mixed(Config,
                  [{session_tickets, auto},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, manual},
                   {use_ticket, [<<131,100,0,12,"faultyticket">>,
                                 <<"faulty ticket">>]},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateless},
                   {log_level, debug},
                   {anti_replay, '10k'},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateful},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}]).

basic_stateless_stateful_faulty_ticket() ->
    [{doc,"Test session resumption with session tickets (erlang client - erlang server)"}].
basic_stateless_stateful_faulty_ticket(Config) when is_list(Config) ->
    do_test_mixed(Config,
                  [{session_tickets, auto},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, manual},
                   {use_ticket, [<<"faulty ticket">>,
                                 <<131,100,0,12,"faultyticket">>]},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateless},
                   {log_level, debug},
                   {anti_replay, '10k'},
                   {versions, ['tlsv1.2','tlsv1.3']}],
                  [{session_tickets, stateful},
                   {log_level, debug},
                   {versions, ['tlsv1.2','tlsv1.3']}]).

hello_retry_request() ->
    [{doc,"Test session resumption with session tickets and hello_retry_request (erlang client - erlang server)"}].
hello_retry_request(Config) when is_list(Config) ->
    ClientOpts0 = ssl_test_lib:ssl_options(client_rsa_verify_opts, Config),
    ServerOpts0 = ssl_test_lib:ssl_options(server_rsa_verify_opts, Config),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),
    ServerTicketMode = proplists:get_value(server_ticket_mode, Config),
    
    %% Configure session tickets
    ClientOpts = [{session_tickets, auto}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']},
                  {supported_groups,[secp256r1, x25519]}|ClientOpts0],
    ServerOpts = [{session_tickets, ServerTicketMode}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']},
                  {supported_groups, [x448, x25519]}|ServerOpts0],

    Server0 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts}]),
    Port0 = ssl_test_lib:inet_port(Server0),

    %% Store ticket from first connection
    Client0 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,
                                                verify_active_session_resumption,
                                                [false]}},
                                         {from, self()},  {options, ClientOpts}]),
    ssl_test_lib:check_result(Server0, ok, Client0, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [true]}}},

    %% Wait for session ticket
    ct:sleep(100),

    ssl_test_lib:close(Client0),

    %% Use ticket
    Client1 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,
                                                verify_active_session_resumption,
                                                [true]}},
                                         {from, self()}, {options, ClientOpts}]),
    ssl_test_lib:check_result(Server0, ok, Client1, ok),

    process_flag(trap_exit, false),
    ssl_test_lib:close(Server0),
    ssl_test_lib:close(Client1).

multiple_tickets() ->
    [{doc,"Test session resumption with multiple session tickets (erlang client - erlang server)"}].
multiple_tickets(Config) when is_list(Config) ->
    ClientOpts0 = ssl_test_lib:ssl_options(client_rsa_verify_opts, Config),
    ServerOpts0 = ssl_test_lib:ssl_options(server_rsa_verify_opts, Config),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),
    ServerTicketMode = proplists:get_value(server_ticket_mode, Config),

    %% Configure session tickets
    ClientOpts = [{session_tickets, manual}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ClientOpts0],
    ServerOpts = [{session_tickets, ServerTicketMode}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ServerOpts0],

    Server0 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts}]),
    Port0 = ssl_test_lib:inet_port(Server0),

    %% Store ticket from first connection
    Client0 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,
                                                verify_active_session_resumption,
                                                [false, wait_reply, {tickets, 3}]}},
                                         {from, self()},  {options, ClientOpts}]),

    Tickets0 = ssl_test_lib:check_tickets(Client0),

    ct:pal("Received tickets: ~p~n", [Tickets0]),

    ssl_test_lib:check_result(Server0, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [true]}}},

    ssl_test_lib:close(Client0),

    %% Use ticket
    Client1 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,
                                                verify_active_session_resumption,
                                                [true, wait_reply, no_tickets]}},
                                         {from, self()},
                                         {options, [{use_ticket, Tickets0}|ClientOpts]}]),

    ssl_test_lib:check_result(Server0, ok, Client1, ok),

    process_flag(trap_exit, false),
    ssl_test_lib:close(Server0),
    ssl_test_lib:close(Client1).

multiple_tickets_2hash() ->
    [{doc,"Test session resumption with multiple session tickets with 2 different hash algorithms (erlang client - erlang server)"}].
multiple_tickets_2hash(Config) when is_list(Config) ->
    ClientOpts0 = ssl_test_lib:ssl_options(client_rsa_verify_opts, Config),
    ServerOpts0 = ssl_test_lib:ssl_options(server_rsa_verify_opts, Config),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),
    ServerTicketMode = proplists:get_value(server_ticket_mode, Config),
    
    %% Configure session tickets
    ClientOpts = [{session_tickets, manual}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ClientOpts0],
    ServerOpts = [{session_tickets, ServerTicketMode}, {log_level, debug},
                  {versions, ['tlsv1.2','tlsv1.3']}|ServerOpts0],

    Server0 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts}]),
    Port0 = ssl_test_lib:inet_port(Server0),

    %% Get tickets using sha256
    Client0 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,
                                                verify_active_session_resumption,
                                                [false, wait_reply, {tickets, 3}]}},
                                         {from, self()},
                                         {options, [{ciphers, [#{key_exchange => any,
                                                                 cipher => aes_128_gcm,
                                                                 mac => aead,
                                                                 prf => sha256}]}| ClientOpts]}]),

    Tickets0 = ssl_test_lib:check_tickets(Client0),

    ct:pal("Received tickets: ~p~n", [Tickets0]),

    ssl_test_lib:check_result(Server0, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [false]}}},

    ssl_test_lib:close(Client0),

    %% Get tickets using sha384
    Client1 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,
                                                verify_active_session_resumption,
                                                [false, wait_reply, {tickets, 3}]}},
                                         {from, self()},
                                         {options, [{ciphers, [#{key_exchange => any,
                                                                 cipher => aes_256_gcm,
                                                                 mac => aead,
                                                                 prf => sha384}]}| ClientOpts]}]),

    Tickets1 = ssl_test_lib:check_tickets(Client1),

    ct:pal("Received tickets: ~p~n", [Tickets1]),

    ssl_test_lib:check_result(Server0, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [true]}}},

    ssl_test_lib:close(Client1),

    %% Use tickets for handshake (server chooses TLS_AES_256_GCM_SHA384 cipher suite)
    Client2 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Short handshake
                                                verify_active_session_resumption,
                                                [true]}},
                                         {from, self()},
                                         {options, [{use_ticket, Tickets0 ++ Tickets1}|ClientOpts]}]),
    ssl_test_lib:check_result(Server0, ok, Client2, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [true]}}},

    ssl_test_lib:close(Client2),

    %% Use tickets for handshake (client chooses TLS_CHACHA20_POLY1305_SHA256 cipher suite)
    Client3 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Short handshake
                                                verify_active_session_resumption,
                                                [true]}},
                                         {from, self()},
                                         {options, [{ciphers, [#{key_exchange => any,
                                                                 cipher => chacha20_poly1305,
                                                                 mac => aead,
                                                                 prf => sha256}]},
                                                    {use_ticket, Tickets0 ++ Tickets1}|ClientOpts]}]),
    ssl_test_lib:check_result(Server0, ok, Client3, ok),

    Server0 ! {listen, {mfa, {ssl_test_lib,
                              verify_active_session_resumption,
                              [false]}}},

    ssl_test_lib:close(Client3),

    %% Use tickets (created using sha384) for handshake (client chooses
    %% TLS_CHACHA20_POLY1305_SHA256 cipher suite).
    %% Session resumption should fail as chosen cipher suite uses different hash algorithms
    %% than those supplied by the selected tickets.
    Client4 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Short handshake
                                                verify_active_session_resumption,
                                                [false]}},
                                         {from, self()},
                                         {options, [{ciphers, [#{key_exchange => any,
                                                                 cipher => chacha20_poly1305,
                                                                 mac => aead,
                                                                 prf => sha256}]},
                                                    {use_ticket, Tickets1}|ClientOpts]}]),
    ssl_test_lib:check_result(Server0, ok, Client4, ok),

    ssl_test_lib:close(Client4),

    process_flag(trap_exit, false),
    ssl_test_lib:close(Server0).


%%--------------------------------------------------------------------
%% Internal functions ------------------------------------------------
%%--------------------------------------------------------------------

do_test_mixed(Config, COpts, SOpts1, SOpts2) when is_list(Config) ->
    do_test_mixed(Config, COpts, COpts, SOpts1, SOpts2).
%%
do_test_mixed(Config, COpts1, COpts2, SOpts1, SOpts2) when is_list(Config) ->
    ClientOpts0 = ssl_test_lib:ssl_options(client_rsa_verify_opts, Config),
    ServerOpts0 = ssl_test_lib:ssl_options(server_rsa_verify_opts, Config),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),

    %% Configure session tickets
    ClientOpts1 = COpts1 ++ ClientOpts0,
    ServerOpts1 = SOpts1 ++ ServerOpts0,

    Server0 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts1}]),
    Port0 = ssl_test_lib:inet_port(Server0),

    %% Store ticket from first connection
    Client0 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port0}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Full handshake
                                                verify_active_session_resumption,
                                                [false]}},
                                         {from, self()}, {options, ClientOpts1}]),
    ssl_test_lib:check_result(Server0, ok, Client0, ok),

    %% Wait for session ticket
    ct:sleep(100),

    ssl_test_lib:close(Client0),
    ssl_test_lib:close(Server0),

    ClientOpts2 = COpts2 ++ ClientOpts0,
    ServerOpts2 = SOpts2 ++ ServerOpts0,

    Server1 =
	ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
				   {from, self()},
				   {mfa, {ssl_test_lib,
                                          verify_active_session_resumption,
                                          [false]}},
				   {options, ServerOpts2}]),
    Port1 = ssl_test_lib:inet_port(Server1),

    %% Use ticket
    Client1 = ssl_test_lib:start_client([{node, ClientNode},
                                         {port, Port1}, {host, Hostname},
                                         {mfa, {ssl_test_lib,  %% Short handshake
                                                verify_active_session_resumption,
                                                [false]}},
                                         {from, self()}, {options, ClientOpts2}]),
    ssl_test_lib:check_result(Server1, ok, Client1, ok),

    process_flag(trap_exit, false),
    ssl_test_lib:close(Server1),
    ssl_test_lib:close(Client1).
