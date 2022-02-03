-ifndef(MRIA_RLOG_HRL).
-define(MRIA_RLOG_HRL, true).

-record(rlog,
        { key :: mria_lib:txid()
        , ops :: mria_lib:tx()
        }).

-define(schema, mria_schema).

%% Note to self: don't forget to update all the match specs in
%% `mria_schema' module when changing fields in this record
-record(?schema,
        { mnesia_table
        , shard
        , storage
        , config
        }).

-define(LOCAL_CONTENT_SHARD, undefined).

-define(IMPORTED(REF), {imported, REF}).

-endif.
