# AbstractStores.jl

```@meta
CurrentModule = AbstractStores
```

A small, backend-agnostic interface for storing simple state: a library declares
that it needs an `AbstractStore{T}`, and the application decides whether that
lives in a `Dict`, a directory, SQLite, Postgres, Redis, or an S3 bucket.

See the [README](https://github.com/JuliaServices/AbstractStores.jl) for an
overview and the backend comparison table.

## The interface

```@docs
AbstractStore
modify!
sweep!
```

### Traits

```@docs
AbstractStores.supportsttl
AbstractStores.supportslisting
AbstractStores.isatomic
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
AbstractStores.Entry
```

## Testing your own store

```@docs
AbstractStores.runstoretests
```

## Reference

```@autodocs
Modules = [AbstractStores]
Order = [:function, :type, :constant]
Filter = t -> !(t in (AbstractStore, MemoryStore, FileStore, PrefixedStore,
                      SQLStore, RedisStore, ObjectStore, SerializedCodec,
                      JSONCodec, RawCodec, modify!, sweep!))
```
