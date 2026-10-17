# Build identity

Every Rupert web layout displays `Build <12-character commit>` in its header. Every HTTP response through Rails, including health checks, redirects and downloads, includes `X-Rupert-Build` with the full commit. The value is loaded once at application boot, so a checkout change cannot make an old running process claim the new release. Restart web and job services after promotion.

Git deployments use the actual checkout revision. Git-free releases can supply `RUPERT_BUILD_SHA` or package `web/config/build.json` with a full `revision` and optional ISO 8601 `built_at`. Missing metadata displays `unversioned` explicitly; invalid values cannot enter response headers. `RUPERT_BUILT_AT` optionally displays a UTC build timestamp.

Docker builds require the full source revision and persist it inside the image:

```sh
docker build --build-arg RUPERT_BUILD_SHA="$(git rev-parse HEAD)" --build-arg RUPERT_BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -t rupert .
```

After deployment, compare the public `/up` and `/login` response headers with the intended release SHA, then verify the visible header after login. A stale process is a failed promotion even if its health endpoint returns 200. Static files served outside Rails do not carry this application header.
