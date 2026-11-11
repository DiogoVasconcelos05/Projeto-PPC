#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

CONCURRENCIES=(10 100 1000)
RUNTIMES=(Java Go Rust)

REPETITIONS=2
WARMUP_DURATION="5s"
TEST_DURATION="5s"

PAYLOAD_FILE="$PROJECT_DIR/payload_1kb.json"
RESULTS_DIR="$PROJECT_DIR/results_$(date +%Y%m%d_%H%M%S)"

CURRENT_SERVER_PID=""
CURRENT_MONITOR_PID=""
SECONDARY_PID=""
BUILD_DIR=""

cleanup_pid() {
    local pid="$1"

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    cleanup_pid "$CURRENT_MONITOR_PID"
    cleanup_pid "$CURRENT_SERVER_PID"
    cleanup_pid "$SECONDARY_PID"

    if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
        rm -rf -- "$BUILD_DIR"
    fi
}

trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

for command in awk cargo curl date go java oha python3; do
    require_command "$command"
done

check_port_available() {
    local port="$1"

    if ! python3 -c '
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

try:
    sock.bind(("0.0.0.0", port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
' "$port"; then
        printf 'Required benchmark port %s is already in use.\n' "$port" >&2

        if command -v ss >/dev/null 2>&1; then
            ss -ltnp "sport = :$port" >&2 || true
        fi

        printf 'Find the owning process with: sudo fuser -v %s/tcp\n' "$port" >&2
        printf 'Stop that specific process if it is safe, then rerun the benchmark.\n' >&2
        return 1
    fi
}

check_port_available 8080
check_port_available 8081

# Check Cargo version.
CARGO_VERSION="$(cargo --version)"

if [[ "$CARGO_VERSION" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    CARGO_MAJOR="${BASH_REMATCH[1]}"
    CARGO_MINOR="${BASH_REMATCH[2]}"

    if (( CARGO_MAJOR < 1 || (CARGO_MAJOR == 1 && CARGO_MINOR < 85) )); then
        printf 'Cargo 1.85 or newer is required (found %s).\n' "$CARGO_VERSION" >&2
        printf 'Update Rust with: rustup toolchain install stable && rustup default stable\n' >&2
        exit 1
    fi
else
    printf 'Could not determine Cargo version from: %s\n' "$CARGO_VERSION" >&2
    exit 1
fi

# Check file descriptor limit.
OPEN_FILE_LIMIT="$(ulimit -n)"

if [[ "$OPEN_FILE_LIMIT" =~ ^[0-9]+$ ]] && (( OPEN_FILE_LIMIT < 2048 )); then
    printf 'Warning: open-file limit is %s; concurrency 1000 may fail.\n' \
        "$OPEN_FILE_LIMIT" >&2
    printf 'If allowed, run: ulimit -n 4096\n' >&2
fi

mkdir -p "$RESULTS_DIR"

SUMMARY_CSV="$RESULTS_DIR/summary_results.csv"

printf 'lang,concurrency,run,throughput_rps,p95_ms,p99_ms,avg_rss_mb,peak_rss_mb,avg_cpu_cores,peak_cpu_cores\n' \
    > "$SUMMARY_CSV"

# Create the payload if it does not exist.
if [[ ! -f "$PAYLOAD_FILE" ]]; then
    echo "Creating 1KB JSON payload..."

    python3 -c \
        "import json; print(json.dumps({'data': 'x' * 1000}))" \
        > "$PAYLOAD_FILE"
fi

# Check that the monitoring script exists.
if [[ ! -f "$SCRIPT_DIR/monitor_process.py" ]]; then
    echo "Missing monitor_process.py in $SCRIPT_DIR" >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ppc-benchmark.XXXXXX")"

echo "Building Go services..."
go build -o "$BUILD_DIR/secondary-api" services/secondary-api/main.go
go build -o "$BUILD_DIR/main-api-go" services/main-api-go/main.go

echo "Building Rust service in release mode..."
cargo build --release --manifest-path services/main-api-rust/Cargo.toml

echo "=================================================="
echo " Starting comparative benchmark (Java vs Go vs Rust)"
echo "=================================================="

wait_for_api() {
    local attempt

    for attempt in $(seq 1 30); do
        if ! kill -0 "$CURRENT_SERVER_PID" 2>/dev/null; then
            echo "Server process exited before becoming ready." >&2
            return 1
        fi

        if curl --silent --show-error --fail --max-time 2 \
            -H "Content-Type: application/json" \
            --data-binary "@$PAYLOAD_FILE" \
            "http://127.0.0.1:8080/api" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    echo "Server did not become ready at http://127.0.0.1:8080/api." >&2
    return 1
}

start_runtime() {
    local runtime="$1"

    echo "Starting $runtime API..."

    case "$runtime" in
        Java)
            java -XX:+UnlockDiagnosticVMOptions \
                services/main-api-java/Main.java &
            ;;
        Go)
            "$BUILD_DIR/main-api-go" &
            ;;
        Rust)
            services/main-api-rust/target/release/main-api-rust &
            ;;
        *)
            echo "Unknown runtime: $runtime" >&2
            return 1
            ;;
    esac

    CURRENT_SERVER_PID=$!

    wait_for_api
}

stop_runtime() {
    cleanup_pid "$CURRENT_SERVER_PID"
    CURRENT_SERVER_PID=""
    sleep 2
}

run_measurement() {
    local runtime="$1"
    local concurrency="$2"
    local run="$3"

    local rss_log="$RESULTS_DIR/rss_${runtime}_c${concurrency}_run${run}.csv"
    local raw_result metrics
    local rps p95 p99
    local avg_rss peak_rss avg_cpu peak_cpu

    printf '    Run %s/%s\n' "$run" "$REPETITIONS"

    # Start resource monitor for the main API process.
    python3 "$SCRIPT_DIR/monitor_process.py" \
        "$CURRENT_SERVER_PID" "$rss_log" &
    CURRENT_MONITOR_PID=$!

    # Give the monitor time to collect its first samples.
    sleep 0.2

    # Execute the measured test.
    raw_result=$(oha \
        -z "$TEST_DURATION" \
        -c "$concurrency" \
        -m POST \
        -H "Content-Type: application/json" \
        -D "$PAYLOAD_FILE" \
        --output-format json \
        "http://127.0.0.1:8080/api")

    # Stop the monitor and wait for its CSV to be flushed.
    cleanup_pid "$CURRENT_MONITOR_PID"
    CURRENT_MONITOR_PID=""

    # Extract throughput and latency percentiles from oha.
    metrics=$(python3 -c '
import json
import sys

result = json.load(sys.stdin)
summary = result["summary"]
latency = result["latencyPercentiles"]

rps = summary["requestsPerSec"]
p95_ms = latency["p95"] * 1000
p99_ms = latency["p99"] * 1000

print(f"{rps:.6f},{p95_ms:.3f},{p99_ms:.3f}")
' <<< "$raw_result")

    IFS=, read -r rps p95 p99 <<< "$metrics"

    # Calculate average and peak RSS/CPU from monitor samples.
    read -r avg_rss peak_rss avg_cpu peak_cpu < <(
        python3 - "$rss_log" <<'PY'
import csv
import sys

with open(sys.argv[1], newline="") as file:
    rows = list(csv.DictReader(file))

if not rows:
    print("0 0 0 0")
    sys.exit(0)

rss = [float(row["rss_mb"]) for row in rows]
cpu = [float(row["cpu_cores"]) for row in rows]

print(
    f"{sum(rss) / len(rss):.3f}",
    f"{max(rss):.3f}",
    f"{sum(cpu) / len(cpu):.3f}",
    f"{max(cpu):.3f}"
)
PY
    )

    # Append results to the summary CSV.
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$runtime" \
        "$concurrency" \
        "$run" \
        "$rps" \
        "$p95" \
        "$p99" \
        "$avg_rss" \
        "$peak_rss" \
        "$avg_cpu" \
        "$peak_cpu" \
        >> "$SUMMARY_CSV"

    printf '      %s req/s | p95: %sms | p99: %sms\n' \
        "$rps" "$p95" "$p99"

    printf '      RSS avg: %s MB | peak: %s MB\n' \
        "$avg_rss" "$peak_rss"

    printf '      CPU avg: %s cores | peak: %s cores\n' \
        "$avg_cpu" "$peak_cpu"

    sleep 2
}

run_runtime_at_concurrency() {
    local runtime="$1"
    local concurrency="$2"
    local run

    echo ""
    echo "  Runtime: $runtime | Concurrency: $concurrency"

    start_runtime "$runtime"

    echo "    [Warm-up] Running for $WARMUP_DURATION..."

    oha \
        -z "$WARMUP_DURATION" \
        -c "$concurrency" \
        -m POST \
        -H "Content-Type: application/json" \
        -D "$PAYLOAD_FILE" \
        "http://127.0.0.1:8080/api" >/dev/null

    sleep 2

    for run in $(seq 1 "$REPETITIONS"); do
        run_measurement "$runtime" "$concurrency" "$run"
    done

    stop_runtime
}

echo "Starting secondary I/O service on port 8081..."

"$BUILD_DIR/secondary-api" &
SECONDARY_PID=$!

# Test each concurrency level, rotating the runtime order.
for i in "${!CONCURRENCIES[@]}"; do
    concurrency="${CONCURRENCIES[$i]}"

    echo ""
    echo "=================================================="
    printf ' CONCURRENCY LEVEL: %s\n' "$concurrency"
    echo "=================================================="

    # Rotate the runtime order for each concurrency level.
    for offset in 0 1 2; do
        runtime_index=$(( (i + offset) % ${#RUNTIMES[@]} ))
        runtime="${RUNTIMES[$runtime_index]}"

        run_runtime_at_concurrency "$runtime" "$concurrency"
    done
done

cleanup_pid "$SECONDARY_PID"
SECONDARY_PID=""

echo ""
echo "=================================================="
echo " Benchmark complete."
printf ' Results saved in: %s\n' "$SUMMARY_CSV"
echo "=================================================="
