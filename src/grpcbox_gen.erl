-module(grpcbox_gen).

-export([
    from_proto/2
]).

from_proto(Proto, OutDir) ->
    GpbOpts = [{module_name_suffix, "_pb"}],
    Module = compile_pb(Proto, GpbOpts, OutDir),
    gen_services(Module, GpbOpts, OutDir).

compile_pb(Filename, GpbOpts, OutDir) ->
    ModuleName = lists:flatten(
        [
            proplists:get_value(module_name_prefix, GpbOpts, ""),
            filename:basename(Filename, ".proto"),
            proplists:get_value(module_name_suffix, GpbOpts, "")
        ]
    ),
    gpb_compile:file(Filename, [
        {rename, {msg_name, snake_case}},
        use_packages,
        maps,
        strings_as_binaries,
        {i, "."},
        {report_errors, false},
        {o, OutDir},
        {descriptor, true}
        | GpbOpts
    ]),
    GeneratedPB = filename:join(OutDir, ModuleName ++ ".erl"),
    GpbIncludeDir = filename:join(code:lib_dir(gpb), "include"),
    BeamOutDir = "/tmp",

    {ok, _} = compile:file(GeneratedPB, [{outdir, BeamOutDir}, {i, GpbIncludeDir}, return_errors]),
    {module, Module} = code:load_abs(filename:join(BeamOutDir, ModuleName)),
    Module.

gen_services(ProtoModule, GrpcConfig, OutDir) ->
    ServiceDefs = 
        [gen_service_def(S, ProtoModule, GrpcConfig, OutDir) || S <- ProtoModule:get_service_names()],

    Templates = ["grpcbox_service_client","grpcbox_service_bhvr"],
    WithTemplates = [{S, T} || S <- ServiceDefs, T <- Templates],
    [template(TemplateName, Service, OutDir)
     || {Service, TemplateName} <- WithTemplates].

gen_service_def(Service, ProtoModule, GrpcConfig, FullOutDir) ->
    ServiceModules = proplists:get_value(service_modules, GrpcConfig, []),
    ServicePrefix = proplists:get_value(prefix, GrpcConfig, ""),
    ServiceSuffix = proplists:get_value(suffix, GrpcConfig, ""),
    {{_, Name}, Methods} = ProtoModule:get_service_def(Service),
    ModuleName = proplists:get_value(Name, ServiceModules, list_snake_case(atom_to_list(Name))),
    #{
        out_dir => FullOutDir,
        pb_module => atom_to_list(ProtoModule),
        unmodified_service_name => atom_to_list(Name),
        module_name => ServicePrefix ++ ModuleName ++ ServiceSuffix,
        methods => [resolve_method(M, ProtoModule) || M <- Methods]
    }.

template(Template, Service, OutDir) ->
    LibDir = os:getenv("ERL_LIBS"),
    TemplateFileName = filename:join([LibDir, "grpcbox", "priv", Template ++ ".erl"]),
    {ok, TemplateFile} = file:read_file(TemplateFileName),
    Data = bbmustache:render(TemplateFile, maps:to_list(Service), [{key_type, atom}, {escape_fun, fun(X) -> X end}]),
    [TemplateSuffix|_] = lists:reverse(string:split(Template, "_", all)),

    Output = filename:join([OutDir, maps:get(module_name, Service) ++ "_" ++ TemplateSuffix ++ ".erl"]),
    ok = filelib:ensure_dir(Output),
    ok = file:write_file(Output, Data),
    Output.

resolve_method(Method, ProtoModule) ->
    MessageType = {message_type, ProtoModule:msg_name_to_fqbin(maps:get(input, Method))},
    MethodData = lists:flatmap(fun normalize_method_opt/1, maps:to_list(Method)),
    [MessageType | MethodData].

normalize_method_opt({opts, _}) ->
    [];
normalize_method_opt({name, Name}) ->
    StrName = atom_to_list(Name),
    [
        {method, list_snake_case(StrName)},
        {unmodified_method, StrName}
    ];
normalize_method_opt({K, V}) when V =:= true; V =:= false ->
    [{K, V}];
normalize_method_opt({K, V}) ->
    [{K, atom_to_list(V)}].

list_snake_case(NameString) ->
    Snaked = lists:foldl(
        fun(RE, Snaking) ->
            re:replace(Snaking, RE, "\\1_\\2", [{return, list}, global])
        end,
        NameString,
        %% uppercase followed by lowercase
        [
            "(.)([A-Z][a-z]+)",
            %% any consecutive digits
            "(.)([0-9]+)",
            %% uppercase with lowercase
            %% or digit before it
            "([a-z0-9])([A-Z])"
        ]
    ),
    Snaked1 = string:replace(Snaked, ".", "_", all),
    Snaked2 = string:replace(Snaked1, "__", "_", all),
    string:to_lower(unicode:characters_to_list(Snaked2)).
