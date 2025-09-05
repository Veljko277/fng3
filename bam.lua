Import("configure.lua")

--- Setup Config -------
config = NewConfig()
config:Add(OptCCompiler("compiler"))
config:Add(OptLibrary("zlib", "zlib.h", true))
config:Finalize("config.lua")
settings = NewSettings()

-- data compiler
function Script(name) return "python " .. name end

function CHash(output, ...) -- used in generated files only
    local inputs = TableFlatten({ ... })
    output = Path(output)

    -- compile all the files
    local cmd = Script("datasrc/cmd5.py") .. " "
    for index, inname in ipairs(inputs) do
        cmd = cmd .. Path(inname) .. " "
    end

    cmd = cmd .. " > " .. output

    AddJob(output, "cmd5 " .. output, cmd)
    for index, inname in ipairs(inputs) do
        AddDependency(output, inname)
    end
    AddDependency(output, "datasrc/cmd5.py")
    return output
end

function ResCompile(scriptfile)
    scriptfile = Path(scriptfile)
    if config.compiler.driver == "cl" then
        output = PathBase(scriptfile) .. ".res"
        AddJob(output, "rc " .. scriptfile, "rc /fo " .. output .. " " .. scriptfile)
    elseif config.compiler.driver == "gcc" then
        output = PathBase(scriptfile) .. ".coff"
        AddJob(output, "windres " .. scriptfile, "windres -i " .. scriptfile .. " -o " .. output)
    end
    AddDependency(output, scriptfile)
    return output
end

function ContentCompile(action, output)
    output = Path(output)
    AddJob(
        output,
        action .. " > " .. output,
        Script("datasrc/compile.py") .. " " .. action .. " > " .. Path(output)
    )
    AddDependency(output, Path("datasrc/content.py")) -- do this more proper
    AddDependency(output, Path("datasrc/network.py"))
    AddDependency(output, Path("datasrc/compile.py"))
    AddDependency(output, Path("datasrc/datatypes.py"))
    return output
end

-- Content Compile\Generate
network_source = ContentCompile("network_source", "src/game/generated/protocol.cpp")
network_header = ContentCompile("network_header", "src/game/generated/protocol.h")
server_content_source = ContentCompile("server_content_source", "src/game/generated/server_data.cpp")
server_content_header = ContentCompile("server_content_header", "src/game/generated/server_data.h")
AddDependency(network_source, network_header)
AddDependency(server_content_source, server_content_header)

nethash = CHash("src/game/generated/nethash.cpp", "src/engine/shared/protocol.h", "src/game/generated/protocol.h",
    "src/game/tuning.h", "src/game/gamecore.cpp", network_header)

function Intermediate_Output(settings, input)
    return "objs/" .. string.sub(PathBase(input), string.len("src/") + 1) .. settings.config_ext
end

-- apply compiler settings
config.compiler:Apply(settings)

--settings.objdir = Path("objs")
settings.cc.Output = Intermediate_Output

if config.compiler.driver == "cl" then
    settings.cc.flags:Add("/wd4244", "/wd4577")
else
    settings.cc.flags:Add("-Wall", "-fexceptions")
    settings.link.flags:Add("-fstack-protector", "-fstack-protector-all")
end
settings.cc.includes:Add("src")

settings.link.libs:Add("pthread")
-- add ICU
settings.cc.flags:Add("`pkg-config --cflags icu-uc icu-i18n`")
settings.link.flags:Add("`pkg-config --libs icu-uc icu-i18n`")
-- ExFlags
settings.cc.flags:Add("-std=c++20")
-- Use system zlib library instead of compiling a local copy
settings.link.libs:Add("z")

settings.link.flags:Add("-lmysqlclient -lmysqlcppconn")
-- Make Database interface in rust to avoid conflits and split work

engine_settings = settings:Copy()
server_settings = engine_settings:Copy()
engine = Compile(engine_settings, Collect("src/engine/shared/*.cpp", "src/base/*.cpp"))
server = Compile(server_settings, Collect("src/engine/server/*.cpp"))
game_shared = Compile(settings, Collect("src/game/*.cpp"), nethash, network_source)
game_server = Compile(settings, CollectRecursive("src/game/server/*.cpp"), server_content_source)
md5_comp = Compile(settings, Collect("src/engine/external/md5/*.cpp"))
json_comp = Compile(settings, Collect("src/engine/external/json/*.c", "src/engine/external/json/*.cpp"))


settings.cc.includes:Add("src/engine/external/md5")
settings.cc.includes:Add("src/engine/external/json")
settings.cc.defines:Add("CONF_OPENSSL")
settings.cc.flags:Add("`pkg-config --cflags openssl`")
settings.link.flags:Add("`pkg-config --libs openssl`")

external = Compile(settings, Collect("src/engine/external/*.c", "src/engine/external/*.cpp"))

-- build server
server_exe = Link(server_settings, "teeworlds_srv", engine, server,
    game_shared, game_server, zlib, external, md5_comp, json_comp)

-- make targets
s = PseudoTarget("server" .. "_" .. settings.config_name, server_exe, serverlaunch, icu_depends)

all = PseudoTarget(settings.config_name, c, s, v, m, t)
return all