# Mission

Add a `/healthz` endpoint that reports service health including database
connectivity and cache availability, for use by Kubernetes liveness probes.

## Definition of Done

- `GET /healthz` returns 200 with `{"status": "ok", "checks": {...}}` when healthy
- Returns 503 with details when any dependency is unreachable
- Each dependency check has a 2-second timeout so the probe stays fast
- Endpoint is excluded from authentication middleware
- New tests cover healthy, degraded, and fully-down scenarios

## Verifier Commands

```bash
# Fast check
go test ./internal/health/... -run TestHealth -count=1

# Full check
go test ./... -race -count=1 && golangci-lint run
```

## Context

- Framework is Chi router; register the route in `internal/router/router.go`
- Database pool is in `internal/db/pool.go`; Redis client in `internal/cache/redis.go`
- Follow existing patterns in `internal/` for new packages
