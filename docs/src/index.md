# AbstractStores.jl

```@meta
CurrentModule = AbstractStores
```

A small, backend-agnostic interface for storing simple state: a library declares
that it needs an `AbstractStore{T}`, and the application decides whether that
lives in a `Dict`, a directory, SQLite, Postgres, Redis, or an S3 bucket.

See the [README](https://github.com/JuliaServices/AbstractStores.jl) for an
overview and the backend comparison table.

```@docs
AbstractStores
```

## The interface

```@docs
AbstractStore
Base.get(::AbstractStore, ::AbstractString, ::Any)
Base.put!(::AbstractStore, ::AbstractString, ::Any)
Base.delete!(::AbstractStore, ::AbstractString)
Base.keys(::AbstractStore)
modify!
sweep!
```

### Derived operations

```@docs
Base.getindex(::AbstractStore, ::AbstractString)
Base.setindex!(::AbstractStore, ::Any, ::AbstractString)
Base.haskey(::AbstractStore, ::AbstractString)
Base.pop!(::AbstractStore, ::AbstractString, ::Any)
Base.get!(::AbstractStore, ::AbstractString, ::Any)
Base.length(::AbstractStore)
Base.empty!(::AbstractStore)
Base.pairs(::AbstractStore)
Base.lock(::Any, ::AbstractStore)
```

### Traits

```@docs
AbstractStores.supportsttl
AbstractStores.supportslisting
AbstractStores.isatomic
AbstractStores.extensionloaded
```

## Backends

```@docs
MemoryStore
FileStore
PrefixedStore
SQLStore
RedisStore
ObjectStore
```

## Codecs

```@docs
AbstractStores.AbstractCodec
SerializedCodec
JSONCodec
RawCodec
AbstractStores.encode
AbstractStores.decode
AbstractStores.encodeentry
AbstractStores.canexpire
AbstractStores.Entry
```

## Testing your own store

```@docs
AbstractStores.runstoretests
```

## Internals

Useful when implementing a backend, but not part of the stable surface.

### TTL handling

```@docs
AbstractStores.expiryof
AbstractStores.ttlseconds
AbstractStores.checkttl
```

### Key encoding

```@docs
AbstractStores.encodekey
AbstractStores.decodekey
AbstractStores.checkobjectkey
```

### SQL backend

```@docs
AbstractStores.SQLDialect
AbstractStores.SQLITE
AbstractStores.MYSQL
AbstractStores.POSTGRES
AbstractStores.detectdialect
AbstractStores.createtable!
AbstractStores.likeprefix
```

### Redis backend

```@docs
AbstractStores.globescape
AbstractStores.TOKEN_CHARS
```

### Compare-and-swap

```@docs
AbstractStores.MAX_CAS_ATTEMPTS
AbstractStores.ConcurrencyError
```
