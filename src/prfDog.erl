%% -*- erlang-indent-level: 2 -*-
%%% Created : 17 Oct 2008 by Mats Cronqvist <masse@kreditor.se>

%% implements a proxy function between watchdog and the prf consumers.

-module(prfDog).
-author('Mats Cronqvist').

%% prf callbacks
-export([collect/1,config/2]).

-behaviour(gen_server).
-export([init/1,terminate/2,code_change/3,
         handle_call/3,handle_cast/2,handle_info/2]).

-export([state/0]).
state() ->
  gen_server:call(?MODULE,state).

-include("log.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% prf callbacks, runs in the prfTarg process

collect(init) ->
  gen_server:start_link({local,?MODULE},?MODULE,[],[]),
  {[],{?MODULE,[]}};
collect(LD) ->
  {LD,{?MODULE,gen_server:call(?MODULE,get_data)}}.

config(LD,{port,Port}) when is_integer(Port) ->
  gen_server:call(?MODULE,{config,{port,Port}}),
  LD;
config(LD,{secret,Secret}) when is_list(Secret) ->
  gen_server:call(?MODULE,{config,{secret,Secret}}),
  LD.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks

%% boilerplate
terminate(_Reason,_State) ->
  ok.

code_change(_OldVsn,State,_Extra) ->
  {ok,State}.

handle_cast(_What,State) ->
  {noreply,State}.

%% not boilerplate
-record(ld,{port,
            acceptor,
            udp_socket,
            tcp_sockets=[],
            msg=orddict:new(),
            secret}).

init([]) ->
  {ok,#ld{}}.

handle_call(state,_,LD) ->
  Fields = record_info(fields,ld),
  {reply,lists:zip(Fields,tl(tuple_to_list(LD))),LD};
handle_call({config,{port,Port}},_,LD) ->
  {reply,[],LD#ld{acceptor=accept(Port),udp_socket=udp_open(Port)}};
handle_call({config,{secret,Secret}},_,LD) ->
  {reply,[],LD#ld{secret=Secret}};
handle_call(get_data,_,LD) ->
  {reply,LD#ld.msg,LD#ld{msg=orddict:new()}}.

handle_info({new_socket,Sock},LD) ->
  %% we accepted a socket towards a producer.
  {noreply,LD#ld{tcp_sockets=[Sock|LD#ld.tcp_sockets]}};
handle_info({tcp,Sock,Bin},LD) ->
  case lists:member(Sock,LD#ld.tcp_sockets) of
    true ->
      %% got data from a known socket. this is good
      {noreply,decrypt(Bin,LD)};
    false->
      %% got data from unknown socket. wtf?
      ?log([{data_from,Sock},{bytes,byte_size(Bin)}]),
      {noreply,LD}
  end;
handle_info({tcp_closed, Sock},LD) ->
  case lists:member(Sock,LD#ld.tcp_sockets) of
    true ->
      {noreply,LD#ld{tcp_sockets=LD#ld.tcp_sockets--[Sock]}};
    false ->
      ?log([{unknown_socket_exited,Sock}]),
      {noreply,LD}
  end;
handle_info({tcp_error, Sock, Reason},LD) ->
  ?log([{tcp_error,Reason},{socket,Sock}]),
  {noreply,LD};
handle_info({udp,Socket,_IP,_Port,Bin},LD) ->
  case Socket == LD#ld.udp_socket of
    true ->
      inet:setopts(Socket,[{active,once}]),
      {noreply,decrypt(Bin,LD)};
    false ->
      %% got data from unknown socket. wtf?
      ?log([{unknown_socket,Socket},{bytes,byte_size(Bin)}]),
      {noreply,LD}
  end;
handle_info(Msg,LD) ->
  ?log([{unrec,Msg}]),
  {noreply,LD}.

decrypt(Bin,LD) ->
  case LD#ld.secret of
    undefined ->
      ?log([{no_secret}]),
      LD;
    Secret ->
      case prf_crypto:decrypt(Secret,Bin) of
        {watchdog,Node,TS,Trig,Msg} ->
          LD#ld{msg=orddict:store({Node,TS,Trig},Msg,LD#ld.msg)};
        _ ->
          ?log({decrypt_failed}),
          LD
      end
  end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% UPD socket
udp_open(Port) ->
  {ok,Socket} = gen_udp:open(Port,
                             [binary,
                              {recbuf,1024*1024},
                              {reuseaddr, true},
                              {active, once}]),
  Socket.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% TCP socket
%% accept is blocking, so it runs in its own process
accept(Port) ->
  erlang:spawn_link(fun() -> acceptor(Port) end).

acceptor(Port) ->
  Opts = [binary,{reuseaddr,true},{active,true},{packet,4}],
  {ok,ListenSock} = gen_tcp:listen(Port,Opts),
  acceptor_loop(ListenSock).

acceptor_loop(ListenSock) ->
  {ok,Socket} = gen_tcp:accept(ListenSock),
  ?MODULE ! {new_socket,Socket},
  gen_tcp:controlling_process(Socket,whereis(?MODULE)),
  acceptor_loop(ListenSock).
