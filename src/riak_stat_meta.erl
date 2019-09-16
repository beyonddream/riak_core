%%%-------------------------------------------------------------------
%%% @doc
%%% riak_stat_meta is the middle-man for stats and
%%% riak_core_metadata. All information that needs to go into or out
%%% of the metadata will always go through this module.
%%%
%%% Profile Prefix: {profiles, list}
%%% Loaded Prefix:  {profiles, loaded}
%%% Stats Prefix:   {stats,    nodeid()}
%%%
%%% Profile metadata-pkey: {{profiles, list}, [<<"profile-name">>]}
%%% Profile metadata-val : [{Stat, {status, Status},...]
%%%
%%% Loaded metadata-pkey : {{profiles, loaded}, nodeid()}
%%% Loaded metadata-val  : [<<"profile-name">>]
%%%
%%% Stats metadata-pkey: {{stats, nodeid()}, [riak,riak_kv,...]}
%%% Stats metadata-val : {enabled, spiral, [{resets,...},{vclock,...}], [Aliases]}
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(riak_stat_meta).
-include_lib("riak_core/include/riak_stat.hrl").
-include_lib("riak_core/include/riak_core_metadata.hrl").

%% Registration API
-export([register/1, register/4]).

%% Basic API
-export([
    find_entries/3,
%%    find_entries_/4,
%%    find_entries_2/4,
    dp_get/2,
    get_dps/2]).

%% Updating API
-export([
    change_status/1,
    change_status/2
]).

%% Resetting/Deleting API
-export([
    reset_stat/1,
    reset_resets/0,
    unregister/1]).

%% Profile API
-export([
    save_profile/1,
    load_profile/1,
    delete_profile/1,
    reset_profile/0,
    get_profiles/0,
    get_loaded_profile/0]).

%% Stats are on per node basis
-define(STAT,                  stats).
-define(STATPFX,              {?STAT, ?NODEID}).
-define(STATKEY(StatName),    {?STATPFX, StatName}).
-define(NODEID,                term_to_binary(node())).

%% Profiles are Globally shared
-define(PROF,                  profiles).
-define(PROFID,                list).
-define(PROFPFX,              {?PROF, ?PROFID}).
-define(PROFILEKEY(Profile),  {?PROFPFX, Profile}).
-define(LOADEDPFX,            {?PROF, loaded}).
-define(LOADEDKEY,             ?NODEID).
-define(LOADEDPKEY,           {?LOADEDPFX, ?LOADEDKEY}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%%%===================================================================
%%% Basic API
%%%===================================================================

%%%-------------------------------------------------------------------
%% @doc
%% Get the data from the riak_core_metadata, If not Opts are passed then an empty
%% list is given and the defaults are set in the riak_core_metadata.
%% it's possible to do a select pattern in the options under the form:
%%      {match, ets:match_spec}
%% Which is pulled out in riak_core_metadata and used in an ets:select,
%% @end
%%%-------------------------------------------------------------------
-spec(get(metadata_prefix(), metadata_key()) -> metadata_value() | undefined).
get(Prefix, Key) ->
    get(Prefix, Key, []).
get(Prefix, Key, Opts) ->
    riak_core_metadata:get(Prefix, Key, Opts).

%%%-------------------------------------------------------------------
%% @doc
%% Give a Prefix for anything in the metadata and get a list of all the
%% data stored under that prefix
%% @end
%%%-------------------------------------------------------------------
-spec(get_all(metadata_prefix()) -> metadata_value()).
get_all(Prefix) ->
    riak_core_metadata:to_list(Prefix).

%%%-------------------------------------------------------------------
%% @doc
%% put the data into the metadata, options contain the {match, Match_spec}
%% @end
%%%-------------------------------------------------------------------
-spec(put(metadata_prefix(), metadata_key(),
    metadata_value() | metadata_modifier(), options()) -> ok).
put(Prefix, Key, Value) ->
    put(Prefix, Key, Value, []).
put(Prefix, Key, Value, Opts) ->
    riak_core_metadata:put(Prefix, Key, Value, Opts).

%%%-------------------------------------------------------------------
%% @doc
%% deleting the key from the metadata replaces values with tombstone
%% @end
%%%-------------------------------------------------------------------
-spec(delete(metadata_prefix(), metadata_key()) -> ok).
delete(Prefix, Key) ->
    riak_core_metadata:delete(Prefix, Key).


%%%===================================================================
%%% Main API
%%%===================================================================

%%%-------------------------------------------------------------------
%% @doc
%% Use riak_core_metadata:fold(_) to fold over the path in the metadata
%% and pull out the stats that match the Status and Type given.
%% @end
%%%-------------------------------------------------------------------
-spec(find_entries(statslist(),status(),type()) -> statslist()).
find_entries(Stats,Status,Type) ->
    lists:flatten(lists:map(
        fun(Stat) ->
            fold(Stat,Status,Type)
        end, Stats
    )).


%%%-------------------------------------------------------------------
%% @doc
%% Using riak_core_metadata the statname(s) is passed in a tuple: {match,Name} which will
%% return the objects that match in the metadata in order to fold through in the iterator, this
%% iterates over the ?STATPFX : {stats,term_to_binary(node())}, and fold over the objects returned
%% and depending on the Status, Type or DataPoints (DP) requested, it will be guarded and then returned
%% in the accumulator.
%%
%% Some objects have a tuple 3 or 2 value, and some of the tuple-3 values store the aliases in the
%% Options (O), encompasses any possible Value that may have the aliases stored in a different place.
%%
%% The Aliases are the names of the DPs for those specific stats, if the stat does not have any aliases
%% for the data points requested it will not be returned.
%% @end
%%%-------------------------------------------------------------------
-spec(fold(statname(),(enabled | disabled | '_'),(type() | '_')) -> acc()).
%%%-------------------------------------------------------------------
%% @doc
%% the Status can be anything, it is always guarded for, the type is
%% not required, and there are no datapoints requested. Only return the
%% name of the stat and the status it has in the metadata.
%% @end
%%%-------------------------------------------------------------------
fold(Stat, Status0, Type0) ->
    {Stats, Status0, Type0} =
        riak_core_metadata:fold(fun %%          tuple/4
                                    ({Name, [{MStatus, MType, _O, _A}]}, {Acc, Status, Type})
                                        when (Status == '_' orelse Status == MStatus)
                                        andalso (MType == Type orelse Type == '_')->
                                        {[{Name, MType, MStatus} | Acc], Status, Type};
                                    %%          tuple/3
                                    ({Name, [{MStatus, MType, _O}]}, {Acc, Status, Type})
                                        when (Status == '_' orelse Status == MStatus)
                                        andalso (MType == Type orelse Type == '_')->
                                        {[{Name, MType, MStatus} | Acc], Status, Type};
                                    %%          tuple/2
                                    ({Name, [{MStatus, MType}]}, {Acc, Status, Type})
                                        when (Status == '_' orelse Status == MStatus)
                                        andalso (MType == Type orelse Type == '_')->
                                        {[{Name, MType, MStatus} | Acc], Status, Type};

                                    (_Other, {Acc, Status, Type}) ->
                                        {Acc, Status, Type}
                                end, {[], Status0, Type0}, ?STATPFX, [{match, Stat}]),

Stats.


dp_get(DPs, Aliases) ->
    lists:foldl(fun
                    ({_,[]},Ac) -> Ac;
                    (Valid, Ac) -> [Valid|Ac]
                end,[],[riak_stat_meta:get_dps(DP,Aliases) || DP <- DPs]).

get_dps(DP, Aliases) ->
    case proplists:get_value(DP, Aliases, []) of
        [] -> [];
        V -> {DP,V}
    end.


%%%-------------------------------------------------------------------
%% @doc
%% Checks the metadata for the pkey provided
%% returns [] | Value
%% @end
%%%-------------------------------------------------------------------
-spec(check_meta(metadata_pkey()) -> metadata_value()).
check_meta(Stat) when is_list(Stat) ->
    check_meta(?STATKEY(Stat));
check_meta({Prefix, Key}) ->
    case get(Prefix, Key) of
        undefined -> % Not found, return empty list
            [];
        Value ->
            case find_unregister_status(Key, Value) of
                false        -> Value;
                unregistered -> unregistered;
                _Otherwise   -> Value
            end
    end.

find_unregister_status(_K, '$deleted') ->
    unregistered;
find_unregister_status(_SN, {Status, _T, _Opts, _A}) ->
    Status; % enabled | disabled =/= unregistered
find_unregister_status(_PN, _Stats) ->
    false.


%%%===================================================================


%%%-------------------------------------------------------------------
%% @doc
%% In the case where one list should take precedent, which is most
%% likely the case when registering in both exometer and metadata, the options
%% hardcoded into the stats may change, or the primary kv for stats statuses
%% switches, in every case, there must be an alpha.
%%
%% For this, the lists are compared, and when a difference is found
%% (i.e. the stat tuple is not in the betalist, but is in the alphalist)
%% it means that the alpha stat, with the newest key-value needs to
%% returned in order to change the status of that stat key-value.
%% @end
%%%-------------------------------------------------------------------
-spec(the_alpha_stat(Alpha :: list(), Beta :: list()) -> term()).
the_alpha_stat(Alpha, Beta) ->
    AlphaList = the_alpha_map([Alpha]),
    BetaList  = the_alpha_map(Beta),
    {_LeftOvers, AlphaStatList} =
        lists:foldl(fun
                        (AlphaStat, {BetaAcc, TheAlphaStats}) ->
                            %% is the stat from Alpha in Beta?
                            case lists:member(AlphaStat, BetaAcc) of
                                true ->
                                    %% nothing to be done.
                                    {BetaAcc,TheAlphaStats};
                                false ->
                                    {AKey, _O} = AlphaStat,
                                    {lists:keydelete(AKey,1,BetaAcc),
                                        [AlphaStat|TheAlphaStats]}
                            end
                    end, {BetaList, []}, AlphaList),
    AlphaStatList.
% The stats must fight, to become the alpha


the_alpha_map(A_B) ->
    lists:foldl(fun
                  ({Stat, {Atom, Val}},Acc) -> [{Stat, {Atom, Val}}|Acc];
                  ({Stat, Val},Acc)         -> [{Stat, {atom, Val}}|Acc];
                  (_,Acc) -> Acc
              end,[], A_B).


%%%-------------------------------------------------------------------

find_all_entries() ->
    [{Name, {status, Status}} || {Name,_Type, Status} <- find_entries([[riak|'_']], '_', '_')].

%%%-------------------------------------------------------------------


%%%===================================================================
%%% Registration API
%%%===================================================================

%%%-------------------------------------------------------------------
%% @doc
%% Checks if the stat is already registered in the metadata, if not it
%% registers it, and pulls out the options for the status and sends it
%% back to go into exometer
%% @end
%%%-------------------------------------------------------------------
-spec(register(statinfo()) -> options() | []).
register({StatName, Type, Opts, Aliases}) ->
    register(StatName, Type, Opts, Aliases).
register(StatName,Type, Opts, Aliases) ->
    case check_meta(?STATKEY(StatName)) of
        [] ->
            {Status, MOpts} = find_status(fresh, Opts),
            re_register(StatName,{Status,Type,MOpts,Aliases}),
            MOpts;
        unregistered ->
            [];
        {MStatus,Type,MOpts,Aliases} -> %% is registered
            {Status,NewMOpts,NewOpts} = find_status(re_reg,{Opts,MStatus,MOpts}),
            re_register(StatName, {Status,Type, NewMOpts,Aliases}),
            NewOpts;
        _ -> lager:debug(
            "riak_stat_meta:register(StatInfo) ->
            Could not register stat:~n{~p,[{~p,~p,~p,~p}]}~n",
            [StatName,undefined,Type,Opts,Aliases]),[]
    end.

find_status(fresh, Opts) ->
    case proplists:get_value(status,Opts) of
        undefined -> {enabled, Opts};
        Status    -> {Status,  Opts}
    end;
find_status(re_reg, {Opts, MStatus, MOpts}) ->
    case proplists:get_value(status, Opts) of
        undefined ->
            {MStatus, the_alpha_stat(MOpts, Opts),
                [{status,MStatus}|Opts]};
        _Status ->
            {MStatus, the_alpha_stat(MOpts, Opts),
                lists:keyreplace(status,1,Opts,{status,MStatus})}
    end.

re_register(StatName, Value) -> %% ok
    put(?STATPFX, StatName, Value).


%%%===================================================================
%%% Updating API
%%%===================================================================

%%%-------------------------------------------------------------------
%% @doc
%% Changes the status of stats in the metadata
%% @end
%%%-------------------------------------------------------------------
-spec(change_status(metadata_key(), status()) -> ok | acc()).
change_status(Stats) when is_list(Stats) ->
    lists:foldl(fun
                    ({Stat, {status, Status}}, Acc) ->
                        [change_status(Stat, Status) | Acc];
                    ({Stat, Status}, Acc) ->
                        [change_status(Stat, Status) | Acc]
                end, [], Stats);
change_status({StatName, Status}) ->
    change_status(StatName, Status).
change_status(Statname, ToStatus) ->
    case check_meta(?STATKEY(Statname)) of
        [] ->
            [];
        unregistered ->
            [];
        {_Status, Type, Opts, Aliases} ->
            put(?STATPFX, Statname, {ToStatus, Type, Opts, Aliases})
    end.

%%%-------------------------------------------------------------------
%% @doc
%% Setting the options in the metadata manually, such as
%% resets etc...
%% @end
%%%-------------------------------------------------------------------
-spec(set_options(metadata_key(), options()) -> ok).
set_options(StatInfo, NewOpts) when is_list(NewOpts) ->
    lists:foreach(fun({Key, NewVal}) ->
        set_options(StatInfo, {Key, NewVal})
                  end, NewOpts);
set_options({Statname, {Status, Type, Opts, Aliases}}, {Key, NewVal}) ->
    NewOpts = lists:keyreplace(Key, 1, Opts, {Key, NewVal}),
    NewOpts2 = fresh_clock(NewOpts),
    set_options(Statname, {Status, Type, NewOpts2, Aliases});
set_options(StatName, {Status, Type, NewOpts, Aliases}) ->
    re_register(StatName, {Status, Type, NewOpts, Aliases}).

fresh_clock(Opts) ->
    case lists:keysearch(vclock, 1, Opts) of
        false ->
            [{vclock, clock_fresh(?NODEID, 0)} | Opts];
        {value, {vclock, [{Node, {Count, _VC}}]}} ->
            lists:keyreplace(vclock, 1, Opts, {vclock, clock_fresh(Node, Count)});
        _ ->
            [{vclock, clock_fresh(?NODEID, 0)} | Opts]
    end.

clock_fresh(Node, Count) ->
    vclock:fresh(Node, vc_inc(Count)).
vc_inc(Count) -> Count + 1.


%%%==================================================================
%%% Deleting/Resetting Stats API
%%%===================================================================


%%%-------------------------------------------------------------------
%% @doc
%% reset the stat in exometer and notify metadata of its reset
%% @end
%%%-------------------------------------------------------------------
-spec(reset_stat(metadata_key()) -> ok | error()).
reset_stat(Statname) ->
    case check_meta(?STATKEY(Statname)) of
        [] -> ok;
        unregistered -> {error, unregistered};
        {_Status, Type, Opts, Aliases} ->
            Resets= proplists:get_value(resets, Opts),
            Options = [{resets, reset_inc(Resets)}],
            set_options({Statname, {enabled, Type, Opts, Aliases}}, Options)
    end.

reset_inc(Count) -> Count + 1.

%%%-------------------------------------------------------------------
%% @doc
%% sometimes the reset count just gets too high, and for every single
%% stat its a bit much
%% @end
%%%-------------------------------------------------------------------
-spec(reset_resets() -> ok).
reset_resets() ->
    lists:foreach(fun({Stat, _Val}) ->
        {Status, Type, Opts, Aliases} = check_meta(?STATKEY(Stat)),
        set_options({Stat, {Status, Type, Opts, Aliases}}, {resets, 0})
                  end, get_all(?STATPFX)).

%%%-------------------------------------------------------------------


%%%-------------------------------------------------------------------
%% @doc
%% Marks the stats as unregistered, that way when a node is restarted and registers the
%% stats it will ignore stats that are marked unregistered
%% @end
%%%-------------------------------------------------------------------
-spec(unregister(metadata_key()) -> ok).
unregister(Statname) ->
    case check_meta(?STATKEY(Statname)) of
        {_Status, Type, MetaOpts, Aliases} ->
            re_register(Statname, {unregistered, Type, MetaOpts, Aliases});
        _ -> ok
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%% Profile API %%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%-------------------------------------------------------------------
%% @doc
%% Take the stats and their status out of the metadata for the current
%% node and save it into the metadata as a profile - works on per node
%% @end
%%%-------------------------------------------------------------------
-spec(save_profile(profilename()) -> ok | error()).
save_profile(ProfileName) ->
    put(?PROFPFX, ProfileName, find_all_entries()),
    io:fwrite("Profile: ~s Saved~n", [ProfileName]).

%%%-------------------------------------------------------------------
%% @doc
%% Find the profile in the metadata and pull out stats to change them.
%% It will compare the current stats with the profile stats and will
%% change the ones that need changing to prevent errors/less expense
%% @end
%%%-------------------------------------------------------------------
-spec(load_profile(profilename()) -> ok | error()).
load_profile(ProfileName) ->
    case check_meta(?PROFILEKEY(ProfileName)) of
        {error, Reason} ->
            io:format("Error : ~p~n",[Reason]);
        [] ->
            io:format("Error: Profile does not Exist~n");
        ProfileStats ->
            CurrentStats = find_all_entries(),
            ToChange = the_alpha_stat(ProfileStats, CurrentStats),
            %% delete stats that are already enabled/disabled, any duplicates
            %% with different statuses will be replaced with the profile one
            change_stat_list_to_status(ToChange), %% todo: use the metadata fold to change the stats
            put(?LOADEDPFX, ?LOADEDKEY, ProfileName),
            io:format("Loaded Profile: ~s~n",[ProfileName])
    end.

change_stat_list_to_status(StatusList) -> %% todo: change the name of this function to some generic
    riak_stat_mgr:change_status(StatusList).


%%%-------------------------------------------------------------------
%% @doc
%% Deletes the profile from the metadata, however currently the metadata
%% returns a tombstone for the profile, it can be overwritten when a new profile
%% is made of the same name, and in the profile gen_server the name of the
%% profile is "unregistered" so it can not be reloaded again after deletion
%% @end
%%%-------------------------------------------------------------------
-spec(delete_profile(profilename()) -> ok).
delete_profile(ProfileName) ->
    case check_meta(?LOADEDPKEY) of
        ProfileName -> %% make this a guard instead of a pattern match
            put(?LOADEDPFX, ?LOADEDKEY, [<<"none">>]),
            delete(?PROFPFX, ProfileName);
        _ ->
            delete(?PROFPFX, ProfileName)
    end,
    io:format("Profile Deleted : ~s~n",[ProfileName]).


%%%-------------------------------------------------------------------
%% @doc
%% resets the profile by enabling all the stats, pulling out all the stats that
%% are disabled in the metadata and then changing them to enabled in both the
%% metadata and exometer
%% @end
%%%-------------------------------------------------------------------
-spec(reset_profile() -> ok | error()).
reset_profile() ->
    CurrentStats = find_all_entries(),
        put(?LOADEDPFX, ?LOADEDKEY, [<<"none">>]),
    change_stats_from(CurrentStats, disabled),
    io:format("All Stats set to 'enabled'~n").
% change from disabled to enabled


change_stats_from(Stats, Status) ->
    change_stat_list_to_status( %% todo: make this using metadata fold
        lists:foldl(fun
                        ({Stat, {status, St}}, Acc) when St == Status ->
                            NewSt =
                                case Status of
                                    enabled -> disabled;
                                    disabled -> enabled
                                end,
                            [{Stat, {status, NewSt}} | Acc];
                        ({_Stat, {status, St}}, Acc) when St =/= Status ->
                            Acc
                    end, [], Stats)).


%%%-------------------------------------------------------------------
%% @doc
%% returns a list of the profile names stored in the metadata
%% @end
%%%-------------------------------------------------------------------
-spec(get_profiles() -> metadata_value()).
get_profiles() ->
    get_all(?PROFPFX).

%%%-------------------------------------------------------------------
%% @doc
%% get the profile that is loaded in the metadata
%% @end
%%%-------------------------------------------------------------------
-spec(get_loaded_profile() -> profilename()).
get_loaded_profile() ->
    get(?LOADEDPFX, ?LOADEDKEY).

-ifdef(TEST).

-endif.
