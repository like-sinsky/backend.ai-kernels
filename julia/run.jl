module SornaExecutor

"""
This submodule is exposed to the user codes as their "Main" module.
"""
module SornaExecutionEnv # submodule

import ZMQ
import JSON
import Base: display, readline, flush, PipeEndpoint, info, warn

# overloading hack from IJulia
const StdioPipe = Base.PipeEndpoint

type SornaDisplay <: Display
    isock::ZMQ.Socket
    osock::ZMQ.Socket
end

function display(d::SornaDisplay, M::MIME"image/png", x)
    local data = reprmime(M, x)
    local o = Dict(
        "type" => string(M),
        "data" => Base64Encode(data),
    )
    ZMQ.send(d.osock, "media", true)
    ZMQ.send(d.osock, JSON.json(o))
end

function display(d::SornaDisplay, M::MIME"image/svg", x)
    local data = reprmime(M, x)
    local o = Dict(
        "type" => string(M),
        "data" => x,
    )
    ZMQ.send(d.osock, "media", true)
    ZMQ.send(d.osock, JSON.json(o))
end

function display(d::SornaDisplay, M::MIME"text/html", x)
    local data = reprmime(M, x)
    local o = Dict(
        "type" => string(M),
        "data" => x,
    )
    ZMQ.send(d.osock, "media", true)
    ZMQ.send(d.osock, JSON.json(o))
end

function info(io::StdioPipe, msg...; kw...)
    if io == STDERR
        local o = chomp(string(msg...))
        ZMQ.send(sorna.osock, "stderr", true)
        ZMQ.send(sorna.osock, "INFO: $o")
        #local o = Dict(
        #    "level" => "info",
        #    "msg"   => chomp(string(msg...)),
        #)
        #ZMQ.send(sorna.osock, "log", true)
        #ZMQ.send(sorna.osock, JSON.json(o))
    else
        invoke(info, Tuple{supertype(StdioPipe)}, io, msg..., kw...)
    end
end

function warn(io::StdioPipe, msg...; kw...)
    if io == STDERR
        local o = chomp(string(msg...))
        ZMQ.send(sorna.osock, "stderr", true)
        ZMQ.send(sorna.osock, "WARN: $o")
        #local o = Dict(
        #    "level" => "warn",
        #    "msg"   => chomp(string(msg...)),
        #)
        #ZMQ.send(sorna.osock, "log", true)
        #ZMQ.send(sorna.osock, "warn", true)
        #ZMQ.send(sorna.osock, JSON.json(o))
    else
        invoke(warn, Tuple{supertype(StdioPipe)}, io, msg..., kw...)
    end
end

"""
Read a String from the front-end web browser.
This function is a Sorna version of IJulia's readprompt.
"""
function readprompt(prompt::AbstractString; password::Bool=false)
    global sorna
    local opts = Dict("is_password" => password)
    ZMQ.send(sorna.osock, "stdout", true)
    ZMQ.send(sorna.osock, prompt)
    ZMQ.send(sorna.osock, "waiting-input", true)
    ZMQ.send(sorna.osock, JSON.json(opts))
    code_id = unsafe_string(ZMQ.recv(sorna.isock))
    code_txt = unsafe_string(ZMQ.recv(sorna.isock))
    return code_txt
end

"Native-like readline function that emulates stdin using readprompt."
function readline(io::StdioPipe)
    if io == STDIN
        return readprompt("STDIN> ")
    else
        invoke(readline, Tuple{supertype(StdioPipe)}, io)
    end
end

function flush(io::StdioPipe)
    invoke(flush, Tuple{supertype(StdioPipe)}, io)
    oslibuv_flush()
    if io == STDIN
        # TODO: implement
    elseif io == STDERR
        # TODO: implement
    end
end

function init_sorna(isock::ZMQ.Socket, osock::ZMQ.Socket)
    global sorna
    sorna = SornaDisplay(isock, osock)
    pushdisplay(sorna)
    println("sorna initialized")
end

end # submodule

import ZMQ
import .SornaExecutionEnv

"""
Makes a block expression from the given (multi-line) string.
We need this special function since Julia's vanilla parse()
function only takes a single line of string.
"""
function parseall(code::AbstractString)
    exprs = []
    pos = start(code)
    lineno = 1
    try
        while !done(code, pos)
            expr, pos = parse(code, pos)
            push!(exprs, expr)
            lineno += 1
        end
    catch ex
        if isa(ex, ParseError)
            # Add the line number to parsing errors
            throw(ParseError("$(ex.msg) (Line $lineno)"))
        else
            rethrow()
        end
    end

    if length(exprs) == 0
        throw(ParseError("Premature end of input"))
    elseif length(exprs) == 1
        return exprs[1]
    else
        return Expr(:block, exprs...)
    end
end

function redirect_stream(rd::IO, target::AbstractString, osock::ZMQ.Socket)
    try
        while !eof(rd)
            nb = nb_available(rd)
            if nb > 0
                ZMQ.send(osock, target, true)
                ZMQ.send(osock, read(rd, nb))
            end
        end
    catch e
        if isa(e, InterruptException)
            redirect_stream(rd, target, output_socket)
        else
            rethrow()
        end
    end
end

# format_stackframe is taken from https://github.com/invenia/StackTraces.jl
# which is now part of Julia's standard library since v0.5.
# Unfortunately the standard library does not expose formatting functions... :(
function format_stackframe(frame::StackFrame; full_path::Bool=false)
    file_info = string(
        full_path ? frame.file : basename(string(frame.file)),
        ":", frame.line
    )
    if :inlined_file in fieldnames(frame) && frame.inlined_file != Symbol("")
        inline_info = "[inlined code from $file_info] "
        file_info = string(
            full_path ? frame.inlined_file : basename(string(frame.inlined_file)),
            ":", frame.inlined_line
        )
    else
        inline_info = ""
    end
    func_name = string(frame.func)
    if (func_name == "execute_code" || func_name == "parseall") && basename(string(frame.file)) == "run.jl"
        nothing
    else
        "$inline_info$(frame.func != "" ? frame.func : "?") at $file_info"
    end
end

function format_stacktrace(stack::StackTrace, ex::Exception = nothing; full_path::Bool=false)
    prefix = (ex != nothing) ? "ERROR: $(typeof(ex)): $(ex.msg)" : ""
    if isempty(stack)
        return prefix
    end
    pieces = []
    for f in stack
        piece = format_stackframe(f, full_path=full_path)
        if piece == nothing
            break
        end
        push!(pieces, piece)
    end
    string(
        prefix, "\n",
        join(map(piece -> "  $piece", pieces), "\n"),
    )
end

function execute_code(input_socket, output_socket, code_id, code_txt)
    try
        exprs = parseall(code_txt)
        SornaExecutionEnv.eval(exprs)
    catch ex
        st = catch_stacktrace()
        write(STDERR, format_stacktrace(st, ex))
    finally
        # ensure reader tasks to run once more.
        sleep(0.001)
        ZMQ.send(output_socket, "finished", true)
        ZMQ.send(output_socket, "")
    end
end

function run_query_mode()

    # ZMQ setup
    ctx = ZMQ.Context()
    input_socket = ZMQ.Socket(ctx, ZMQ.PULL)
    output_socket = ZMQ.Socket(ctx, ZMQ.PUSH)
    ZMQ.bind(input_socket, "tcp://*:2000")
    ZMQ.bind(output_socket, "tcp://*:2001")

    SornaExecutionEnv.init_sorna(input_socket, output_socket)

    println("start serving...")

    const read_stdout = Ref{Base.PipeEndpoint}()
    const read_stderr = Ref{Base.PipeEndpoint}()

    read_stdout[], = redirect_stdout()
    read_stderr[], = redirect_stderr()

    # Intercept STDOUT and STDERR
    readout_task = @async redirect_stream(read_stdout[], "stdout", output_socket)
    readerr_task = @async redirect_stream(read_stderr[], "stderr", output_socket)

    try
        while true
            # Receive code_id and code_txt
            code_id = unsafe_string(ZMQ.recv(input_socket))
            code_txt = unsafe_string(ZMQ.recv(input_socket))

            # Evaluate code
            execute_code(input_socket, output_socket, code_id, code_txt)
        end
    finally
        ZMQ.close(input_socket)
        ZMQ.close(output_socket)
        ZMQ.close(ctx)
    end
end

end # module


import SornaExecutor

SornaExecutor.run_query_mode()

# vim: ts=8 sts=4 sw=4 et
