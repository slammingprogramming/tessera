# Third-party material

Tessera itself is [AGPL-3.0-or-later](LICENSE). The only third-party code in the repository is listed here.

| Where | What | License |
|---|---|---|
| `tests/lib/ref_lib32vid.lua` | `lib32vid.lua` from [sanjuuni](https://github.com/MCJack123/sanjuuni) by JackMacWindows, used unmodified as a test oracle for the 32vid decoder (`tsr.media.vid32`). It is not installed on any computer. | MIT, Copyright (c) 2025 JackMacWindows (full notice at the top of the file) |

Other things worth knowing:

- Tessera's crypto, DEFLATE, tar, diff, TCP/IP, TLS-like channel, ssh, pgp and the other protocol code are written from the public specifications (RFCs, the
  Ed25519/X25519/ChaCha20 papers and so on), not copied from other projects. Test vectors and cross-check fixtures were produced with OpenSSL, Node.js and
  git; only the generated data is stored (`tests/fixtures/`).
- Mod integration drivers (Advanced Peripherals, Mekanism, Create / CC:C Bridge, Tom's Peripherals) were written after reading the mods' public
  documentation and source to get the peripheral names and units right; no mod code is included.
- Packages in a registry that are not part of this repository declare their own license (`pkg info` shows it).
