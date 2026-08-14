# FileStore: one file per key, in a directory the store owns.

# Bytes stored raw in a filename. Uppercase letters are deliberately *not* here:
# the default filesystems on macOS (APFS) and Windows (NTFS) are
# case-insensitive, so filenames differing only in case name the *same file*,
# and two distinct keys must never collide. Escaping all non-ASCII likewise
# sidesteps APFS treating differently-normalized Unicode as the same name.
# Every canonical filename is therefore pure `[a-z0-9._-]` plus `%XX` escapes,
# on which no filesystem case-folding or normalization can cause a collision.
const SAFE_KEY_BYTES = let safe = falses(256)
    for c in "abcdefghijklmnopqrstuvwxyz0123456789._-"
        safe[UInt8(c) + 1] = true
    end
    safe
end

# Windows reserves these device names case-insensitively and regardless of
# extension ("con", "CON.txt", ...); encoding the first byte of a reserved stem
# keeps a store directory portable across operating systems.
const WINDOWS_RESERVED = Set(["con", "prn", "aux", "nul",
                              ("com$i" for i in 1:9)..., ("lpt$i" for i in 1:9)...])

const MAX_FILENAME_BYTES = 255
# Widest adornment `put!` wraps around a name for its temp file:
# ".tmp-" + name + "-" + pid (≤10 digits) + "-" + rand(UInt32) (≤10 digits).
const TMP_NAME_OVERHEAD = 27

"""
    AbstractStores.encodekey(key) -> String

Percent-encode `key` into a single safe, canonical filename.

Every byte outside `[a-z0-9._-]` becomes `%XX`, so `/`, `..`, NUL, and
non-ASCII cannot escape the store directory — and, because uppercase and
non-ASCII bytes are always escaped, two distinct keys cannot collide on a
case-insensitive or Unicode-normalizing filesystem (the defaults on macOS and
Windows).  A leading `.` is also encoded, keeping `.`, `..`, and dotfile
lookalikes out of the namespace so listing can skip dotfiles (`.DS_Store`, our
own temp files) without ambiguity, as is the first byte of a Windows-reserved
device name (`con`, `nul`, `com1`, …).
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
    if startswith(name, '.')
        name = "%2E" * name[2:end]
    elseif first(split(name, '.'; limit=2)) in WINDOWS_RESERVED
        name = string('%', uppercase(string(UInt8(name[1]); base=16, pad=2)), name[2:end])
    end
    # Win32 strips trailing dots from a path component, so "a" and "a." would
    # name the same file; a trailing space is already escaped above.
    endswith(name, '.') && (name = name[1:end-1] * "%2E")
    return name
end

"""
    AbstractStores.decodekey(name) -> Union{String,Nothing}

Inverse of [`encodekey`](@ref).  Returns `nothing` for any name that is not the
*canonical* encoding of a key — verified by round-tripping the decoded key back
through `encodekey` — so listing skips files the store did not write, and no two
listable names can decode to the same key.
"""
function decodekey(name::AbstractString)
    isempty(name) && return nothing     # "" round-trips, but is not a legal key
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
    key = String(take!(io))
    return encodekey(key) == name ? key : nothing
end

"""
    FileStore{T}(dir; codec=SerializedCodec(), permissions=0o600, dirpermissions=0o700)

A store that persists one file per key under `dir`, creating the directory if
needed.

Writes go to a temporary file in the same directory and are then atomically
renamed into place, so a reader never observes a half-written value and a crash
mid-write cannot lose or corrupt an existing entry.

Keys are percent-encoded into filenames (see [`encodekey`](@ref)), which makes
path traversal structurally impossible — a key of `"../../etc/passwd"` names a
file called `%2E.%2F..%2Fetc%2Fpasswd` inside `dir`.  Uppercase and non-ASCII
bytes are escaped too, so keys differing only in case or Unicode normalization
stay distinct even on the case-insensitive filesystems that are the default on
macOS and Windows, and Windows-reserved device names (`con`, `nul`, …) are
handled.  Keys whose encoded form exceeds $(MAX_FILENAME_BYTES - TMP_NAME_OVERHEAD)
bytes are rejected (a $MAX_FILENAME_BYTES-byte filename limit, less the temp-file
adornment), as is the empty key (it has no filename).

Files are created `0o600` and the directory `0o700` by default, on the assumption
that anything worth persisting through this interface (tokens, credentials,
session state) should not be world-readable.  Pass `permissions=nothing` to skip
`chmod` entirely.

!!! warning "Permissions are unix-only"
    Windows has no POSIX mode bits — `chmod` there only toggles the read-only
    flag — so on Windows these defaults do **not** restrict who can read the
    files.  If you are persisting secrets on Windows, put the store somewhere
    already protected by an ACL (e.g. under `%LOCALAPPDATA%`) rather than relying
    on `permissions`.

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

# Manual acquire/release instead of `lock(f, l)`: on current Julia nightly
# the cancellable keyword body of `Base.lock(f, ::ReentrantLock)` is not
# inferred, so every closure result would widen to Any (and juliac --trim
# cannot resolve the downstream calls).
function Base.lock(f, store::FileStore)
    l = store.lock
    lock(l)
    try
        return f()
    finally
        unlock(l)
    end
end

function keypath(store::FileStore, key::AbstractString)
    isempty(key) && throw(ArgumentError(
        "FileStore cannot store the empty key \"\": it has no filename"))
    name = encodekey(key)
    # The budget covers the temp-file adornment too, so a key accepted here
    # cannot fail later with an opaque ENAMETOOLONG at write time.
    sizeof(name) <= MAX_FILENAME_BYTES - TMP_NAME_OVERHEAD || throw(ArgumentError(
        "key encodes to a $(sizeof(name))-byte filename, exceeding the " *
        "$(MAX_FILENAME_BYTES - TMP_NAME_OVERHEAD)-byte limit: $(repr(String(key)))"))
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
            # best-effort reclamation: reading must not require write access
            try rm(path; force=true) catch end
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
            # `Base.Filesystem.rename`, not `mv(force=true)`: mv on Julia < 1.12
            # deletes the destination before renaming, so a crash in between
            # loses the old value and a concurrent reader sees the key vanish.
            # rename replaces atomically on every supported Julia; the caveats
            # are that 1.10/1.11's rename falls back to a copy+delete if the
            # rename syscall itself fails (same-directory renames don't), and
            # on Windows a destination held open by another process can raise a
            # sharing violation where mv would have deleted it first.
            Base.Filesystem.rename(tmp, path)
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

# Override the keys()-based fallback: `empty!` must reclaim expired entries
# too, and the envelope codec's `keys` both hides them and reads every file.
function Base.empty!(store::FileStore; prefix::AbstractString="")
    names = @lock store.lock readdir(store.dir; sort=false)
    for name in names
        startswith(name, '.') && continue
        key = decodekey(name)
        key === nothing && continue
        startswith(key, prefix) || continue
        @lock store.lock rm(joinpath(store.dir, name); force=true)
    end
    return store
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
