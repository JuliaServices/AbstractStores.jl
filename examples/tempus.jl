# How Tempus.jl would swap its `Store` hierarchy for AbstractStores.
#
# Tempus currently defines:
#
#   abstract type Store end
#       getJobs / addJob! / purgeJob! / disableJob!
#       storeJobExecution! / getNMostRecentJobExecutions
#   InMemoryStore   -- Set{Job} + Dict{String,Vector{JobExecution}} + a lock
#   FileStore       -- InMemoryStore + a whole-file JSON rewrite on every mutation;
#                      execution history is NOT persisted
#   SQLiteStore     -- InMemoryStore as a cache + hand-written SQL
#
# The shape underneath is two key-value collections: jobs by name, and a bounded
# execution history per job name. Both map onto `AbstractStore` directly, and the
# three backends collapse into "whichever store the caller passed".
#
# Two things Tempus gains beyond deleting code:
#
#   * `FileStore` persists execution history too, because there is no longer a
#     reason for it not to — history is just another store.
#   * The single-file JSON rewrite becomes a per-key atomic write, so a crash
#     mid-save can no longer lose every job at once.

module TempusStores

using Dates, AbstractStores

# ---------------------------------------------------------------------------
# Stand-ins for the Tempus types, so this example runs on its own.
# ---------------------------------------------------------------------------

struct JobOptions
    retries::Int
    max_executions::Union{Nothing,Int}
end
JobOptions(; retries=0, max_executions=nothing) = JobOptions(retries, max_executions)

struct Job
    name::String
    action_ref::String
    schedule::Union{Nothing,String}
    options::JobOptions
    disabledAt::Union{Nothing,DateTime}
end
Job(name, action_ref, schedule; options=JobOptions(), disabledAt=nothing) =
    Job(name, action_ref, schedule, options, disabledAt)

struct JobExecution
    jobName::String
    runAt::DateTime
    status::Symbol
end

# ---------------------------------------------------------------------------
# The scheduler now holds two stores instead of one bespoke `Store`.
#
# Note the types: Tempus states what it needs (`Job`s by name, and a history list
# per job) and stays out of the persistence question entirely.
# ---------------------------------------------------------------------------

struct Scheduler{J<:AbstractStore{Job},E<:AbstractStore{Vector{JobExecution}}}
    jobs::J
    executions::E
    history_limit::Int
end

Scheduler(jobs, executions; history_limit::Int=100) =
    Scheduler(jobs, executions, history_limit)

"""
    Scheduler(backend; history_limit=100)

Derive both stores from one backend by namespacing.  A caller gets an in-memory
scheduler with `MemoryStore{Any}()`, a persistent one with
`FileStore{Any}(dir; codec=JSONCodec())`, and a multi-process one with
`SQLStore{Any}(conn)` — with no further changes to Tempus.
"""
Scheduler(backend::AbstractStore; history_limit::Int=100) =
    Scheduler(PrefixedStore{Job}(backend, "jobs/"),
              PrefixedStore{Vector{JobExecution}}(backend, "executions/"),
              history_limit)

# ---------------------------------------------------------------------------
# The Store interface, reimplemented against AbstractStores.
# Every method below was previously written three times, once per backend.
# ---------------------------------------------------------------------------

getJobs(s::Scheduler) = [s.jobs[name] for name in keys(s.jobs)]

addJob!(s::Scheduler, job::Job) = (put!(s.jobs, job.name, job); job)

function purgeJob!(s::Scheduler, job::Union{Job,AbstractString})
    name = job isa Job ? job.name : String(job)
    delete!(s.jobs, name)
    delete!(s.executions, name)   # history goes with the job
    return nothing
end

# Read-modify-write on a stored value: exactly what `modify!` is for. Tempus's
# InMemoryStore did this under its own lock; here the store supplies the
# atomicity, and on an `isatomic` backend it holds across processes too.
function disableJob!(s::Scheduler, job::Union{Job,AbstractString};
                     at::DateTime=Dates.now(UTC))
    name = job isa Job ? job.name : String(job)
    modify!(s.jobs, name) do old
        old === nothing ? nothing :
            Job(old.name, old.action_ref, old.schedule, old.options, at)
    end
end

"""
    storeJobExecution!(scheduler, execution)

Prepend an execution to its job's history, truncated to `history_limit`.

The whole read-append-truncate-write is one `modify!`, so concurrent executions
of the same job cannot clobber each other's history — the failure mode the old
`Dict{String,Vector{JobExecution}}` avoided only by holding a process-local lock.
"""
function storeJobExecution!(s::Scheduler, execution::JobExecution)
    modify!(s.executions, execution.jobName) do old
        history = old === nothing ? JobExecution[] : copy(old)
        pushfirst!(history, execution)
        return length(history) > s.history_limit ? history[1:s.history_limit] : history
    end
    return execution
end

function getNMostRecentJobExecutions(s::Scheduler, jobName::AbstractString, n::Int)
    n <= 0 && return JobExecution[]
    history = get(s.executions, jobName, nothing)
    history === nothing && return JobExecution[]
    return history[1:min(n, length(history))]
end

# ---------------------------------------------------------------------------
# What the interface makes newly possible
# ---------------------------------------------------------------------------

"""
    claim!(scheduler, jobName, worker; lease=Minute(5)) -> Bool

Try to become the process that runs `jobName` right now.  Returns `true` to
exactly one caller until the lease expires.

Tempus cannot express this today: its stores are process-local, so two schedulers
pointed at the same job list both fire every job.  With an atomic, TTL-capable
store this is four lines, and `Tempus` gains multi-process scheduling without
knowing whether the lease lives in Redis or Postgres.
"""
function claim!(s::Scheduler, jobName::AbstractString, worker::AbstractString,
                leases::AbstractStore{String}; lease=Dates.Minute(5))
    AbstractStores.isatomic(leases) || throw(ArgumentError(
        "job leases require an atomic store; `AbstractStores.isatomic($(typeof(leases)))` is false"))
    return get!(leases, jobName, worker; ttl=lease) == worker
end

end # module
