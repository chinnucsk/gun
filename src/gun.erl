%% Copyright (c) 2013, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(gun).

%% Connection.
-export([open/2]).
-export([open/3]).
-export([close/1]).
-export([shutdown/1]).

%% Requests.
-export([delete/2]).
-export([delete/3]).
-export([get/2]).
-export([get/3]).
-export([head/2]).
-export([head/3]).
-export([options/2]).
-export([options/3]).
-export([patch/3]).
-export([patch/4]).
-export([post/3]).
-export([post/4]).
-export([put/3]).
-export([put/4]).
-export([request/4]).
-export([request/5]).

%% Streaming data.
-export([data/4]).

%% Cancelling a stream.
-export([cancel/2]).

%% Websocket.
-export([ws_upgrade/2]).
-export([ws_upgrade/3]).
-export([ws_send/2]).

%% Internals.
-export([start_link/4]).
-export([init/5]).
-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).

-type conn_type() :: ssl | tcp | tcp_spdy.
-type headers() :: [{iodata(), iodata()}].

-type ws_close_code() :: 1000..4999.
-type ws_frame() :: close | ping | pong
	| {text | binary | close | ping | pong, iodata()}
	| {close, ws_close_code(), iodata()}.

-type opts() :: [{keepalive, pos_integer()}
	| {retry, non_neg_integer()}
	| {retry_timeout, pos_integer()}
	| {type, conn_type()}].
-export_type([opts/0]).

-record(state, {
	parent :: pid(),
	owner :: pid(),
	host :: inet:hostname(),
	port :: inet:port_number(),
	keepalive :: pos_integer(),
	type :: conn_type(),
	retry :: non_neg_integer(),
	retry_timeout :: pos_integer(),
	socket :: inet:socket() | ssl:sslsocket(),
	transport :: module(),
	protocol :: module(),
	protocol_state :: any()
}).

%% Connection.

-spec open(inet:hostname(), inet:port_number())
	-> {ok, pid()} | {error, any()}.
open(Host, Port) ->
	open(Host, Port, []).

-spec open(inet:hostname(), inet:port_number(), opts())
	-> {ok, pid()} | {error, any()}.
open(Host, Port, Opts) ->
	case open_opts(Opts) of
		ok ->
			supervisor:start_child(gun_sup, [self(), Host, Port, Opts]);
		Error ->
			Error
	end.

%% @private
open_opts([]) ->
	ok;
open_opts([{keepalive, K}|Opts]) when is_integer(K), K > 0 ->
	open_opts(Opts);
open_opts([{retry, R}|Opts]) when is_integer(R), R >= 0 ->
	open_opts(Opts);
open_opts([{retry_timeout, T}|Opts]) when is_integer(T) > 0 ->
	open_opts(Opts);
open_opts([{type, T}|Opts])
		when T =:= tcp; T =:= tcp_spdy; T =:= ssl ->
	open_opts(Opts);
open_opts([Opt|_]) ->
	{error, {options, Opt}}.

-spec close(pid()) -> ok.
close(ServerPid) ->
	supervisor:terminate_child(gun_sup, ServerPid).

-spec shutdown(pid()) -> ok.
shutdown(ServerPid) ->
	_ = ServerPid ! {shutdown, self()},
	ok.

%% Requests.

-spec delete(pid(), iodata()) -> reference().
delete(ServerPid, Path) ->
	request(ServerPid, <<"DELETE">>, Path, []).

-spec delete(pid(), iodata(), headers()) -> reference().
delete(ServerPid, Path, Headers) ->
	request(ServerPid, <<"DELETE">>, Path, Headers).

-spec get(pid(), iodata()) -> reference().
get(ServerPid, Path) ->
	request(ServerPid, <<"GET">>, Path, []).

-spec get(pid(), iodata(), headers()) -> reference().
get(ServerPid, Path, Headers) ->
	request(ServerPid, <<"GET">>, Path, Headers).

-spec head(pid(), iodata()) -> reference().
head(ServerPid, Path) ->
	request(ServerPid, <<"HEAD">>, Path, []).

-spec head(pid(), iodata(), headers()) -> reference().
head(ServerPid, Path, Headers) ->
	request(ServerPid, <<"HEAD">>, Path, Headers).

-spec options(pid(), iodata()) -> reference().
options(ServerPid, Path) ->
	request(ServerPid, <<"OPTIONS">>, Path, []).

-spec options(pid(), iodata(), headers()) -> reference().
options(ServerPid, Path, Headers) ->
	request(ServerPid, <<"OPTIONS">>, Path, Headers).

-spec patch(pid(), iodata(), headers()) -> reference().
patch(ServerPid, Path, Headers) ->
	request(ServerPid, <<"PATCH">>, Path, Headers).

-spec patch(pid(), iodata(), headers(), iodata()) -> reference().
patch(ServerPid, Path, Headers, Body) ->
	request(ServerPid, <<"PATCH">>, Path, Headers, Body).

-spec post(pid(), iodata(), headers()) -> reference().
post(ServerPid, Path, Headers) ->
	request(ServerPid, <<"POST">>, Path, Headers).

-spec post(pid(), iodata(), headers(), iodata()) -> reference().
post(ServerPid, Path, Headers, Body) ->
	request(ServerPid, <<"POST">>, Path, Headers, Body).

-spec put(pid(), iodata(), headers()) -> reference().
put(ServerPid, Path, Headers) ->
	request(ServerPid, <<"PUT">>, Path, Headers).

-spec put(pid(), iodata(), headers(), iodata()) -> reference().
put(ServerPid, Path, Headers, Body) ->
	request(ServerPid, <<"PUT">>, Path, Headers, Body).

-spec request(pid(), iodata(), iodata(), headers()) -> reference().
request(ServerPid, Method, Path, Headers) ->
	StreamRef = make_ref(),
	_ = ServerPid ! {request, self(), StreamRef, Method, Path, Headers},
	StreamRef.

-spec request(pid(), iodata(), iodata(), headers(), iodata()) -> reference().
request(ServerPid, Method, Path, Headers, Body) ->
	StreamRef = make_ref(),
	_ = ServerPid ! {request, self(), StreamRef, Method, Path, Headers, Body},
	StreamRef.

%% Streaming data.

-spec data(pid(), reference(), fin | nofin, iodata()) -> ok.
data(ServerPid, StreamRef, IsFin, Data) ->
	_ = ServerPid ! {data, self(), StreamRef, IsFin, Data},
	ok.

%% Cancelling a stream.

-spec cancel(pid(), reference()) -> ok.
cancel(ServerPid, StreamRef) ->
	_ = ServerPid ! {cancel, self(), StreamRef},
	ok.

%% Websocket.

-spec ws_upgrade(pid(), iodata()) -> ok.
ws_upgrade(ServerPid, Path) ->
	ws_upgrade(ServerPid, Path, []).

-spec ws_upgrade(pid(), iodata(), headers()) -> ok.
ws_upgrade(ServerPid, Path, Headers) ->
	_ = ServerPid ! {ws_upgrade, self(), Path, Headers},
	ok.

-spec ws_send(pid(), ws_frame() | [ws_frame()]) -> ok.
ws_send(ServerPid, Frames) ->
	_ = ServerPid ! {ws_send, self(), Frames},
	ok.

%% Internals.

start_link(Owner, Host, Port, Opts) ->
	proc_lib:start_link(?MODULE, init,
		[self(), Owner, Host, Port, Opts]).

%% @doc Faster alternative to proplists:get_value/3.
%% @private
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.

init(Parent, Owner, Host, Port, Opts) ->
	try
		ok = proc_lib:init_ack(Parent, {ok, self()}),
		Keepalive = get_value(keepalive, Opts, 5000),
		Retry = get_value(retry, Opts, 5),
		RetryTimeout = get_value(retry_timeout, Opts, 5000),
		Type = get_value(type, Opts, ssl),
		connect(#state{parent=Parent, owner=Owner, host=Host, port=Port,
			keepalive=Keepalive, type=Type,
			retry=Retry, retry_timeout=RetryTimeout}, Retry)
	catch Class:Reason ->
		Owner ! {gun_error, self(), {{Class, Reason, erlang:get_stacktrace()},
			"An unexpected error occurred."}}
	end.

connect(State=#state{owner=Owner, host=Host, port=Port, type=ssl}, Retries) ->
	Transport = ranch_ssl,
	Opts = [binary, {active, false}, {client_preferred_next_protocols,
		client, [<<"spdy/3">>, <<"http/1.1">>], <<"http/1.1">>}],
	case Transport:connect(Host, Port, Opts) of
		{ok, Socket} ->
			Protocol = gun_spdy,
%% @todo For some reasons this function doesn't work? Bug submitted.
%			Protocol = case ssl:negotiated_next_protocol(Socket) of
%				{ok, <<"spdy/3">>} -> gun_spdy;
%				_ -> gun_http
%			end,
			ProtoState = Protocol:init(Owner, Socket, Transport),
			before_loop(State#state{socket=Socket, transport=Transport,
				protocol=Protocol, protocol_state=ProtoState});
		{error, _} ->
			retry_loop(State, Retries - 1)
	end;
connect(State=#state{owner=Owner, host=Host, port=Port, type=Type}, Retries) ->
	Transport = ranch_tcp,
	Opts = [binary, {active, false}],
	case Transport:connect(Host, Port, Opts) of
		{ok, Socket} ->
			Protocol = case Type of
				tcp_spdy -> gun_spdy;
				tcp -> gun_http
			end,
			ProtoState = Protocol:init(Owner, Socket, Transport),
			before_loop(State#state{socket=Socket, transport=Transport,
				protocol=Protocol, protocol_state=ProtoState});
		{error, _} ->
			retry_loop(State, Retries - 1)
	end.

%% Too many failures, give up.
retry_loop(_, 0) ->
	error(too_many_retries);
retry_loop(State=#state{parent=Parent, retry_timeout=RetryTimeout}, Retries) ->
	_ = erlang:send_after(RetryTimeout, self(), retry),
	receive
		retry ->
			connect(State, Retries);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
				{retry_loop, State, Retries})
	end.

before_loop(State=#state{keepalive=Keepalive}) ->
	_ = erlang:send_after(Keepalive, self(), keepalive),
	loop(State).

loop(State=#state{parent=Parent, owner=Owner, host=Host,
		retry=Retry, socket=Socket, transport=Transport,
		protocol=Protocol, protocol_state=ProtoState}) ->
	{OK, Closed, Error} = Transport:messages(),
	ok = Transport:setopts(Socket, [{active, once}]),
	receive
		{OK, Socket, Data} ->
			case Protocol:handle(Data, ProtoState) of
				error ->
					Transport:close(Socket),
					retry_loop(State#state{socket=undefined,
						transport=undefined, protocol=undefined}, Retry);
				ProtoState2 ->
					loop(State#state{protocol_state=ProtoState2})
			end;
		{Closed, Socket} ->
			Transport:close(Socket),
			retry_loop(State#state{socket=undefined, transport=undefined,
				protocol=undefined}, Retry);
		{Error, Socket, _} ->
			Transport:close(Socket),
			retry_loop(State#state{socket=undefined, transport=undefined,
				protocol=undefined}, Retry);
		keepalive ->
			ProtoState2 = Protocol:keepalive(ProtoState),
			before_loop(State#state{protocol_state=ProtoState2});
		{request, Owner, StreamRef, Method, Path, Headers} ->
			ProtoState2 = Protocol:request(ProtoState,
				StreamRef, Method, Host, Path, Headers),
			loop(State#state{protocol_state=ProtoState2});
		{request, Owner, StreamRef, Method, Path, Headers, Body} ->
			ProtoState2 = Protocol:request(ProtoState,
				StreamRef, Method, Host, Path, Headers, Body),
			loop(State#state{protocol_state=ProtoState2});
		{data, Owner, StreamRef, IsFin, Data} ->
			ProtoState2 = Protocol:data(ProtoState,
				StreamRef, IsFin, Data),
			loop(State#state{protocol_state=ProtoState2});
		{cancel, Owner, StreamRef} ->
			ProtoState2 = Protocol:cancel(ProtoState, StreamRef),
			loop(State#state{protocol_state=ProtoState2});
		{ws_upgrade, Owner, Path, Headers} when Protocol =/= gun_spdy ->
			%% @todo
			ProtoState2 = Protocol:ws_upgrade(ProtoState,
				Path, Headers),
			ws_loop(State#state{protocol=gun_ws, protocol_state=ProtoState2});
		{shutdown, Owner} ->
			%% @todo Protocol:shutdown?
			ok;
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
				{loop, State});
		Any when is_tuple(Any), is_pid(element(2, Any)) ->
			element(2, Any) ! {gun_error, self(), {notowner,
				"Operations are restricted to the owner of the connection."}},
			loop(State);
		{ws_upgrade, _, _, _} ->
			Owner ! {gun_error, self(), {badstate,
				"Websocket over SPDY isn't supported."}},
			loop(State);
		{ws_send, _, _} ->
			Owner ! {gun_error, self(), {badstate,
				"Connection needs to be upgraded to Websocket "
				"before the gun:ws_send/1 function can be used."}},
			loop(State);
		Any ->
			error_logger:error_msg("Unexpected message: ~w~n", [Any])
	end.

ws_loop(State=#state{parent=Parent, owner=Owner, retry=Retry, socket=Socket,
		transport=Transport, protocol=Protocol, protocol_state=ProtoState}) ->
	{OK, Closed, Error} = Transport:messages(),
	ok = Transport:setopts(Socket, [{active, once}]),
	receive
		{OK, Socket, Data} ->
			ProtoState2 = Protocol:handle(ProtoState, Data),
			ws_loop(State#state{protocol_state=ProtoState2});
		{Closed, Socket} ->
			Transport:close(Socket),
			retry_loop(State#state{socket=undefined, transport=undefined,
				protocol=undefined}, Retry);
		{Error, Socket, _} ->
			Transport:close(Socket),
			retry_loop(State#state{socket=undefined, transport=undefined,
				protocol=undefined}, Retry);
		%% @todo keepalive
		{ws_send, Owner, Frames} when is_list(Frames) ->
			todo; %% @todo
		{ws_send, Owner, Frame} ->
			{todo, Frame}; %% @todo
		{shutdown, Owner} ->
			%% @todo Protocol:shutdown?
			ok;
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
				{ws_loop, State});
		Any when is_tuple(Any), is_pid(element(2, Any)) ->
			element(2, Any) ! {gun_error, self(), {notowner,
				"Operations are restricted to the owner of the connection."}},
			loop(State);
		Any ->
			error_logger:error_msg("Unexpected message: ~w~n", [Any])
	end.

system_continue(_, _, {retry_loop, State, Retry}) ->
	retry_loop(State, Retry);
system_continue(_, _, {loop, State}) ->
	loop(State);
system_continue(_, _, {ws_loop, State}) ->
	ws_loop(State).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, _) ->
	exit(Reason).

system_code_change(Misc, _, _, _) ->
	{ok, Misc}.
