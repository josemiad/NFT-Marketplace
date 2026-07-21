# NFT Marketplace

A non-custodial ERC-721 marketplace built with Foundry. Sellers list directly from their own wallet — the NFT
never leaves the seller's custody until the moment of sale — and buyers pay in ETH or an ERC-20 token.
ERC-2981 royalties are paid out automatically on every sale when the NFT supports the standard.

## Features

- **List, buy, unpublish** — `publishNFT`, `buyNFT`, `unpublishNFT`.
- **ETH or ERC-20 payments** — a listing defaults to ETH; pass a token address to `publishNFT` to price it in
  that ERC-20 instead. `buyNFT` doesn't change — it reads the listing's payment token and settles accordingly.
- **ERC-2981 royalties** — if the listed NFT implements `IERC2981`, the royalty split is paid to the receiver
  automatically; if it doesn't (or misbehaves), the full price goes to the seller. The check is defensive by
  design: a non-compliant, reverting, or hostile NFT contract can never block a sale or drain funds — see
  `_royaltyInfo` in `src/NFTMarketplace.sol`.
- **Reentrancy-guarded** — every state-changing function uses OpenZeppelin's `ReentrancyGuard`.

## Project layout

```
src/NFTMarketplace.sol       the marketplace contract
test/NFTMarketplace.t.sol    unit, fuzz, and characterization tests
test/mocks/Mocks.sol         mock NFTs/ERC-20 used only by the test suite
script/DeployNFTMarketplace.s.sol   forge script for deployment
```

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (developed against `forge 1.7.1`)

## Setup

```shell
git clone --recurse-submodules <this-repo>
cd nft-marketplace
forge build
```

If you already cloned without `--recurse-submodules`:

```shell
git submodule update --init --recursive
```

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

24 tests: unit tests per function, revert-path characterization tests, and fuzz tests for both the ETH and
ERC-20 buy paths. `src/NFTMarketplace.sol` sits at 100% line/statement/branch/function coverage.

### Coverage

```shell
forge coverage --report summary
```

### Format

```shell
forge fmt
```

### Gas snapshot

```shell
forge snapshot
```

CI fails the build on any gas regression against the committed `.gas-snapshot`.

### Deploy

```shell
forge script script/DeployNFTMarketplace.s.sol:DeployNFTMarketplace \
  --rpc-url <your_rpc_url> \
  --private-key <your_private_key> \
  --broadcast --verify
```

## CI

Every push/PR runs, in order: `forge fmt --check`, `forge build --sizes`, `forge test -vvv`,
`forge snapshot --check`, and a coverage-floor gate (fails below 90% line coverage). See
`.github/workflows/test.yml`.

## License

MIT
