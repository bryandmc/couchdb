% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_upr_fake_server).
-behaviour(gen_server).

% Public API
-export([start/1, reset/0]).

% Only uses by tests
-export([set_failover_log/2]).

% Needed for internal process spawning
-export([accept/1, accept_loop/1]).

% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2,
    code_change/3]).

-include_lib("couch_upr/include/couch_upr.hrl").


-define(dbname(SetName, PartId),
    <<SetName/binary, $/, (list_to_binary(integer_to_list(PartId)))/binary>>).


% #doc_info{}, #doc{}, #db{} are from couch_db.hrl. They are copy & pasted here
% as they will go away once the proper UPR is in place.
-record(doc_info,
    {
    id = <<"">>,
    deleted = false,
    local_seq,
    rev = {0, <<>>},
    body_ptr,
    content_meta = 0, % should be 0-255 only.
    size = 0
    }).
-record(doc,
    {
    id = <<>>,
    rev = {0, <<>>},

    % the binary body
    body = <<"{}">>,
    content_meta = 0, % should be 0-255 only.

    deleted = false,

    % key/value tuple of meta information, provided when using special options:
    % couch_db:open_doc(Db, Id, Options).
    meta = [],
    seq = 0,
    partition = 0
    }).
-record(db,
    {main_pid = nil,
    update_pid = nil,
    compactor_info = nil,
    instance_start_time, % number of microsecs since jan 1 1970 as a binary string
    fd,
    fd_ref_counter,
    header,% = #db_header{},
    committed_update_seq,
    docinfo_by_id_btree,
    docinfo_by_seq_btree,
    local_docs_btree,
    update_seq,
    name,
    filepath,
    security = [],
    security_ptr = nil,
    user_ctx,% = #user_ctx{},
    waiting_delayed_commit = nil,
    fsync_options = [],
    options = []
    }).


-record(state, {
    streams = [], %:: [{partition_id(), {request_id(), sequence_number()}}]
    setname = nil,
    failover_logs = dict:new()
}).


% Public API

-spec start(binary()) -> {ok, pid()} | ignore |
                         {error, {already_started, pid()} | term()}.
start(SetName) ->
    % Start the fake UPR server where the original one is expected to be
    Port = list_to_integer(couch_config:get("upr", "port", "0")),
    gen_server:start({local, ?MODULE}, ?MODULE, [Port, SetName], []).

-spec reset() -> ok.
reset() ->
    gen_server:call(?MODULE, reset).

% Only used by tests to populate the failover log
-spec set_failover_log(partition_id(), partition_version()) -> ok.
set_failover_log(PartId, FailoverLog) ->
    gen_server:call(?MODULE, {set_failover_log, PartId, FailoverLog}).


% gen_server callbacks

-spec init([port() | binary()]) -> {ok, #state{}}.
init([Port, SetName]) ->
    {ok, Listen} = gen_tcp:listen(Port,
        [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    case Port of
    % In case the port was set to "0", the OS will decide which port to run
    % the fake UPR server on. Update the configuration so that we know which
    % port was chosen (that's only needed for the tests).
    0 ->
        {ok, RandomPort} = inet:port(Listen),
        couch_config:set("upr", "port", integer_to_list(RandomPort), false);
    _ ->
        ok
    end,
    accept(Listen),
    {ok, #state{
        streams = [],
        setname = SetName
    }}.


-spec handle_call(tuple() | atom(), {pid(), reference()}, #state{}) ->
                         {reply, any(), #state{}}.
handle_call({send_snapshot, Socket, PartId, EndSeq}, _From, State) ->
    #state{
        streams = Streams,
        setname = SetName
    } = State,
    {RequestId, Seq} = proplists:get_value(PartId, Streams),
    Num = do_send_snapshot(Socket, SetName, PartId, RequestId, Seq, EndSeq),
    State2 = case Num of
    0 ->
        State;
    _ ->
        Streams2 = lists:keyreplace(
            PartId, 1, Streams, {PartId, {RequestId, Seq+Num}}),
        State#state{streams = Streams2}
    end,
    {reply, ok, State2};

handle_call({add_stream, PartId, RequestId, StartSeq}, _From, State) ->
    {reply, ok, State#state{
        streams = [{PartId, {RequestId, StartSeq}}|State#state.streams]
    }};

handle_call({set_failover_log, PartId, FailoverLog}, _From, State) ->
    FailoverLogs = dict:store(PartId, FailoverLog, State#state.failover_logs),
    {reply, ok, State#state{
        failover_logs = FailoverLogs
    }};

handle_call({get_sequence_number, PartId}, _From, State) ->
    case open_db(State#state.setname, PartId) of
    {ok, Db} ->
        Seq = Db#db.update_seq,
        couch_db:close(Db),
        {reply, {ok, Seq}, State};
    {error, cannot_open_db} ->
        {reply, {error, not_my_partition}, State}
    end;


handle_call({get_failover_log, PartId}, _From, State) ->
    case dict:find(PartId, State#state.failover_logs) of
    {ok, FailoverLog} ->
        ok;
    error ->
        FailoverLog = [{0, 0}]
    end,
    {reply, FailoverLog, State};

handle_call(reset, _From, State0) ->
    State = #state{
        setname = State0#state.setname
    },
    {reply, ok, State}.


-spec handle_cast(any(), #state{}) ->
                         {stop, {unexpected_cast, any()}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.


-spec handle_info({'EXIT', {pid(), reference()}, normal}, #state{}) ->
                         {noreply, #state{}}.
handle_info({'EXIT', _From, normal}, State)  ->
    {noreply, State}.


-spec terminate(any(), #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(any(), #state{}, any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


% Internal functions

-spec get_failover_log(partition_id()) -> partition_version().
get_failover_log(PartId) ->
    gen_server:call(?MODULE, {get_failover_log, PartId}).


% Returns the current high sequence number of a partition
-spec get_sequence_number(partition_id()) -> {ok, update_seq()} |
                                             {error, not_my_partition}.
get_sequence_number(PartId) ->
    gen_server:call(?MODULE, {get_sequence_number, PartId}).


-spec accept(socket()) -> pid().
accept(Listen) ->
    process_flag(trap_exit, true),
    spawn_link(?MODULE, accept_loop, [Listen]).

-spec accept_loop(socket()) -> ok.
accept_loop(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    % Let the server spawn a new process and replace this loop
    % with the read loop, to avoid blocking
    accept(Listen),
    read(Socket).


-spec read(socket()) -> ok.
read(Socket) ->
    case gen_tcp:recv(Socket, ?UPR_HEADER_LEN) of
    {ok, Header} ->
        case couch_upr_producer:parse_header(Header) of
        {open_connection, BodyLength, RequestId} ->
            handle_open_connection_body(Socket, BodyLength, RequestId);
        {stream_request, BodyLength, RequestId, PartId} ->
            handle_stream_request_body(Socket, BodyLength, RequestId, PartId);
        {failover_log, RequestId, PartId} ->
            handle_failover_log(Socket, RequestId, PartId);
        {stats, BodyLength, RequestId} ->
            handle_stats_body(Socket, BodyLength, RequestId);
        {sasl_auth, BodyLength, RequestId} ->
            handle_sasl_auth_body(Socket, BodyLength, RequestId)
        end,
        read(Socket);
    {error, closed} ->
        ok
    end.


% XXX vmx: 2014-01-24: Proper logging/error handling is missing
-spec handle_open_connection_body(socket(), size(), request_id()) ->
                                         ok | {error, closed}.
handle_open_connection_body(Socket, BodyLength, RequestId) ->
    case gen_tcp:recv(Socket, BodyLength) of
    {ok, <<_SeqNo:?UPR_SIZES_SEQNO,
           ?UPR_FLAG_PRODUCER:?UPR_SIZES_FLAGS,
           _Name/binary>>} ->
        OpenConnection = couch_upr_producer:encode_open_connection(RequestId),
        ok = gen_tcp:send(Socket, OpenConnection);
    {error, closed} ->
        {error, closed}
    end.

-spec handle_stream_request_body(socket(), size(), request_id(),
                                 partition_id()) -> ok | {error, closed}.
handle_stream_request_body(Socket, BodyLength, RequestId, PartId) ->
    case gen_tcp:recv(Socket, BodyLength) of
    {ok, <<_Flags:?UPR_SIZES_FLAGS,
           _Reserved:?UPR_SIZES_RESERVED,
           StartSeq:?UPR_SIZES_BY_SEQ,
           EndSeq:?UPR_SIZES_BY_SEQ,
           PartUuid:?UPR_SIZES_PARTITION_UUID/integer,
           PartHighSeq:?UPR_SIZES_BY_SEQ>>} ->
        FailoverLog = get_failover_log(PartId),
        case StartSeq > EndSeq of
        true ->
            send_error(Socket, RequestId, ?UPR_STATUS_ERANGE);
        false ->
            case lists:member({PartUuid, PartHighSeq}, FailoverLog) orelse
                 StartSeq =:= 0 of
            true ->
                send_ok_or_error(
                    Socket, RequestId, PartId, StartSeq, EndSeq, PartUuid,
                    PartHighSeq, FailoverLog);
            false ->
                send_error(Socket, RequestId, ?UPR_STATUS_KEY_NOT_FOUND)
            end
        end;
    {error, closed} ->
        {error, closed}
    end.

-spec send_ok_or_error(socket(), request_id(), partition_id(), update_seq(),
                       update_seq(), uuid(), update_seq(),
                       partition_version()) -> ok.
send_ok_or_error(Socket, RequestId, PartId, StartSeq, EndSeq,
        PartVersionUuid, PartVersionSeq, FailoverLog) ->
    {ok, HighSeq} = get_sequence_number(PartId),

    case StartSeq =:= 0 of
    true ->
        send_ok(Socket, RequestId, PartId, StartSeq, EndSeq, FailoverLog);
    false ->
        % The server might already have a different future than the client
        % has (the client and the server have a common history, but the server
        % is ahead with new failover log entries). We need to make sure the
        % requested `StartSeq` is lower than the sequence number of the
        % failover log entry that comes next (if there is any).
        DiffFailoverLog = lists:takewhile(fun({LogPartUuid, _}) ->
            LogPartUuid =/= PartVersionUuid
        end, FailoverLog),

        case DiffFailoverLog of
        % Same history
        [] ->
            case StartSeq =< HighSeq of
            true ->
                send_ok(
                    Socket, RequestId, PartId, StartSeq, EndSeq, FailoverLog);
            false ->
                % The client tries to get items from the future, which
                % means that it got ahead of the server somehow.
                send_error(Socket, RequestId, ?UPR_STATUS_ERANGE)
            end;
        _ ->
            {_, NextHighSeqNum} = lists:last(DiffFailoverLog),
            case StartSeq < NextHighSeqNum of
            true ->
                send_ok(
                    Socket, RequestId, PartId, StartSeq, EndSeq, FailoverLog);
            false ->
                send_rollback(Socket, RequestId, PartVersionSeq)
            end
        end
    end.

-spec send_ok(socket(), request_id(), partition_id(), update_seq(),
              update_seq(), partition_version()) -> ok.
send_ok(Socket, RequestId, PartId, StartSeq, EndSeq, FailoverLog) ->
    StreamOk = couch_upr_producer:encode_stream_request_ok(
        RequestId, FailoverLog),
    ok = gen_tcp:send(Socket, StreamOk),
    ok = gen_server:call(?MODULE, {add_stream, PartId, RequestId, StartSeq}),
    ok = gen_server:call(?MODULE, {send_snapshot, Socket, PartId, EndSeq}),
    StreamEnd = couch_upr_producer:encode_stream_end(PartId, RequestId),
    ok = gen_tcp:send(Socket, StreamEnd).

-spec send_rollback(socket(), request_id(), update_seq()) -> ok.
send_rollback(Socket, RequestId, RollbackSeq) ->
    StreamRollback = couch_upr_producer:encode_stream_request_rollback(
        RequestId, RollbackSeq),
    ok = gen_tcp:send(Socket, StreamRollback).

-spec send_error(socket(), request_id(), upr_status()) -> ok.
send_error(Socket, RequestId, Status) ->
    StreamError = couch_upr_producer:encode_stream_request_error(
        RequestId, Status),
    ok = gen_tcp:send(Socket, StreamError).


-spec handle_failover_log(socket(), request_id(), partition_id()) -> ok.
handle_failover_log(Socket, RequestId, PartId) ->
    FailoverLog = get_failover_log(PartId),
    FailoverLogResponse = couch_upr_producer:encode_failover_log(
        RequestId, FailoverLog),
    ok = gen_tcp:send(Socket, FailoverLogResponse).


-spec handle_stats_body(socket(), size(), request_id()) ->
                               ok | not_yet_implemented |
                               {error, closed | not_my_partition}.
handle_stats_body(Socket, BodyLength, RequestId) ->
    case gen_tcp:recv(Socket, BodyLength) of
    {ok, Stat} ->
        case binary:split(Stat, <<" ">>) of
        [<<"vbucket-seqno">>] ->
                % XXX vmx 2013-12-09: Return all seq numbers
                not_yet_implemented;
        [<<"vbucket-seqno">>, PartId0] ->
            PartId = list_to_integer(binary_to_list(PartId0)),
            case get_sequence_number(PartId) of
            {ok, Seq} ->
                SeqKey = <<"vb_", PartId0/binary ,"_high_seqno">>,
                SeqValue = list_to_binary(integer_to_list(Seq)),
                SeqStat = couch_upr_producer:encode_stat(
                    RequestId, SeqKey, SeqValue),
                ok = gen_tcp:send(Socket, SeqStat),

                UuidKey = <<"vb_", PartId0/binary ,"_vb_uuid">>,
                FailoverLog = get_failover_log(PartId),
                {UuidValue, _} = hd(FailoverLog),
                UuidStat = couch_upr_producer:encode_stat(
                    RequestId, UuidKey, <<UuidValue:64/integer>>),
                ok = gen_tcp:send(Socket, UuidStat),

                EndStat = couch_upr_producer:encode_stat(RequestId, <<>>, <<>>),
                ok = gen_tcp:send(Socket, EndStat);
            {error, not_my_partition} ->
                % The real response contains the vBucket map so that
                % clients can adapt. It's not easy to simulate, hence
                % we return an empty JSON object to keep things simple.
                StatError = couch_upr_producer:encode_stat_error(
                    RequestId, ?UPR_STATUS_NOT_MY_VBUCKET,
                    <<"{}">>),
                ok = gen_tcp:send(Socket, StatError)
            end
        end;
    {error, closed} ->
        {error, closed}
    end.


% XXX vmx: 2014-01-24: Proper logging/error handling is missing
-spec handle_sasl_auth_body(socket(), size(), request_id()) ->
                                   ok | {error, closed}.
handle_sasl_auth_body(Socket, BodyLength, RequestId) ->
    case gen_tcp:recv(Socket, BodyLength) of
    % NOTE vmx 2014-01-10: Currently there's no real authentication
    % implemented in the fake server. Just always send back the authentication
    % was successful
    {ok, _} ->
        Authenticated = couch_upr_producer:encode_sasl_auth(RequestId),
        ok = gen_tcp:send(Socket, Authenticated);
    {error, closed} ->
        {error, closed}
    end.


% This function creates mutations for one snapshot of one partition of a
% given size
-spec create_mutations(binary(), partition_id(), update_seq(), update_seq()) ->
                              [#doc{}].
create_mutations(SetName, PartId, StartSeq, EndSeq) ->
    {ok, Db} = open_db(SetName, PartId),
    DocsFun = fun(DocInfo, Acc) ->
        #doc_info{
            id = DocId,
            deleted = Deleted,
            local_seq = Seq,
            rev = Rev
        } = DocInfo,
        Value = case Deleted of
        true ->
           deleted;
        false ->
            {ok, CouchDoc} = couch_db:open_doc_int(Db, DocInfo, []),
            iolist_to_binary(CouchDoc#doc.body)
        end,
        {RevSeq, Cas, Expiration, Flags} = extract_revision(Rev),
        {ok, [{Cas, Seq, RevSeq, Flags, Expiration, 0, DocId, Value}|Acc]}
    end,
    {ok, _NumDocs, Docs} = couch_db:fast_reads(Db, fun() ->
        couch_db:enum_docs_since(Db, StartSeq, DocsFun, [],
                                 [{end_key, EndSeq}])
    end),
    couch_db:close(Db),
    lists:reverse(Docs).


% Extract the CAS and flags out of thr revision
% The couchdb unit tests don't fill in a proper revision, but an empty binary
-spec extract_revision({non_neg_integer(), <<_:128>>}) ->
                              {non_neg_integer(), non_neg_integer(),
                               non_neg_integer(), non_neg_integer()}.
extract_revision({RevSeq, <<>>}) ->
    {RevSeq, 0, 0, 0};
% https://github.com/couchbase/ep-engine/blob/master/src/couch-kvstore/couch-kvstore.cc#L212-L216
extract_revision({RevSeq, RevMeta}) ->
    <<Cas:64, Expiration:32, Flags:32>> = RevMeta,
    {RevSeq, Cas, Expiration, Flags}.


-spec do_send_snapshot(socket(), binary(), partition_id(), request_id(),
                       update_seq(), update_seq()) -> non_neg_integer().
do_send_snapshot(Socket, SetName, PartId, RequestId, StartSeq, EndSeq) ->
    Mutations = create_mutations(SetName, PartId, StartSeq, EndSeq),
    lists:foreach(fun
        ({Cas, Seq, RevSeq, _Flags, _Expiration, _LockTime, Key, deleted}) ->
            Encoded = couch_upr_producer:encode_snapshot_deletion(
                PartId, RequestId, Cas, Seq, RevSeq, Key),
            ok = gen_tcp:send(Socket, Encoded);
        ({Cas, Seq, RevSeq, Flags, Expiration, LockTime, Key, Value}) ->
            Encoded = couch_upr_producer:encode_snapshot_mutation(
                PartId, RequestId, Cas, Seq, RevSeq, Flags, Expiration,
                LockTime, Key, Value),
            ok = gen_tcp:send(Socket, Encoded)
    end, Mutations),
    Marker = couch_upr_producer:encode_snapshot_marker(PartId, RequestId),
    ok = gen_tcp:send(Socket, Marker),
    length(Mutations).


-spec open_db(binary(), partition_id()) ->
                     {ok, #db{}} | {error, cannot_open_db}.
open_db(SetName, PartId) ->
    case couch_db:open_int(?dbname(SetName, PartId), []) of
    {ok, PartDb} ->
        {ok, PartDb};
    _Error ->
        {error, cannot_open_db}
    end.