%%--------------------------------------------------------------------
%% Copyright (c) 2019-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(mria_membership_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("mria.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

all() -> mria_ct:all(?MODULE).

init_per_suite(Config) ->
    mria_ct:start_dist(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    ok = meck:new(mria_mnesia, [non_strict, passthrough, no_history]),
    ok = meck:expect(mria_mnesia, cluster_status, fun(_) -> running end),
    {ok, _} = mria_membership:start_link(),
    ok = init_membership(3),
    Config.

end_per_testcase(_TestCase, Config) ->
    snabbkaffe:stop(),
    ok = mria_membership:stop(),
    ok = meck:unload(mria_mnesia),
    Config.

t_lookup_member(_) ->
    false = mria_membership:lookup_member('node@127.0.0.1'),
    #member{node = 'n1@127.0.0.1', status = up}
        = mria_membership:lookup_member('n1@127.0.0.1').

t_coordinator(_) ->
    ?assertEqual(node(), mria_membership:coordinator()),
    Nodes = ['n1@127.0.0.1', 'n2@127.0.0.1', 'n3@127.0.0.1'],
    ?assertEqual('n1@127.0.0.1', mria_membership:coordinator(Nodes)).

t_node_down_up(_) ->
    ok = meck:expect(mria_mnesia, is_node_in_cluster, fun(_) -> true end),
    ok = mria_membership:node_down('n2@127.0.0.1'),
    ok = timer:sleep(100),
    #member{status = down} = mria_membership:lookup_member('n2@127.0.0.1'),
    ok = mria_membership:node_up('n2@127.0.0.1'),
    ok = timer:sleep(100),
    #member{status = up} = mria_membership:lookup_member('n2@127.0.0.1').

t_mnesia_down_up(_) ->
    ok = mria_membership:mnesia_down('n2@127.0.0.1'),
    ok = timer:sleep(100),
    #member{mnesia = stopped} = mria_membership:lookup_member('n2@127.0.0.1'),
    ok = mria_membership:mnesia_up('n2@127.0.0.1'),
    ok = timer:sleep(100),
    #member{status = up, mnesia = running} = mria_membership:lookup_member('n2@127.0.0.1').

t_partition_occurred(_) ->
    ok = mria_membership:partition_occurred('n2@127.0.0.1').

t_partition_healed(_) ->
    ok = mria_membership:partition_healed(['n2@127.0.0.1']).

t_announce(_) ->
    ok = mria_membership:announce(leave).

t_leader(_) ->
    ?assertEqual(node(), mria_membership:leader()).

t_is_all_alive(_) ->
    ?assert(mria_membership:is_all_alive()).

t_members(_) ->
    ?assertEqual(4, length(mria_membership:members())).

t_nodelist(_) ->
    Nodes = lists:sort([node(),
                        'n1@127.0.0.1',
                        'n2@127.0.0.1',
                        'n3@127.0.0.1'
                       ]),
    ?assertEqual(Nodes, lists:sort(mria_membership:nodelist())).

t_is_member(_) ->
    ?assert(mria_membership:is_member('n1@127.0.0.1')),
    ?assert(mria_membership:is_member('n2@127.0.0.1')),
    ?assert(mria_membership:is_member('n3@127.0.0.1')).

t_local_member(_) ->
    #member{node = Node} = mria_membership:local_member(),
    ?assertEqual(node(), Node).

t_leave(_) ->
    Cluster = mria_ct:cluster([core, core, core], []),
    try
        [N0, N1, N2] = mria_ct:start_cluster(mria, Cluster),
        ?assertMatch([N0, N1, N2], rpc:call(N0, mria, info, [running_nodes])),
        ok = rpc:call(N1, mria, leave, []),
        ok = rpc:call(N2, mria, leave, []),
        ?assertMatch([N0], rpc:call(N0, mria, info, [running_nodes]))
    after
        mria_ct:teardown_cluster(Cluster)
    end.

t_force_leave(_) ->
    Cluster = mria_ct:cluster([core, core, core], []),
    try
        [N0, N1, N2] = mria_ct:start_cluster(mria, Cluster),
        ?assertMatch(true, rpc:call(N0, mria_node, is_running, [N1])),
        true = rpc:call(N0, mria_node, is_running, [N2]),
        ?assertMatch([N0, N1, N2], rpc:call(N0, mria, info, [running_nodes])),
        ?assertMatch(ok, rpc:call(N0, mria, force_leave, [N1])),
        ?assertMatch(ok, rpc:call(N0, mria, force_leave, [N2])),
        ?assertMatch([N0], rpc:call(N0, mria, info, [running_nodes]))
    after
        mria_ct:teardown_cluster(Cluster)
    end.

t_ping_from_cores(_) ->
    test_core_ping_pong(ping).

t_ping_from_replicants(_) ->
    test_replicant_ping_pong(ping).

t_pong_from_cores(_) ->
    test_core_ping_pong(pong).

t_pong_from_replicants(_) ->
    test_replicant_ping_pong(pong).

%% replicants do not insert themselves into the membership table, and
%% they insert cores during loadbalancer initialization.
t_replicant_init(_) ->
    Cluster = mria_ct:cluster([core, core, replicant, replicant],
                              mria_mnesia_test_util:common_env()),
    ?check_trace(
       try
           Nodes = [N0, N1, _N2, _N3] = mria_ct:start_cluster(mria, Cluster),
           ok = mria_mnesia_test_util:wait_tables(Nodes),
           Cores = [N0, N1],
           [begin
                ?assertMatch([_, _], erpc:call(N, mria_membership, members, []),
                             #{node => N}),
                [?assert(erpc:call(N, mria_membership, is_member, [M]),
                         #{node => N, other => M})
                 || M <- Cores],
                Leader = erpc:call(N, mria_membership, leader, []),
                Coordinator = erpc:call(N, mria_membership, coordinator, []),
                ?assert(lists:member(Leader, Cores), #{node => N}),
                ?assert(lists:member(Coordinator, Cores), #{node => N}),
                ok
            end
            || N <- Nodes],
           ok
       after
           mria_ct:teardown_cluster(Cluster)
       end,
       [fun ?MODULE:assert_no_replicants_inserted/1]).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

init_membership(N) ->
    lists:foreach(
      fun(Member) ->
              ok = mria_membership:pong(node(), Member)
      end, lists:map(fun member/1, lists:seq(1, N))),
    mria_membership:announce(join).

member(I) ->
    Node = list_to_atom("n" ++ integer_to_list(I) ++ "@127.0.0.1"),
    #member{node   = Node,
            addr   = {{127,0,0,1}, 5000 + I},
            guid   = mria_guid:gen(),
            hash   = 1000 * I,
            status = up,
            mnesia = running,
            ltime  = erlang:timestamp()
           }.

test_core_ping_pong(PingOrPong) ->
    Cluster = mria_ct:cluster([core, core, replicant, replicant],
                              mria_mnesia_test_util:common_env()),
    ?check_trace(
       try
           Nodes = [N0, N1, _N2, _N3] = mria_ct:start_cluster(mria, Cluster),
           ok = mria_mnesia_test_util:wait_tables(Nodes),
           Cores = [N0, N1],
           ?tp(done_waiting_for_tables, #{}),
           [begin
                %% Cores do have themselves as local members.
                LocalMember = erpc:call(N, mria_membership, local_member, []),
                lists:foreach(
                  fun(M) ->
                          ?wait_async_action(
                             mria_membership:PingOrPong(M, LocalMember),
                             #{ ?snk_kind := mria_membership_pong
                              , member := #member{node = N}
                              }, 1000)
                  end, Nodes),
                assert_expected_memberships(N, Cores),
                ok
            end
            || N <- Cores],
           ok
       after
           mria_ct:teardown_cluster(Cluster)
       end,
       [ fun ?MODULE:assert_no_replicants_inserted/1
       , {"cores always get inserted",
          fun(Trace0) ->
                  {_, Trace} = ?split_trace_at(#{?snk_kind := done_waiting_for_tables}, Trace0),
                  assert_cores_always_get_inserted(Trace)
          end}
       ]).

test_replicant_ping_pong(PingOrPong) ->
    Cluster = mria_ct:cluster([core, core, replicant, replicant],
                              mria_mnesia_test_util:common_env()),
    ?check_trace(
       try
           Nodes = [N0, N1, N2, N3] = mria_ct:start_cluster(mria, Cluster),
           ok = mria_mnesia_test_util:wait_tables(Nodes),
           Cores = [N0, N1],
           Replicants = [N2, N3],
           ?tp(done_waiting_for_tables, #{}),
           [begin
                %% Replicants do not have themselves as local members.
                %% We make an entry on the fly.
                LocalMember = erpc:call(N, mria_membership, make_new_local_member, []),
                lists:foreach(
                  fun(M) ->
                          ?wait_async_action(
                             mria_membership:PingOrPong(M, LocalMember),
                             #{ ?snk_kind := mria_membership_pong
                              , member := #member{node = N}
                              }, 1000)
                  end, Nodes),
                assert_expected_memberships(N, Cores),
                ok
            end
            || N <- Replicants],
           ok
       after
           mria_ct:teardown_cluster(Cluster)
       end,
       [ fun ?MODULE:assert_no_replicants_inserted/1
       , {"cores get inserted on ping",
          fun(Trace0) ->
                  case PingOrPong of
                      ping ->
                          {_, Trace} = ?split_trace_at(#{?snk_kind := done_waiting_for_tables}, Trace0),
                          assert_cores_always_get_inserted(Trace);
                      pong ->
                          %% pongs from replicants do not result in
                          %% cores being inserted.
                          ok
                  end
          end}
       ]).

assert_expected_memberships(Node, Cores) ->
    Members = erpc:call(Node, mria_membership, members, []),
    ReplicantMembers = [Member || Member = #member{role = replicant} <- Members],
    {PresentCores, UnknownCores} =
        lists:partition(
          fun(N) ->
                  lists:member(N, Cores)
          end,
          [N || #member{role = core, node = N} <- Members]),
    ?assertEqual([], ReplicantMembers, #{node => Node}),
    ?assertEqual([], UnknownCores, #{node => Node}),
    %% cores get inserted into replicants' tables either by the pings
    %% sent from cores, or by the core discovery procedure.
    ?assertEqual(lists:usort(Cores), lists:usort(PresentCores), #{node => Node}),
    ok.

assert_no_replicants_inserted(Trace) ->
    ?assertEqual([], [Event || Event = #{ ?snk_kind := mria_membership_insert
                                        , member := #member{role = replicant}
                                        } <- Trace]).

assert_cores_always_get_inserted(Trace) ->
    ?assert(
      ?strict_causality(
         #{ ?snk_kind := EventType
          , ?snk_meta := #{node := _Node}
          , member := #member{role = core, node = _MemberNode,
                              status = up, mnesia = running}
          } when EventType =:= mria_membership_ping;
                 EventType =:= mria_membership_pong
        , #{ ?snk_kind := mria_membership_insert
           , ?snk_meta := #{node := _Node}
           , member := #member{role = core, node = _MemberNode,
                               status = up, mnesia = running}
           }
        , Trace
        )).
