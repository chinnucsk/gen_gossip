-module(egossip_server_test).
-include_lib("eunit/include/eunit.hrl").

-include("src/egossip.hrl").


app_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
            fun reconcile_nodes_/1,
            fun prevent_forever_wait_/1,
            fun transition_wait_to_gossip_state_/1,
            fun transition_gossip_to_wait_state_/1,
            fun gossips_if_nodelist_and_epoch_match_/1,
            fun use_latest_epoch_if_nodelist_match_/1,
            fun reconciles_nodelists_/1,
            fun remove_downed_node_/1,
            fun dont_increment_cycle_in_wait_state_/1,
            fun dont_increment_cycle_for_other_modes_/1,
            fun dont_gossip_in_wait_state_/1,
            fun dont_wait_forever_/1,
            fun proxies_out_of_band_messages_to_callback_module_/1
            ]}.

setup() ->
    meck:new(egossip_server, [passthrough]),
    meck:expect(egossip_server, send_gossip, fun(_, _, _, State) -> {ok, State} end),
    meck:expect(egossip_server, node_name, 0, a),

    Module = gossip_test,
    meck:new(Module),
    meck:expect(Module, init, 1, {ok, state}),
    meck:expect(Module, gossip_freq, 1, {reply, 1000, state}),
    meck:expect(Module, round_finish, 2, {noreply, state}),
    meck:expect(Module, round_length, 2, {reply, 10, state}),
    meck:expect(Module, digest, 1, {reply, digest, state}),
    meck:expect(Module, handle_push, 3, {reply, digest, state}),
    meck:expect(Module, handle_pull, 3, {reply, digest, state}),
    meck:expect(Module, handle_commit, 3, {reply, digest, state}),
    meck:expect(Module, handle_info, 2, {noreply, state}),
    meck:expect(Module, handle_call, 3, {reply, ok, state}),
    meck:expect(Module, handle_cast, 2, {noreply, state}),
    meck:expect(Module, code_change, 3, {ok, state}),
    meck:expect(Module, terminate, 2, ok),
    meck:expect(Module, join, 2, {noreply, state}),
    meck:expect(Module, expire, 2, {noreply, state}),
    Module.

cleanup(Module) ->
    meck:unload(egossip_server),
    meck:unload(Module).

called(Mod, Fun) ->
    History = meck:history(Mod),
    List = [match || {_, {M, F, _, _}} <- History, M == Mod, F == Fun],
    List =/= [].

dont_gossip_in_wait_state_(Module) ->
    fun() ->
        State0 = #state{module=Module},

        {next_state, gossiping, State1} = egossip_server:handle_info('$egossip_tick', waiting, State0),
        ?assert( not meck:called(egossip_server, send_gossip, [from, handle_pull, digest, State1]) )
    end.

reconcile_nodes_(Module) ->
    fun() ->
        State = #state{module=Module, mstate=state},

        %%%
        %% EQUAL SIZED ISLANDS

        % node wins tiebreaker
        meck:expect(egossip_server, node_name, 0, c),
        {_, N1} = egossip_server:reconcile_nodes([c,d], [a,b], a, State),
        ?assertEqual(N1, [a,c,d]),
        ?assert(not called( Module, join )),
        meck:reset(egossip_server),

        % node losses tiebreaker
        meck:expect(egossip_server, node_name, 0, a),
        {_, N2} = egossip_server:reconcile_nodes([a,b], [c,d], d, State),
        ?assertEqual(N2, [a,c,d]),
        ?assert( meck:called(Module, join, [ [c,d], state ]) ),
        meck:reset(egossip_server),

        % Two islands [a,b] and [c,d], a joins c #=> [a,c,d] and b joins d #=> [b,c,d]
        % an intersection now exists if these two islands talk with eachother.
        % reconcile_nodes should just perform a union and not trigger a join event.
        {_, N3} = egossip_server:reconcile_nodes([a,c,d], [b,c,d], c, State),
        ?assertEqual(N3, [a,b,c,d]),
        ?assert(not called( Module, join )),
        meck:reset(egossip_server),

        %%%
        %% SMALLER ISLAND MUST JOIN LARGER

        % intersection is greater/equal to 2
        {_, N4} = egossip_server:reconcile_nodes([a,b], [a,b,c], c, State),
        ?assertEqual(N4, [a,b,c]),
        ?assert(not called( Module, join )),
        meck:reset(egossip_server),

        % intersection is greater/equal, merges both lists
        {_, N5} = egossip_server:reconcile_nodes([a,b,c], [b,c,d,e], c, State),
        ?assertEqual(N5, [a,b,c,d,e]),
        ?assert(not called( Module, join )),
        meck:reset(egossip_server),

        % intersection exists but less than two
        {_, N6} = egossip_server:reconcile_nodes([a,b], [b,c,d], d, State),
        ?assertEqual(N6, [a,b,c,d]),
        ?assert( meck:called(Module, join, [ [b,c,d], state ]) ),
        meck:reset(egossip_server),

        % no nodes in common
        {_, N7} = egossip_server:reconcile_nodes([a,e], [b,c,d], d, State),
        ?assertEqual(N7, [a,b,c,d]),
        ?assert( meck:called(Module, join, [ [b,c,d], state ]) ),
        meck:reset(egossip_server),

        %%%
        %% LARGER ISLAND SUBSUMES SMALLER

        % no join is triggered
        {_, N8} = egossip_server:reconcile_nodes([a,c,d], [b], b, State),
        ?assertEqual(N8, [a,b,c,d]),
        ?assert( not called(Module, join) ),
        meck:reset(egossip_server)
    end.

prevent_forever_wait_(Module) ->
    % by some freak chance if we were waiting for an epoch to roll around
    % that never occurred because a higher epoch appeared then we should
    % wait for the next highest to occur to prevent waiting forever
    fun() ->
        R_Epoch = 2,
        R_Nodelist = [b],
        WaitFor = 1,
        Nodelist = [a],

        State0 = #state{module=Module, wait_for=WaitFor, nodes=Nodelist},
        Send = {R_Epoch, {handle_push, msg, from}, R_Nodelist},

        {next_state, waiting, State1} = egossip_server:waiting(Send, State0),

        ?assertEqual(State1#state.wait_for, R_Epoch + 1)
    end.

transition_wait_to_gossip_state_(Module) ->
    % to transition from waiting -> gossiping the epoch
    % specified in #state.wait_for must equal the callers epoch
    fun() ->
        R_Epoch = 1,
        R_Nodelist = [b],
        Epoch = 1,
        Nodelist = [a],

        State0 = #state{module=Module, wait_for=Epoch, nodes=Nodelist},
        Msg = {R_Epoch, {handle_push, msg, from}, R_Nodelist},

        {next_state, gossiping, _} = egossip_server:waiting(Msg, State0)
    end.

transition_gossip_to_wait_state_(Module) ->
    fun() ->
        R_Epoch = 2,
        R_Nodelist = [b],
        Epoch = 1,
        Nodelist = [a],

        State0 = #state{module=Module, nodes=Nodelist, epoch=Epoch},
        Msg = {R_Epoch, {handle_push, msg, from}, R_Nodelist},

        {next_state, waiting, _} = egossip_server:gossiping(Msg, State0)
    end.

gossips_if_nodelist_and_epoch_match_(Module) ->
    fun() ->
        R_Epoch = 1,
        R_Nodelist = [a,b],
        Epoch = 1,
        Nodelist = [a,b],

        State0 = #state{mstate=state, module=Module, nodes=Nodelist, epoch=Epoch},
        Msg = {R_Epoch, {handle_push, msg, from}, R_Nodelist},

        {next_state, gossiping, _} = egossip_server:gossiping(Msg, State0),

        % some data was pushed to the module, so it should reply with a handle_pull
        ?assert( meck:called(Module, handle_push, [ msg, from, state ]) ),
        ?assert( meck:called(egossip_server, send_gossip, [from, handle_pull, digest, State0]) )
    end.

use_latest_epoch_if_nodelist_match_(Module) ->
    % since there is clock-drift, ticks will never truly be in sync.
    % this causes other nodes to switch to the next epoch before another.
    % to do our best at synchrnoization we always use the latest epoch.
    fun() ->
        R_Epoch = 10,
        R_Nodelist = [a,b],
        Epoch = 1,
        Nodelist = [a,b],

        State0 = #state{module=Module, nodes=Nodelist, epoch=Epoch},
        Send = {R_Epoch, {handle_push, msg, from}, R_Nodelist},

        {next_state, gossiping, State1} = egossip_server:gossiping(Send, State0),

        % should also send a gossip message back
        ?assert( meck:called(egossip_server, send_gossip, [from, handle_pull, digest, State1]) ),
        ?assertEqual(State1#state.epoch, R_Epoch)
    end.

reconciles_nodelists_(Module) ->
    % two cases we will merge nodelists. First case is in
    % #3 second case is in #4 if you look at the source for egossip_server
    fun() ->
        % 3rd case
        R_EpochA = 2,
        R_NodelistA = [b,c],
        EpochA = 1,
        NodelistA = [a,c],

        StateA0 = #state{module=Module, nodes=NodelistA, epoch=EpochA},
        SendA = {R_EpochA, {handle_push, msg, from}, R_NodelistA},

        {next_state, gossiping, StateA1} = egossip_server:gossiping(SendA, StateA0),

        ?assertEqual([a,b,c], StateA1#state.nodes),

        % 4th case
        R_EpochB = EpochB = 1,
        R_NodelistB = [b,c],
        NodelistB = [a],

        StateB0 = #state{module=Module, nodes=NodelistB, epoch=EpochB},
        SendB = {R_EpochB, {handle_push, msg, from}, R_NodelistB},

        {next_state, gossiping, StateB1} = egossip_server:gossiping(SendB, StateB0),

        ?assertEqual([a,b,c], StateB1#state.nodes)
    end.

remove_downed_node_(Module) ->
    fun() ->
        Nodelist = [a,b,c],
        Epoch = 1,
        State0 = #state{module=Module, nodes=Nodelist, epoch=Epoch},

        {next_state, statename, State1} = egossip_server:handle_info({nodedown, b}, statename, State0),

        ?assertEqual([a,c], State1#state.nodes)
    end.

dont_increment_cycle_in_wait_state_(Module) ->
    fun() ->
        Nodelist = [a,b,c],
        Epoch = 1,

        State0 = #state{mode=aggregate, cycle=0, max_wait=1, module=Module, nodes=Nodelist, epoch=Epoch},

        {next_state, waiting, State1} = egossip_server:handle_info('$egossip_tick', waiting, State0),

        % just making sure cycle is being incremented in gossip state
        {next_state, gossiping, State2} = egossip_server:handle_info('$egossip_tick', gossiping, State0#state{max_wait=0}),

        ?assertEqual(0, State1#state.cycle),
        ?assertEqual(1, State2#state.cycle)
    end.

dont_increment_cycle_for_other_modes_(Module) ->
    % should only increment the cycle and change rounds when
    % were in aggregate mode
    fun() ->
        Nodelist = [a,b,c],
        Epoch = 1,

        State0 = #state{mode=epidemic, cycle=0, max_wait=0, module=Module, nodes=Nodelist, epoch=Epoch},

        {next_state, gossiping, State1} = egossip_server:handle_info('$egossip_tick', waiting, State0),

        % just making sure cycle is being incremented in gossip state
        {next_state, gossiping, State2} = egossip_server:handle_info('$egossip_tick', gossiping, State0),

        ?assertEqual(0, State1#state.cycle),
        ?assertEqual(0, State2#state.cycle)
    end.

dont_wait_forever_(Module) ->
    fun() ->
        MaxWait = 2,
        Nodelist = [a,b,c],
        Epoch = 1,

        State0 = #state{cycle=0, max_wait=MaxWait, module=Module, nodes=Nodelist, epoch=Epoch},

        {next_state, waiting, State1} = egossip_server:handle_info('$egossip_tick', waiting, State0),
        {next_state, waiting, State2} = egossip_server:handle_info('$egossip_tick', waiting, State1),
        {next_state, gossiping, _} = egossip_server:handle_info('$egossip_tick', waiting, State2)
    end.
proxies_out_of_band_messages_to_callback_module_(Module) ->
    fun() ->
        State0 = #state{module=Module, mstate=state},

        {next_state, gossiping, _} = egossip_server:handle_info(out_of_band, gossiping, State0),
        ?assert( meck:called( Module, handle_info, [out_of_band, state] ) ),

        {next_state, gossiping, _} = egossip_server:handle_event(out_of_band, gossiping, State0),
        ?assert( meck:called( Module, handle_cast, [out_of_band, state] ) ),

        {reply, ok, gossiping, _} = egossip_server:handle_sync_event(out_of_band, from, gossiping, State0),
        ?assert( meck:called( Module, handle_call, [out_of_band, from, state] ) ),

        ok = egossip_server:terminate(shutdown, gossiping, State0),
        ?assert( meck:called( Module, terminate, [shutdown, state] ) ),

        {ok, State0} = egossip_server:code_change(1, gossiping, State0, []),
        ?assert( meck:called( Module, code_change, [1, state, []]) )
    end.
