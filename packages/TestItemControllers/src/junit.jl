"""
JUnit XML export for a [`TestrunResult`](@ref).

Every CI system on earth ingests JUnit XML, which is the only reason this exists — the
JSON result model is strictly richer, and nothing in this package reads the XML back.
`write_junit_xml` is a pure function of a `TestrunResult`: it never touches a controller,
a test process or the file system beyond the stream it is handed.

The shape is the conventional one: `<testsuites>` → one `<testsuite>` per source file →
one `<testcase>` per (test item × run profile). Running the same item under several
profiles produces several test cases with the same `classname`/`name` and different
`id`s, which is what a matrix build looks like to a JUnit consumer.
"""

# Strip ANSI escape sequences. Test output is full of them (`Test.jl` colours its failure
# summaries) and they are meaningless — and, in the C1 control range, illegal — in XML.
const _ANSI_CSI = r"\e\[[0-9;:<=>?]*[ -/]*[@-~]"
const _ANSI_OSC = r"\e\][^\a\e]*(?:\a|\e\\)"
const _ANSI_OTHER = r"\e[@-Z\\-_]"

function _strip_ansi(s::AbstractString)
    s = replace(s, _ANSI_OSC => "")
    s = replace(s, _ANSI_CSI => "")
    s = replace(s, _ANSI_OTHER => "")
    return s
end

# XML 1.0 permits tab, newline, carriage return and everything from U+0020 up (minus the
# surrogates). Anything else has no representation at all — not even as a character
# reference — so it is dropped rather than escaped.
_is_valid_xml_char(c::AbstractChar) = (u = UInt32(c); u == 0x9 || u == 0xa || u == 0xd ||
    (0x20 <= u <= 0xd7ff) || (0xe000 <= u <= 0xfffd) || (0x10000 <= u <= 0x10ffff))

"""
    _xml_escape(s)

Escape `s` for use as XML text or as an attribute value. `"` and `'` are escaped too so
the result is safe in either position, and `>` is escaped so a `]]>` in test output cannot
close a section it never opened.
"""
function _xml_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        _is_valid_xml_char(c) || continue
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        elseif c == '"'
            print(io, "&quot;")
        elseif c == '\''
            print(io, "&apos;")
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

_clean(s::AbstractString) = _xml_escape(_strip_ansi(s))

"""
    _report_path(uri, root)::Union{Nothing,String}

The file path of `uri` relative to `root`, with `/` separators so a Windows run and a
Linux run of the same suite produce the same path. Returns `nothing` when `uri` is not a
`file:` URI, leaving it to the caller to decide what an unusable entry becomes.

Shared with the LCOV writer, which needs the same relativization for its `SF:` lines.
"""
function _report_path(uri::AbstractString, root::Union{Nothing,AbstractString})
    path = try
        uri2filepath(uri)
    catch
        nothing
    end
    path === nothing && return nothing

    if root !== nothing
        root_path = startswith(root, "file:") ? something(uri2filepath(root), root) : root
        # `relpath` does not resolve a relative start path against the working directory, so
        # a caller passing `testdata/Pkg` would get a `..`-heavy result, fail the guard below
        # and silently fall back to absolute machine paths in every `classname`.
        root_path = try
            abspath(root_path)
        catch
            root_path
        end
        rel = try
            relpath(path, root_path)
        catch
            path
        end
        # `relpath` happily walks out of the root with `..`; an absolute-looking path is
        # more informative than a pile of parent references.
        if !startswith(rel, "..")
            path = rel
        end
    end

    return replace(path, '\\' => '/')
end

"""
    _relative_path(uri, root)

As [`_report_path`](@ref), but falling back to the URI itself when the path cannot be
derived — a `classname` has to say *something*.
"""
_relative_path(uri::AbstractString, root::Union{Nothing,AbstractString}) =
    something(_report_path(uri, root), String(uri))

# The discovery id, as recorded by whoever produced the result.
#
# This used to be reconstructed from `(uri, root)` and the name. That was wrong twice over:
# it assumed `root` was the item's package root when callers pass the *run* root, which in a
# multi-package run is neither; and the id now carries a package qualifier that cannot be
# recovered from a path at all. The fallback survives only for result files written before
# `id` was recorded, and reproduces the old — approximate — behaviour for those.
function _testitem_id(item::TestrunResultTestitem, root)
    isempty(item.id) || return item.id
    return string(_relative_path(item.uri, root), "::", item.name)
end

_junit_seconds(duration::Union{Nothing,Float64}) = duration === nothing ? 0.0 : duration / 1000

# `:timeout` and `:crash` have no JUnit spelling of their own; they are errors that
# happened to the item rather than assertion failures, so they land in `<error>` with the
# distinction preserved in the message.
_junit_kind(status::Symbol) =
    status === :failed ? :failure :
    status === :skipped ? :skipped :
    status in (:errored, :timeout, :crash) ? :error :
    :passed

function _write_perf_properties(io::IO, perf::TestrunResultPerfStats, indent::String)
    fields = (
        ("elapsed_ms", perf.elapsed),
        ("bytes", perf.bytes),
        ("allocs", perf.allocs),
        ("gctime_ms", perf.gctime),
        ("compile_time_ms", perf.compile_time),
        ("recompile_time_ms", perf.recompile_time),
    )
    present = [(n, v) for (n, v) in fields if v !== nothing]
    isempty(present) && return

    println(io, indent, "<properties>")
    for (name, value) in present
        println(io, indent, "  <property name=\"", name, "\" value=\"", value, "\"/>")
    end
    println(io, indent, "</properties>")
end

function _write_testcase(io::IO, item::TestrunResultTestitem, profile::TestrunResultTestitemProfile,
        classname::String, id::String)
    kind = _junit_kind(profile.status)

    print(io, "    <testcase classname=\"", _clean(classname), "\"",
        " name=\"", _clean(item.name), "\"",
        " id=\"", _clean(id), "\"",
        " time=\"", _junit_seconds(profile.duration), "\"")

    has_body = kind !== :passed || (profile.output !== nothing && !isempty(profile.output)) ||
        profile.perf !== nothing
    if !has_body
        println(io, "/>")
        return
    end
    println(io, ">")

    if profile.perf !== nothing
        _write_perf_properties(io, profile.perf, "      ")
    end

    if kind === :skipped
        println(io, "      <skipped/>")
    elseif kind !== :passed
        tag = kind === :failure ? "failure" : "error"
        messages = profile.messages === nothing ? TestrunResultMessage[] : profile.messages
        if isempty(messages)
            # A timeout or a crash produces no messages, but a `<testcase>` that is neither
            # passing nor carrying a failure element reads as a pass to most consumers.
            println(io, "      <", tag, " message=\"", _clean(string(profile.status)),
                "\" type=\"", _clean(string(profile.status)), "\"/>")
        else
            for m in messages
                summary = first(split(m.message, '\n'; limit=2))
                println(io, "      <", tag, " message=\"", _clean(summary),
                    "\" type=\"", _clean(string(profile.status)), "\">")
                println(io, _clean(_message_detail(m)))
                println(io, "      </", tag, ">")
            end
        end
    end

    if profile.output !== nothing && !isempty(profile.output)
        println(io, "      <system-out>")
        println(io, _clean(profile.output))
        println(io, "      </system-out>")
    end

    println(io, "    </testcase>")
    return
end

function _message_detail(m::TestrunResultMessage)
    io = IOBuffer()
    println(io, m.message)
    if m.expected_output !== nothing || m.actual_output !== nothing
        println(io, "  Expected: ", something(m.expected_output, ""))
        println(io, "  Actual:   ", something(m.actual_output, ""))
    end
    if !isempty(m.uri)
        println(io, "  at ", m.uri, ":", m.line, ":", m.column)
    end
    if m.stack_frames !== nothing
        println(io, "Stacktrace:")
        for f in m.stack_frames
            println(io, "  ", f.label, isempty(f.uri) ? "" : string(" at ", f.uri, ":", f.line))
        end
    end
    return String(take!(io))
end

"""
    write_junit_xml(io_or_path, result::TestrunResult; root=nothing)

Write `result` as JUnit XML.

Test items are grouped into one `<testsuite>` per source file, and each (item, run
profile) pair becomes a `<testcase>` whose `classname` is the file path relative to
`root`, `name` is the item's label and `id` is its stable test item id. Failures become
`<failure>`, errors/timeouts/crashes `<error>`, skips `<skipped>`; captured output goes to
`<system-out>` with ANSI escape sequences stripped; performance statistics, when present,
become `<properties>`.

`root` is a directory path or `file:` URI to relativize paths against; without it the
absolute paths are used. Definition errors are reported as a synthetic `Definition errors`
test suite so a suite that failed to even parse cannot be mistaken for an empty one.
"""
function write_junit_xml(io::IO, result::TestrunResult; root::Union{Nothing,AbstractString}=nothing)
    # Group by file, preserving the order the items appear in the result.
    suites = Tuple{String,Vector{TestrunResultTestitem}}[]
    suite_index = Dict{String,Int}()
    for item in result.testitems
        idx = get(suite_index, item.uri, 0)
        if idx == 0
            push!(suites, (item.uri, TestrunResultTestitem[]))
            suite_index[item.uri] = length(suites)
            idx = length(suites)
        end
        push!(suites[idx][2], item)
    end

    total_tests = sum(length(i.profiles) for i in result.testitems; init=0)
    all_profiles = [p for i in result.testitems for p in i.profiles]
    total_failures = count(p -> _junit_kind(p.status) === :failure, all_profiles)
    total_errors = count(p -> _junit_kind(p.status) === :error, all_profiles) + length(result.definition_errors)
    total_skipped = count(p -> _junit_kind(p.status) === :skipped, all_profiles)
    total_time = sum(_junit_seconds(p.duration) for p in all_profiles; init=0.0)

    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    println(io, "<testsuites tests=\"", total_tests + length(result.definition_errors),
        "\" failures=\"", total_failures,
        "\" errors=\"", total_errors,
        "\" skipped=\"", total_skipped,
        "\" time=\"", total_time, "\">")

    for (uri, items) in suites
        classname = _relative_path(uri, root)
        profiles = [p for i in items for p in i.profiles]
        println(io, "  <testsuite name=\"", _clean(classname),
            "\" tests=\"", length(profiles),
            "\" failures=\"", count(p -> _junit_kind(p.status) === :failure, profiles),
            "\" errors=\"", count(p -> _junit_kind(p.status) === :error, profiles),
            "\" skipped=\"", count(p -> _junit_kind(p.status) === :skipped, profiles),
            "\" time=\"", sum(_junit_seconds(p.duration) for p in profiles; init=0.0), "\">")
        for item in items
            id = _testitem_id(item, root)
            for profile in item.profiles
                _write_testcase(io, item, profile, classname, id)
            end
        end
        println(io, "  </testsuite>")
    end

    if !isempty(result.definition_errors)
        println(io, "  <testsuite name=\"Definition errors\" tests=\"", length(result.definition_errors),
            "\" failures=\"0\" errors=\"", length(result.definition_errors), "\" skipped=\"0\" time=\"0.0\">")
        for e in result.definition_errors
            path = _relative_path(e.uri, root)
            println(io, "    <testcase classname=\"", _clean(path),
                "\" name=\"", _clean(string(path, ":", e.line, ":", e.column)),
                "\" id=\"", _clean(string(path, "::", e.line, ":", e.column)), "\" time=\"0.0\">")
            println(io, "      <error message=\"", _clean(first(split(e.message, '\n'; limit=2))),
                "\" type=\"definition_error\">")
            println(io, _clean(e.message))
            println(io, "      </error>")
            println(io, "    </testcase>")
        end
        println(io, "  </testsuite>")
    end

    println(io, "</testsuites>")
    return
end

function write_junit_xml(path::AbstractString, result::TestrunResult; root::Union{Nothing,AbstractString}=nothing)
    open(path, "w") do io
        write_junit_xml(io, result; root=root)
    end
end
