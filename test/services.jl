# Ephemeral backing services for the backend tests, via Harbor.jl.
#
# Each `with_*` helper starts a container, waits for it to be genuinely ready
# (Harbor's wait strategy *and* a real client connection), hands a live
# connection to the block, and tears the container down afterwards — including
# on error.
#
# Image refs are overridable so CI can pin digests:
#   ABSTRACTSTORES_POSTGRES_IMAGE, ABSTRACTSTORES_MYSQL_IMAGE, ABSTRACTSTORES_REDIS_IMAGE

using Sockets, Harbor, DBInterface

const POSTGRES_IMAGE = get(ENV, "ABSTRACTSTORES_POSTGRES_IMAGE", "postgres:16")
const MYSQL_IMAGE = get(ENV, "ABSTRACTSTORES_MYSQL_IMAGE", "mysql:8")
const REDIS_IMAGE = get(ENV, "ABSTRACTSTORES_REDIS_IMAGE", "redis:7")

const PG_USER, PG_PASSWORD, PG_DB = "postgres", "postgres", "abstractstores_test"
const MY_USER, MY_PASSWORD, MY_DB = "root", "", "abstractstores_test"

function parse_image_ref(ref::AbstractString)
    colon = findlast(':', ref)
    slash = findlast('/', ref)
    if colon !== nothing && (slash === nothing || colon > slash)
        return String(ref[begin:prevind(ref, colon)]), String(ref[nextind(ref, colon):end])
    end
    return String(ref), "latest"
end

"""
    docker_available() -> Bool

Whether a Docker daemon that can run **Linux** containers is reachable.

The OS check is the load-bearing part: a Windows runner has the `docker` CLI and
a responsive daemon, but in Windows-container mode, so `docker pull mysql:8`
fails partway through the test run rather than up front.  Asking the daemon what
it runs turns that into a clean skip.
"""
function docker_available()
    Sys.which("docker") === nothing && return false
    try
        ostype = read(`docker info --format "{{.OSType}}"`, String)
        return strip(ostype) == "linux"
    catch
        return false
    end
end

function pick_port()
    server = Sockets.listen(Sockets.IPv4(0), 0)
    _, port = Sockets.getsockname(server)
    close(server)
    return Int(port)
end

"""
    retry_connect(f; timeout=90, interval=0.5)

Poll `f()` until it returns a connection or `timeout` seconds elapse.

Harbor's wait strategies tell us the port is open or the log line appeared;
neither means the server will accept a client yet.  Postgres in particular logs
"ready to accept connections" once during init and again for real, so a genuine
connection attempt is the only reliable readiness signal.
"""
function retry_connect(f; timeout::Real=90, interval::Real=0.5)
    deadline = time() + timeout
    last_err = nothing
    while time() < deadline
        try
            return f()
        catch err
            last_err = err
            sleep(interval)
        end
    end
    error("service did not become ready within $(timeout)s: ",
          last_err === nothing ? "no attempt made" : sprint(showerror, last_err))
end

"""
    with_postgres(f)

Run `f(conn)` against a throwaway Postgres container.
"""
function with_postgres(f::Function)
    image, tag = parse_image_ref(POSTGRES_IMAGE)
    port = pick_port()
    Harbor.with_container(image; tag,
            ports=Dict(5432 => port),
            environment=Dict("POSTGRES_USER" => PG_USER,
                             "POSTGRES_PASSWORD" => PG_PASSWORD,
                             "POSTGRES_DB" => PG_DB),
            wait_strategy=(port=5432,),
            wait_timeout=120.0,
            container_logs_on_error=true) do _
        conn = retry_connect() do
            DBInterface.connect(Postgres.Connection, "127.0.0.1", PG_USER, PG_PASSWORD;
                                dbname=PG_DB, port=port, connect_timeout=2)
        end
        try
            return f(conn)
        finally
            DBInterface.close!(conn)
        end
    end
end

"""
    with_mysql(f)

Run `f(conn)` against a throwaway MySQL container.
"""
function with_mysql(f::Function)
    image, tag = parse_image_ref(MYSQL_IMAGE)
    port = pick_port()
    Harbor.with_container(image; tag,
            ports=Dict(3306 => port),
            environment=Dict("MYSQL_ALLOW_EMPTY_PASSWORD" => "yes",
                             "MYSQL_DATABASE" => MY_DB),
            wait_strategy=(port=3306,),
            wait_timeout=180.0,
            container_logs_on_error=true) do _
        conn = retry_connect(; timeout=180) do
            DBInterface.connect(MySQL.Connection, "127.0.0.1", MY_USER, MY_PASSWORD;
                                db=MY_DB, port=port)
        end
        try
            return f(conn)
        finally
            DBInterface.close!(conn)
        end
    end
end

"""
    with_redis(f)

Run `f(client)` against a throwaway Redis container.
"""
function with_redis(f::Function)
    image, tag = parse_image_ref(REDIS_IMAGE)
    port = pick_port()
    Harbor.with_container(image; tag,
            ports=Dict(6379 => port),
            wait_strategy=(pattern="Ready to accept connections",),
            wait_timeout=120.0,
            container_logs_on_error=true) do _
        client = retry_connect() do
            c = Redis.connect("127.0.0.1", port)
            Redis.execute(c, Redis.Commands.Command{String}("*1\r\n\$4\r\nPING\r\n"))
            c
        end
        try
            return f(client)
        finally
            close(client)
        end
    end
end
