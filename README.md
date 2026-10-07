# dcrmapper

Crawls the Decred network to build a world map displaying every publicly
accessible full node.

Uses <https://ip-api.com/> for IP geolocation.

## Running

```sh
go run . [-testnet] [-listen 127.0.0.1:8111] [-domain localhost]
```

## Development

Common tasks are wrapped in a `Makefile` — run `make help` to list them:

```sh
make run    # build the binary and start the server
make check  # gofmt, go vet, golangci-lint and tests (the pre-commit gate)
```

There is no build step beyond `go build`: the templates and static assets are
embedded into the binary with `go:embed`, so the `dcrmapper` binary that
`make build` produces is self-contained and runs from any directory.

## Frontend

The UI is plain HTML templates (`templates/`) styled by a single hand-authored
stylesheet, [`public/css/app.css`](public/css/app.css) — no CSS framework and no
build step. Light/dark theming is driven by CSS custom properties; just edit the
file directly.
