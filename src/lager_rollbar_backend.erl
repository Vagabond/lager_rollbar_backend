%% Copyright (c) 2011-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% @doc Rollbar backend for lager.

-module(lager_rollbar_backend).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {level, handle, api_key, config, version}).

-include_lib("lager/include/lager.hrl").

-define(DEFAULT_FORMAT,["[", severity, "] ",
        {pid, ""},
        {module, [
                {pid, ["@"], ""},
                module,
                {function, [":", function], ""},
                {line, [":",line], ""}], ""},
        " ", message]).


%% @private
init(Config) when is_list(Config) ->
    case validate_config(Config) of
        true ->
            case application:start(hackney) of
                ok ->
                    init2(Config);
                {error, {already_started, _}} ->
                    init2(Config);
                Error ->
                    Error
            end;
        false ->
            {error, {fatal, bad_config}}
    end.

%% @private
init2(Config) ->
    case hackney:connect(hackney_tcp, "https://api.rollbar.com", 443, []) of
        {ok, Conn} ->
            try parse_level(proplists:get_value(level, Config)) of
                Lvl ->
                    {ok, #state{level=Lvl,
                                api_key = proplists:get_value(api_key, Config),
                                config=Config,
                                version=get_version(),
                                handle=Conn}}
                catch
                    _:_ ->
                        {error, bad_log_level}
                end;
        Error ->
            Error
    end.


%% @private
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try parse_level(Level) of
        Lvl ->
            {ok, ok, State#state{level=Lvl}}
    catch
        _:_ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Message}, #state{level=Level, handle=Conn} = State) ->
    case lager_util:is_loggable(Message, Level, ?MODULE) of
        true ->
            hackney:send_request(Conn, {post, <<"/api/1/item">>, [], to_json(Message, State)}),
            {ok, State};
        false ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

convert_level(?DEBUG) -> debug;
convert_level(?INFO) -> info;
convert_level(?NOTICE) -> info;
convert_level(?WARNING) -> warning;
convert_level(?ERROR) -> error;
convert_level(?CRITICAL) -> critical;
convert_level(?ALERT) -> critical;
convert_level(?EMERGENCY) -> critical.

parse_level(Level) ->
    try lager_util:config_to_mask(Level) of
        Res ->
            Res
    catch
        error:undef ->
            %% must be lager < 2.0
            lager_util:level_to_num(Level)
    end.

validate_config(Config) ->
    lists:all(fun(X) -> X end, [lists:keyfind(X, 1, Config) /= false || X <- [level, api_key]]).

get_version() ->
    case lists:keyfind(lager_rollbar_backend, 1, application_controller:which_applications()) of
        {lager_rollbar_backend, _, Version} ->
            list_to_binary(Version);
        _ ->
            undefined
    end.

fingerprint(Message) ->
    Md = lager_msg:metadata(Message),
    list_to_binary(io_lib:format("~.16b",
                                 [erlang:phash2([{module, proplists:get_value(module, Md)},
                                                 {function, proplists:get_value(function, Md)},
                                                 {line, proplists:get_value(line, Md)}])])).

to_json(Message, #state{api_key=APIKey, config=Config, version=Version}) ->
    jsx:encode([{payload, [
                           {access_token, APIKey},
                           {data, 
                            [
                             {environment, proplists:get_value(environment, Config, <<"production">>)},
                             {body, [
                                     {message, [
                                                {body, list_to_binary(lager_msg:message(Message))} |
                                                serialize_metadata(lager_msg:metadata(Message), [])
                                               ]
                                     },
                                     {level, convert_level(lager_msg:severity(Message))},
                                     {language, erlang},
                                     %% TODO UUID
                                     {fingerprint, fingerprint(Message)},
                                     {notifier, [
                                                 {name, lager_rollbar_backend},
                                                 {version, Version}
                                                ]}
                                    ]}
                            ]}
                          ]}
               ]).

get_metadata(Key, Metadata) ->
    get_metadata(Key, Metadata, <<"undefined">>).

get_metadata(Key, Metadata, Default) ->
    case lists:keyfind(Key, 1, Metadata) of
        false ->
            Default;
        {Key, Value} when is_atom(Value) ->
            list_to_binary(atom_to_list(Value));
        {Key, Value} when is_list(Value) ->
            list_to_binary(Value);
        {Key, Value} when is_integer(Value) ->
            Value;
        {Key, Value}  ->
            list_to_binary(io_lib:format("~p", [Value]))
    end.

serialize_metadata([], Acc) ->
    Acc;
serialize_metadata([{Key, Value}|T], Acc) ->
    serialize_metadata(T, [{Key, get_metadata(Key, [{Key, Value}])}|Acc]).
