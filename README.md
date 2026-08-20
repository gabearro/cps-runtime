# cps-runtime

Continuation-passing-style async runtime, event loop, I/O, concurrency, and multi-threaded scheduler for Nim.

## Install

```sh
nimble install https://github.com/gabearro/cps-runtime@#v1.0.0
```

```nim
import cps
```

## Development

```sh
nimble install -d -y
nimble test
```

## CPS ecosystem

The former monorepo has been split into independently versioned Nimble packages:

| Area | Repository |
| --- | --- |
| TLS | [cps-tls](https://github.com/gabearro/cps-tls) |
| QUIC | [cps-quic](https://github.com/gabearro/cps-quic) |
| HTTP clients and servers | [cps-http](https://github.com/gabearro/cps-http) |
| IRC | [cps-irc](https://github.com/gabearro/cps-irc) |
| IRC bouncer | [cps-irc-bouncer](https://github.com/gabearro/cps-irc-bouncer) |
| BitTorrent | [cps-bittorrent](https://github.com/gabearro/cps-bittorrent) |
| Terminal UI | [cps-tui](https://github.com/gabearro/cps-tui) |
| Web UI | [cps-web-ui](https://github.com/gabearro/cps-web-ui) |
| Native GUI | [cps-native-gui](https://github.com/gabearro/cps-native-gui) |
| WebAssembly VM | [cps-wasm](https://github.com/gabearro/cps-wasm) |

Application repositories are [cps-irc-app](https://github.com/gabearro/cps-irc-app),
[cps-torrent-app](https://github.com/gabearro/cps-torrent-app), and
[cps-clipbook](https://github.com/gabearro/cps-clipbook).

The complete pre-split tree is retained on the `monorepo-archive` branch.

## License

MIT
