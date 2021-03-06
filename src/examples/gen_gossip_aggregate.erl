%% @doc
%% Implements a simple aggregation-based protocol. This will
%% calculate the sum for an entire cluster of nodes.
%% round_length/2 defines how long it takes to converge on the answer.
%% We calculate the sum of the cluster by taking the average of the value
%% and multiplying it by the number of nodes in the conversation.
%%
%% Usage:
%%
%%   (a@machine1)> gen_gossip_aggregate:start_link(25).
%%   (b@machine1)> gen_gossip_aggregate:start_link(25).
%%   (b@machine1)> net_adm:ping('a@machine1').
%%
%% @end
-module(gen_gossip_aggregate).
-behaviour(gen_gossip).

%% API
-export([start_link/1]).

%% gen_gossip callbacks
-export([init/1,
         gossip_freq/1,
         round_finish/2,
         round_length/2,
         digest/1,
         join/2,
         expire/2,
         handle_gossip/4]).

-record(state, {
    value = 0
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Number) ->
    gen_gossip:register_handler(?MODULE, [Number],  aggregate).

%%%===================================================================
%%% gen_gossip callbacks
%%%===================================================================

init([Number]) ->
    {ok, #state{value=Number}}.

% Defines how frequently we want to send a gossip message.
% In milliseconds.
gossip_freq(State) ->
    {reply, 1000, State}.

% The total number of cycles needed to reach convergence.
% Best to experiment and figure out how many cycles it takes
% your algorithm to reach convergence then assign that number
round_length(NodeCount, State) ->
    Length = ceil(math:log(NodeCount * NodeCount)) + 1,
    {reply, Length, State}.

% Callback signifiying end of a round
round_finish(NodeCount, State) ->
    io:format("=== end of round ===~n"),
    io:format(">>> SUM : ~p~n", [State#state.value * NodeCount]),
    {noreply, State}.

% First message sent when talking to another node.
digest(State) ->
    {reply, State#state.value, _HandleToken = push, State}.

% Callback triggered when you join a cluster of nodes
join(Nodelist, State) ->
    io:format("Joined cluster ~p~n", [Nodelist]),
    {noreply, State}.

% Callback triggered when a node crashes
expire(_Node, State) ->
    {noreply, State}.

handle_gossip(push, Value, _From, State) ->
    io:format("got push~n"),
    NewValue = (Value + State#state.value) / 2,
    {reply, State#state.value, _HandleToken = pull, State#state{value=NewValue}};

handle_gossip(pull, Value, _From, State) ->
    io:format("got sym push~n"),
    NewValue = (Value + State#state.value) / 2,
    {noreply, State#state{value=NewValue}}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

ceil(X) ->
    T = erlang:trunc(X),
    case (X - T) of
        Neg when Neg < 0 -> T;
        Pos when Pos > 0 -> T + 1;
        _ -> T
    end.
