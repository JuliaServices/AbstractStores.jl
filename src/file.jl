# FileStore: one file per key, in a directory the store owns.

const SAFE_KEY_BYTES = let safe = falses(256)
    for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        safe[UInt8(c) + 1] = true
    end
    safe
end

const MAX_FILENAME_BYTES = 255

"""
    AbstractStores.encodekey(key) -> String

Percent-encode `key` into a single safe filename.  Every byte outside
`[A-Za-z0-9._-]` becomes `%XX`, so `/`, `..`, NUL, and non-ASCII cannot escape
the store directory.  A leading `.` is always encoded, which keeps `.`, `..`, and
dotfile-lookalikes out of the namespace and lets listing skip dotfiles
(`.DS_Store`, our own temp files) without ambiguity.
"""
function encodekey(key::AbstractString)
    io = IOBuffer()
    for b in codeunits(String(key))
        if SAFE_KEY_BYTES[b + 1]
            write(io, b)
        else
            print(io, '%', uppercase(string(b; base=16, pad=2)))
        end
    end
    name = String(take!(io))
    startswith(name, '.') && (name = "%2E" * name[2:end])
    return name
end

"""
    AbstractStores.decodekey(name) -> Union{String,Nothing}

Inverse of [`encodekey`](@ref).  Returns `nothing` for names that are not valid
encodings, so listing can skip files the store did not write.
"""
function decodekey(name::AbstractString)
    bytes = codeunits(name)
    io = IOBuffer()
    i = 1
    while i <= length(bytes)
        b = bytes[i]
        if b == UInt8('%')
            i + 2 <= length(bytes) || return nothing
            hex = tryparse(UInt8, String(bytes[i+1:i+2]); base=16)
            hex === nothing && return nothing
            write(io, hex)
            i += 3
        else
            write(io, b)
            i += 1
        end
    end
    return String(take!(io))
end

"""
    FileStore{T}(dir; codec=SerializedCodec(), permissions=0o600, dirpermissions=0o700)

A store that persists one file per key under `dir`, creating the directory if
needed.

Writes go to a temporary file in the same directory and are then `mv`'d into
place, so a reader never observes a half-written value and a crash mid-write
cannot corrupt an existing entry.

Keys are percent-encoded into filenames (see [`encodekey`](@ref)), which makes
path traversal structurally impossible — a key of `"../../etc/passwd"` names a
file called `%2E%2E%2F%2E%2E%2Fetc%2Fpasswd` inside `dir`.  Keys whose encoded
form exceeds $MAX_FILENAME_BYTES bytes are rejected.

Files are created `0o600` and the directory `0o700` by default, on the assumption
that anything worth persisting through this interface (tokens, credentials,
session state) should not be world-readable.  Pass `permissions=nothing` to skip
`chmod` entirely.

- [`supportsttl`](@ref): `true`, unless `codec` is [`RawCodec`](@ref) — expiry
  travels in the encoded [`Entry`](@ref) envelope, so a raw-bytes codec has
  nowhere to put it
- [`isatomic`](@ref): `false` — individual `put!`s are atomic, but a
  `modify!`/`pop!` read-modify-write is serialized only against other tasks in
  *this* process.  Two processes sharing a directory can lose an update; if you
  need multi-process single-use semantics, use a store backed by a server that
  can do a real compare-and-swap.

# Examples
```julia
julia> store = FileStore{String}(joinpath(tempdir(), "tokens"); codec=JSONCodec());

julia> store["refresh"] = "rt_abc123";

julia> store["refresh"]
"rt_abc123"

julia> readdir(store.dir)
1-element Vector{String}:
 "refresh"
```
"""
struct FileStore{T,C<:AbstractCodec} <: AbstractStore{T}
    dir::String
    codec::C
    permissions::Union{Nothing,UInt16}
    lock::ReentrantLock
end

function FileStore{T}(dir::AbstractString;
                      codec::AbstractCodec=SerializedCodec(),
                      permissions::Union{Nothing,Integer}=0o600,
                      dirpermissions::Union{Nothing,Integer}=0o700) where {T}
    path = abspath(expanduser(String(dir)))
    isdir(path) || mkpath(path)
    dirpermissions === nothing || chmod(path, Int(dirpermissions))
    perm = permissions === nothing ? nothing : UInt16(permissions)
    return FileStore{T,typeof(codec)}(path, codec, perm, ReentrantLock())
end

FileStore(dir::AbstractString; kw...) = FileStore{Any}(dir; kw...)

supportsttl(store::FileStore) = canexpire(store.codec)
supportslisting(::FileStore) = true
isatomic(::FileStore) = false

Base.lock(f, store::FileStore) = lock(f, store.lock)

function keypath(store::FileStore, key::AbstractString)
    name = encodekey(key)
    sizeof(name) <= MAX_FILENAME_BYTES || throw(ArgumentError(
        "key encodes to a $(sizeof(name))-byte filename, exceeding the " *
        "$MAX_FILENAME_BYTES-byte limit: $(repr(String(key)))"))
    return joinpath(store.dir, name)
end

# Read the raw entry, or `nothing` if the file is absent.
function readentry(store::FileStore{T}, path::AbstractString) where {T}
    isfile(path) || return nothing
    bytes = try
        read(path)
    catch e
        # lost a race with a concurrent delete; anything else is a real problem
        (e isa Base.IOError || e isa SystemError) && !isfile(path) && return nothing
        rethrow()
    end
    return canexpire(store.codec) ? decodeentry(store.codec, T, bytes) :
           Entry{T}(decode(store.codec, T, bytes), nothing)
end

function Base.get(store::FileStore, key::AbstractString, default)
    path = keypath(store, key)
    return lock(store.lock) do
        entry = readentry(store, path)
        entry === nothing && return default
        if isexpired(entry)
            rm(path; force=true)
            return default
        end
        return entry.value
    end
end

function Base.put!(store::FileStore{T}, key::AbstractString, value; ttl=nothing) where {T}
    checkttl(store, ttl)
    path = keypath(store, key)
    typed = convert(T, value)
    bytes = canexpire(store.codec) ? encodeentry(store.codec, Entry{T}(typed, expiryof(ttl))) :
            encode(store.codec, typed)
    lock(store.lock) do
        # temp name starts with '.' so a concurrent `keys` skips it
        tmp = joinpath(store.dir, string(".tmp-", basename(path), "-", getpid(), "-", rand(UInt32)))
        try
            open(tmp, "w") do io
                write(io, bytes)
            end
            store.permissions === nothing || chmod(tmp, Int(store.permissions))
            mv(tmp, path; force=true)
        catch
            rm(tmp; force=true)
            rethrow()
        end
    end
    return store
end

function Base.delete!(store::FileStore, key::AbstractString)
    @lock store.lock rm(keypath(store, key); force=true)
    return store
end

function Base.haskey(store::FileStore, key::AbstractString)
    path = keypath(store, key)
    isfile(path) || return false
    canexpire(store.codec) || return true
    return get(store, key, NOTFOUND) !== NOTFOUND
end

"""
    keys(store::FileStore; prefix="")

List the store's keys.

When the codec carries an expiry envelope this reads every file, because the
deadline lives inside the value — a directory of `n` entries costs `n` reads.
With a [`RawCodec`](@ref) (no expiry possible) it is a plain `readdir`.
"""
function Base.keys(store::FileStore; prefix::AbstractString="")
    names = @lock store.lock readdir(store.dir; sort=false)
    result = String[]
    now = Dates.now(UTC)
    for name in names
        startswith(name, '.') && continue        # temp files, .DS_Store, etc.
        key = decodekey(name)
        key === nothing && continue
        startswith(key, prefix) || continue
        if canexpire(store.codec)
            entry = @lock store.lock readentry(store, joinpath(store.dir, name))
            (entry === nothing || isexpired(entry, now)) && continue
        end
        push!(result, key)
    end
    return result
end

function sweep!(store::FileStore)
    canexpire(store.codec) || return 0
    names = @lock store.lock readdir(store.dir; sort=false)
    now = Dates.now(UTC)
    removed = 0
    for name in names
        startswith(name, '.') && continue
        decodekey(name) === nothing && continue
        path = joinpath(store.dir, name)
        @lock store.lock begin
            entry = readentry(store, path)
            if entry !== nothing && isexpired(entry, now)
                rm(path; force=true)
                removed += 1
            end
        end
    end
    return removed
end

Base.show(io::IO, store::FileStore{T}) where {T} =
    print(io, "FileStore{", T, "}(", repr(store.dir), "; codec=", store.codec, ")")
