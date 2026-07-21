# ERC-2981 Royalties, ERC-20 Payments & Tooling Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `NFTMarketplace` to pay ERC-2981 royalties on every sale, accept ERC-20 tokens as an alternative to ETH, and lock in the project's process/tooling gates (gas snapshots, a deployment script, and a CI coverage floor).

**Architecture:** Three independent phases, each self-contained and independently testable:
- **Phase A** adds royalty splitting to the existing ETH-only `buyNFT` path via a defensive internal helper (`_royaltyInfo`) that never trusts the NFT contract's return values.
- **Phase B** adds an optional ERC-20 payment token per listing (`address(0)` = ETH), keeping the 3-argument `publishNFT` working unchanged via function overloading, and branches `buyNFT` on the listing's payment token.
- **Phase C** adds CI/tooling: a gas snapshot check, a `forge script` deployment script, and a coverage-floor gate in CI.

**Tech Stack:** Foundry 1.7.1 (forge/forge-std), Solidity ^0.8.34, OpenZeppelin Contracts v5.4.0 (already vendored under `lib/openzeppelin-contracts`, no new dependency).

## Global Constraints

- Do not change the `pragma solidity ^0.8.34;` line.
- No new dependencies — only the already-vendored `lib/openzeppelin-contracts` and `lib/forge-std`.
- Match existing style: `require(condition, "message")` reverts, not custom errors.
- Every commit must pass `forge fmt --check` — run `forge fmt` before committing.
- Preserve the non-custodial design: the marketplace must never hold buyer funds or the NFT at rest — payment goes directly buyer → (royalty receiver, seller); the NFT stays with the seller until the moment of sale.
- After each task, `forge test` must show all tests passing and `forge coverage --report summary` must show 100% line/branch coverage on `src/NFTMarketplace.sol` before moving to the next task.

---

## Phase A: ERC-2981 Royalty Support

### Task 1: Extract test mocks into their own file

**Files:**
- Create: `test/mocks/Mocks.sol`
- Modify: `test/NFTMarketplace.t.sol:1-28` (remove inline mock definitions, import the new file)

**Interfaces:**
- Produces: `MockNFT` (unchanged, `mint(address,uint256)`), `RejectEther` (unchanged) — both now live in `test/mocks/Mocks.sol` instead of inline in the test file.

This is a pure refactor (no behavior change) to keep `NFTMarketplace.t.sol` focused on test cases as we add more mock contracts in later tasks.

- [ ] **Step 1: Create `test/mocks/Mocks.sol` with the two existing mocks moved out verbatim**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "../../lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("Mock NFT", "MNFT") {}

    function mint(address to_, uint256 tokenId_) external {
        _mint(to_, tokenId_);
    }
}

// Contract designed to fail whenever Ether is sent to it
contract RejectEther {
    // Reverting inside receive() forces .call{value: ...}("") to return success = false
    receive() external payable {
        revert("I refuse money");
    }
}
```

- [ ] **Step 2: Remove the inline `MockNFT` and `RejectEther` definitions from `test/NFTMarketplace.t.sol` and import the mocks file instead**

Replace lines 7-27 (the two `import` lines plus the `MockNFT` and `RejectEther` contract bodies) with:

```solidity
import "forge-std/Test.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import "../src/NFTMarketplace.sol";
import "./mocks/Mocks.sol";
```

- [ ] **Step 3: Run the full test suite to confirm nothing broke**

Run: `forge test`
Expected: `Ran 11 tests for test/NFTMarketplace.t.sol:NFTMarketplaceTest` ... `11 passed; 0 failed`

- [ ] **Step 4: Commit**

```bash
git add test/mocks/Mocks.sol test/NFTMarketplace.t.sol
git commit -m "test: extract mock contracts into test/mocks/Mocks.sol"
```

---

### Task 2: Split sale proceeds with the NFT's ERC-2981 royalty (happy path)

**Files:**
- Modify: `src/NFTMarketplace.sol` (imports, `buyNFT`, new `_royaltyInfo` helper, new event)
- Modify: `test/mocks/Mocks.sol` (add `MockNFT2981`)
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `NFTMarketplace._royaltyInfo(address nftAddress_, uint256 tokenId_, uint256 salePrice_) internal view returns (address receiver, uint256 royaltyAmount)` — Task 4 will extend this function's body (same signature). `event RoyaltyPaid(address indexed nftAddress_, uint256 indexed tokenId_, address indexed receiver_, uint256 amount_)`.

- [ ] **Step 1: Add `MockNFT2981` to `test/mocks/Mocks.sol`**

Add this import at the top of `test/mocks/Mocks.sol`:

```solidity
import "../../lib/openzeppelin-contracts/contracts/token/common/ERC2981.sol";
```

Add this contract to `test/mocks/Mocks.sol`:

```solidity
contract MockNFT2981 is ERC721, ERC2981 {
    constructor() ERC721("Mock Royalty NFT", "MRNFT") {}

    function mint(address to_, uint256 tokenId_) external {
        _mint(to_, tokenId_);
    }

    function setDefaultRoyalty(address receiver_, uint96 feeNumerator_) external {
        _setDefaultRoyalty(receiver_, feeNumerator_);
    }

    function supportsInterface(bytes4 interfaceId_) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId_);
    }
}
```

- [ ] **Step 2: Write the failing test in `test/NFTMarketplace.t.sol`**

Add near the other buy tests:

```solidity
    // #### Test Royalties ####
    function testBuyNFTSplitsRoyaltyToReceiver() public {
        MockNFT2981 royaltyNFT = new MockNFT2981();
        address royaltyReceiver = vm.addr(4);
        royaltyNFT.mint(sellerAddr, tokenId);
        royaltyNFT.setDefaultRoyalty(royaltyReceiver, 1000); // 10% (basis points out of 10000)

        vm.startPrank(sellerAddr);
        royaltyNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(royaltyNFT), tokenId, price);
        vm.stopPrank();

        uint256 sellerBalanceBefore = sellerAddr.balance;
        uint256 royaltyBalanceBefore = royaltyReceiver.balance;

        vm.deal(buyerAddr, price);
        vm.prank(buyerAddr);
        marketplace.buyNFT{value: price}(address(royaltyNFT), tokenId);

        uint256 expectedRoyalty = (price * 1000) / 10000;
        assertEq(royaltyReceiver.balance, royaltyBalanceBefore + expectedRoyalty);
        assertEq(sellerAddr.balance, sellerBalanceBefore + price - expectedRoyalty);
        assertEq(royaltyNFT.ownerOf(tokenId), buyerAddr);
    }

    function testBuyNFTWithoutRoyaltySupportPaysFullPriceToSeller() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(sellerAddr);
        mockedNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        vm.stopPrank();

        uint256 sellerBalanceBefore = sellerAddr.balance;

        vm.deal(buyerAddr, price);
        vm.prank(buyerAddr);
        marketplace.buyNFT{value: price}(address(mockedNFT), tokenId);

        assertEq(sellerAddr.balance, sellerBalanceBefore + price);
    }
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `forge test --match-test "testBuyNFTSplitsRoyaltyToReceiver|testBuyNFTWithoutRoyaltySupportPaysFullPriceToSeller" -vv`
Expected: `testBuyNFTSplitsRoyaltyToReceiver` FAILs (`assertEq` mismatch — the full `price` currently goes to the seller with no split). `testBuyNFTWithoutRoyaltySupportPaysFullPriceToSeller` currently PASSes (already true) — that's fine, it's a regression guard for the change about to be made.

- [ ] **Step 4: Add the royalty split to `src/NFTMarketplace.sol`**

Add these imports after the existing `IERC721` import:

```solidity
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC2981.sol";
import "../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
```

Add this event after `NFTSold`:

```solidity
    event RoyaltyPaid(address indexed nftAddress_, uint256 indexed tokenId_, address indexed receiver_, uint256 amount_);
```

Replace the body of `buyNFT` with:

```solidity
    function buyNFT(address nftAddress_, uint256 tokenId_) external payable nonReentrant {
        NFTList memory nftParameters = listing[nftAddress_][tokenId_];
        require(nftParameters.price > 0, "The NFT does not exist");
        require(msg.value == nftParameters.price, "Incorrect price");

        delete listing[nftAddress_][tokenId_];

        (address royaltyReceiver, uint256 royaltyAmount) = _royaltyInfo(nftAddress_, tokenId_, nftParameters.price);
        uint256 sellerAmount = nftParameters.price - royaltyAmount;

        if (royaltyAmount > 0) {
            (bool royaltySuccess,) = royaltyReceiver.call{value: royaltyAmount}("");
            require(royaltySuccess, "Fail the royalty payment process");
            emit RoyaltyPaid(nftAddress_, tokenId_, royaltyReceiver, royaltyAmount);
        }

        (bool success,) = nftParameters.seller.call{value: sellerAmount}("");
        require(success, "Fail the payment process");

        IERC721(nftAddress_).safeTransferFrom(nftParameters.seller, msg.sender, tokenId_);

        emit NFTSold(msg.sender, nftParameters.seller, nftAddress_, tokenId_, nftParameters.price);
    }
```

Add this helper at the bottom of the contract, just above the closing `}`:

```solidity
    function _royaltyInfo(address nftAddress_, uint256 tokenId_, uint256 salePrice_)
        internal
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        try IERC165(nftAddress_).supportsInterface(type(IERC2981).interfaceId) returns (bool supported) {
            if (!supported) return (address(0), 0);
        } catch {
            return (address(0), 0);
        }

        try IERC2981(nftAddress_).royaltyInfo(tokenId_, salePrice_) returns (address r, uint256 amount) {
            if (r == address(0) || amount == 0) return (address(0), 0);
            return (r, amount);
        } catch {
            return (address(0), 0);
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `forge test --match-test "testBuyNFTSplitsRoyaltyToReceiver|testBuyNFTWithoutRoyaltySupportPaysFullPriceToSeller" -vv`
Expected: both PASS.

- [ ] **Step 6: Run the full suite and check coverage**

Run: `forge test && forge coverage --report summary`
Expected: all tests pass; `src/NFTMarketplace.sol` coverage drops to roughly 88% lines / 81% branches — that's expected at this point, not a bug. Four spots in `_royaltyInfo`/`buyNFT` aren't exercised yet: the royalty-payment-failure `require` (closed by Task 3), the `r == address(0) || amount == 0` early return (closed by Task 4, once the price cap is added), and the two `catch` blocks in `_royaltyInfo` (closed by Task 5).

- [ ] **Step 7: Commit**

```bash
git add src/NFTMarketplace.sol test/mocks/Mocks.sol test/NFTMarketplace.t.sol
git commit -m "feat: pay ERC-2981 royalties on sale, splitting proceeds with the seller"
```

---

### Task 3: Characterize royalty-payment failure (whole sale reverts)

**Files:**
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: `RoyaltyPaid` event and `buyNFT` revert message `"Fail the royalty payment process"` from Task 2. No production code changes in this task — it documents behavior Task 2 already implements.

- [ ] **Step 1: Write the test**

```solidity
    function testBuyNFTRoyaltyPaymentFailedReverts() public {
        MockNFT2981 royaltyNFT = new MockNFT2981();
        royaltyNFT.mint(sellerAddr, tokenId);
        royaltyNFT.setDefaultRoyalty(address(rejectEtherAddress), 1000);

        vm.startPrank(sellerAddr);
        royaltyNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(royaltyNFT), tokenId, price);
        vm.stopPrank();

        vm.deal(buyerAddr, price);
        vm.startPrank(buyerAddr);
        vm.expectRevert("Fail the royalty payment process");
        marketplace.buyNFT{value: price}(address(royaltyNFT), tokenId);
        vm.stopPrank();
    }
```

- [ ] **Step 2: Run it**

Run: `forge test --match-test testBuyNFTRoyaltyPaymentFailedReverts -vv`
Expected: PASS (Task 2's `require(royaltySuccess, "Fail the royalty payment process")` already causes this revert).

- [ ] **Step 3: Commit**

```bash
git add test/NFTMarketplace.t.sol
git commit -m "test: characterize revert when royalty payment fails"
```

---

### Task 4: Cap royalty amounts that exceed the sale price

**Files:**
- Modify: `src/NFTMarketplace.sol:_royaltyInfo`
- Modify: `test/mocks/Mocks.sol` (add `MaliciousRoyaltyNFT`)
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: `_royaltyInfo` from Task 2 (same signature, this task adds one guard clause to its body).

A hostile or buggy NFT contract could report `royaltyAmount > salePrice`, which would underflow `sellerAmount = price - royaltyAmount` and revert the whole sale (a griefing vector: any listed NFT from that contract becomes permanently unbuyable). This task makes the marketplace ignore royalty info it can't trust instead of trusting arbitrary external input.

- [ ] **Step 1: Add `MaliciousRoyaltyNFT` to `test/mocks/Mocks.sol`**

Add these imports at the top of `test/mocks/Mocks.sol`:

```solidity
import "../../lib/openzeppelin-contracts/contracts/interfaces/IERC2981.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
```

Add this contract:

```solidity
// Reports a royalty larger than the sale price, on purpose, to test the marketplace's guard
contract MaliciousRoyaltyNFT is ERC721, IERC2981 {
    constructor() ERC721("Malicious", "MAL") {}

    function mint(address to_, uint256 tokenId_) external {
        _mint(to_, tokenId_);
    }

    function royaltyInfo(uint256, uint256 salePrice_) external pure returns (address, uint256) {
        return (address(0xBEEF), salePrice_ * 2);
    }

    function supportsInterface(bytes4 interfaceId_) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId_ == type(IERC2981).interfaceId || super.supportsInterface(interfaceId_);
    }
}
```

- [ ] **Step 2: Write the failing test**

```solidity
    function testBuyNFTIgnoresRoyaltyExceedingPrice() public {
        MaliciousRoyaltyNFT maliciousNFT = new MaliciousRoyaltyNFT();
        maliciousNFT.mint(sellerAddr, tokenId);

        vm.startPrank(sellerAddr);
        maliciousNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(maliciousNFT), tokenId, price);
        vm.stopPrank();

        uint256 sellerBalanceBefore = sellerAddr.balance;

        vm.deal(buyerAddr, price);
        vm.prank(buyerAddr);
        marketplace.buyNFT{value: price}(address(maliciousNFT), tokenId);

        assertEq(sellerAddr.balance, sellerBalanceBefore + price);
        assertEq(maliciousNFT.ownerOf(tokenId), buyerAddr);
    }
```

- [ ] **Step 3: Run it to verify it fails**

Run: `forge test --match-test testBuyNFTIgnoresRoyaltyExceedingPrice -vv`
Expected: FAIL — the call reverts with a panic (arithmetic underflow) because `_royaltyInfo` currently returns `royaltyAmount = price * 2`, larger than `price`.

- [ ] **Step 4: Add the cap to `_royaltyInfo` in `src/NFTMarketplace.sol`**

Change:

```solidity
        try IERC2981(nftAddress_).royaltyInfo(tokenId_, salePrice_) returns (address r, uint256 amount) {
            if (r == address(0) || amount == 0) return (address(0), 0);
            return (r, amount);
        } catch {
```

to:

```solidity
        try IERC2981(nftAddress_).royaltyInfo(tokenId_, salePrice_) returns (address r, uint256 amount) {
            if (r == address(0) || amount == 0 || amount > salePrice_) return (address(0), 0);
            return (r, amount);
        } catch {
```

- [ ] **Step 5: Run it to verify it passes, then run the full suite**

Run: `forge test`
Expected: all tests pass, including `testBuyNFTIgnoresRoyaltyExceedingPrice`.

- [ ] **Step 6: Commit**

```bash
git add src/NFTMarketplace.sol test/mocks/Mocks.sol test/NFTMarketplace.t.sol
git commit -m "fix: ignore ERC-2981 royalty amounts that exceed the sale price"
```

---

### Task 5: Cover `_royaltyInfo`'s two `catch` branches

**Files:**
- Modify: `test/mocks/Mocks.sol` (add `NoERC165NFT` and `RevertingRoyaltyNFT`)
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: `_royaltyInfo` from Tasks 2 and 4 (no further changes to its body — this task only adds test coverage for branches it already contains).

After Task 4, `forge coverage --report summary` still doesn't show 100% branches on `src/NFTMarketplace.sol`. Two branches inside `_royaltyInfo` are still never exercised by any mock so far:
- The `catch` on `IERC165(nftAddress_).supportsInterface(...)` (`src/NFTMarketplace.sol:90-91`) — only fires for an NFT contract that doesn't implement ERC-165 at all, so the call reverts outright. `MockNFT` (plain OpenZeppelin `ERC721`) always answers `supportsInterface` without reverting, so it never hits this.
- The `catch` on `IERC2981(nftAddress_).royaltyInfo(...)` (`src/NFTMarketplace.sol:97-98`) — only fires for a contract that claims ERC-2981 support via `supportsInterface` but then reverts inside `royaltyInfo` itself. No existing mock does that.

This task adds one mock for each and a test proving the marketplace falls back to "no royalty, full price to seller" instead of reverting the whole sale in both cases — exactly the defensive behavior `_royaltyInfo`'s `try/catch` structure is there for.

- [ ] **Step 1: Add `NoERC165NFT` to `test/mocks/Mocks.sol`**

This is a minimal, hand-rolled ERC-721-like contract that deliberately has no `supportsInterface` function and no fallback, so calling it reverts (the EVM's default behavior for an unrecognized selector with no fallback). It implements just enough of ERC-721 for `NFTMarketplace` to work: `ownerOf`, `approve`, and `safeTransferFrom`.

```solidity
// Deliberately does not implement ERC-165 at all — calling supportsInterface on it reverts,
// exercising the outer catch in NFTMarketplace._royaltyInfo
contract NoERC165NFT {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _tokenApprovals;

    function mint(address to_, uint256 tokenId_) external {
        _owners[tokenId_] = to_;
    }

    function ownerOf(uint256 tokenId_) external view returns (address) {
        return _owners[tokenId_];
    }

    function approve(address to_, uint256 tokenId_) external {
        require(msg.sender == _owners[tokenId_], "Not owner");
        _tokenApprovals[tokenId_] = to_;
    }

    function safeTransferFrom(address from_, address to_, uint256 tokenId_) external {
        require(_owners[tokenId_] == from_, "Not owner");
        require(msg.sender == from_ || msg.sender == _tokenApprovals[tokenId_], "Not authorized");
        _owners[tokenId_] = to_;
        delete _tokenApprovals[tokenId_];
    }
}
```

- [ ] **Step 2: Add `RevertingRoyaltyNFT` to `test/mocks/Mocks.sol`**

This one does implement ERC-165 and claims ERC-2981 support, but its `royaltyInfo` always reverts — modeled directly on `MaliciousRoyaltyNFT` from Task 4.

```solidity
// Claims ERC-2981 support via supportsInterface, but reverts inside royaltyInfo itself,
// exercising the inner catch in NFTMarketplace._royaltyInfo
contract RevertingRoyaltyNFT is ERC721, IERC2981 {
    constructor() ERC721("Reverting Royalty", "RRN") {}

    function mint(address to_, uint256 tokenId_) external {
        _mint(to_, tokenId_);
    }

    function royaltyInfo(uint256, uint256) external pure returns (address, uint256) {
        revert("royaltyInfo broken");
    }

    function supportsInterface(bytes4 interfaceId_) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId_ == type(IERC2981).interfaceId || super.supportsInterface(interfaceId_);
    }
}
```

- [ ] **Step 3: Write the two tests in `test/NFTMarketplace.t.sol`**

```solidity
    function testBuyNFTIgnoresRoyaltyWhenERC165CheckReverts() public {
        NoERC165NFT noErc165NFT = new NoERC165NFT();
        noErc165NFT.mint(sellerAddr, tokenId);

        vm.startPrank(sellerAddr);
        noErc165NFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(noErc165NFT), tokenId, price);
        vm.stopPrank();

        uint256 sellerBalanceBefore = sellerAddr.balance;

        vm.deal(buyerAddr, price);
        vm.prank(buyerAddr);
        marketplace.buyNFT{value: price}(address(noErc165NFT), tokenId);

        assertEq(sellerAddr.balance, sellerBalanceBefore + price);
        assertEq(noErc165NFT.ownerOf(tokenId), buyerAddr);
    }

    function testBuyNFTIgnoresRoyaltyWhenRoyaltyInfoReverts() public {
        RevertingRoyaltyNFT revertingNFT = new RevertingRoyaltyNFT();
        revertingNFT.mint(sellerAddr, tokenId);

        vm.startPrank(sellerAddr);
        revertingNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(revertingNFT), tokenId, price);
        vm.stopPrank();

        uint256 sellerBalanceBefore = sellerAddr.balance;

        vm.deal(buyerAddr, price);
        vm.prank(buyerAddr);
        marketplace.buyNFT{value: price}(address(revertingNFT), tokenId);

        assertEq(sellerAddr.balance, sellerBalanceBefore + price);
        assertEq(revertingNFT.ownerOf(tokenId), buyerAddr);
    }
```

- [ ] **Step 4: Run the new tests**

Run: `forge test --match-test "testBuyNFTIgnoresRoyaltyWhenERC165CheckReverts|testBuyNFTIgnoresRoyaltyWhenRoyaltyInfoReverts" -vv`
Expected: both PASS — no code changes needed, since `_royaltyInfo`'s `try/catch` already handles both cases; this task only proves it.

- [ ] **Step 5: Run the full suite and confirm 100% coverage on the marketplace contract**

Run: `forge test && forge coverage --report summary`
Expected: all tests pass; `src/NFTMarketplace.sol` back to 100% lines/statements/branches/functions.

- [ ] **Step 6: Commit**

```bash
git add test/mocks/Mocks.sol test/NFTMarketplace.t.sol
git commit -m "test: cover both catch branches in _royaltyInfo (no ERC-165, reverting royaltyInfo)"
```

---

## Phase B: ERC-20 Payment Support

### Task 6: Add an optional ERC-20 payment token per listing

**Files:**
- Modify: `src/NFTMarketplace.sol` (`NFTList` struct, `NFTListed` event, `publishNFT`)
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Produces: `NFTMarketplace.publishNFT(address nftAddress_, uint256 tokenId_, uint256 price_, address paymentToken_) public nonReentrant` (new overload). The existing `publishNFT(address,uint256,uint256) external` keeps its signature and becomes a thin wrapper calling the new overload with `paymentToken_ = address(0)`.
- Consumes: nothing new from earlier tasks (built directly on the current `NFTList` struct).

- [ ] **Step 1: Write the failing test**

```solidity
    // #### Test ERC-20 Payments ####
    function testPublishNFTThreeArgOverloadDefaultsToETH() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(sellerAddr);
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        vm.stopPrank();

        (, address paymentToken,) = marketplace.listing(address(mockedNFT), tokenId);
        assertEq(paymentToken, address(0));
    }

    function testPublishNFTWithERC20PaymentToken() public {
        MockERC20 token = new MockERC20();
        mockedNFT.mint(sellerAddr, tokenId);

        vm.startPrank(sellerAddr);
        marketplace.publishNFT(address(mockedNFT), tokenId, price, address(token));
        vm.stopPrank();

        (address seller, address paymentToken, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assertEq(seller, sellerAddr);
        assertEq(paymentToken, address(token));
        assertEq(nftPrice, price);
    }
```

- [ ] **Step 2: Add `MockERC20` to `test/mocks/Mocks.sol`**

Add this import at the top of `test/mocks/Mocks.sol`:

```solidity
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
```

Add this contract:

```solidity
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USD", "MUSD") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `forge test --match-test "testPublishNFTThreeArgOverloadDefaultsToETH|testPublishNFTWithERC20PaymentToken" -vv`
Expected: compile error (`marketplace.listing(...)` returns only 2 fields today, and the 4-argument `publishNFT` overload doesn't exist yet).

- [ ] **Step 4: Add the `paymentToken` field and the 4-argument overload in `src/NFTMarketplace.sol`**

Change the struct:

```solidity
    struct NFTList {
        address seller;
        address paymentToken; // address(0) = native ETH
        uint256 price;
    }
```

Change the `NFTListed` event:

```solidity
    event NFTListed(
        address indexed seller_,
        address indexed nftAddress_,
        uint256 indexed tokenId_,
        uint256 price_,
        address paymentToken_
    );
```

Replace `publishNFT` with:

```solidity
    function publishNFT(address nftAddress_, uint256 tokenId_, uint256 price_) external {
        publishNFT(nftAddress_, tokenId_, price_, address(0));
    }

    function publishNFT(address nftAddress_, uint256 tokenId_, uint256 price_, address paymentToken_)
        public
        nonReentrant
    {
        require(price_ > 0, "Price can not be 0");
        address nftOwner = IERC721(nftAddress_).ownerOf(tokenId_);
        require(nftOwner == msg.sender, "You are not the Owner of the NFT");

        listing[nftAddress_][tokenId_] = NFTList({seller: msg.sender, paymentToken: paymentToken_, price: price_});

        emit NFTListed(msg.sender, nftAddress_, tokenId_, price_, paymentToken_);
    }
```

- [ ] **Step 5: Fix the 8 existing call sites that destructure `marketplace.listing(...)`**

`listing` is a public mapping of `NFTList`, so Solidity auto-generates a getter returning all 3 fields in order: `(address seller, address paymentToken, uint256 price)`. Every existing test that destructured the old 2-field tuple now has a tuple-arity mismatch and will fail to compile. Add an empty slot for the new middle `paymentToken` field at each of these 8 lines in `test/NFTMarketplace.t.sol` (found via `grep -n "marketplace.listing(" test/NFTMarketplace.t.sol`):

Lines 71, 118, 139, and 162 (all read `(address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);`) — change each to:

```solidity
        (address nftSeller,, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
```

Line 89 (same pattern, in `testUnpublishNFTCorrectly`) — same change:

```solidity
        (address nftSeller,, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
```

Line 98 (`(address nftSeller2, uint256 nftPrice2) = marketplace.listing(address(mockedNFT), tokenId);`) — change to:

```solidity
        (address nftSeller2,, uint256 nftPrice2) = marketplace.listing(address(mockedNFT), tokenId);
```

Line 176 (reassignment, no type declarations: `(nftSeller, nftPrice) = marketplace.listing(address(mockedNFT), tokenId);`) — change to:

```solidity
        (nftSeller,, nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
```

Line 206 (in `testFuzz_BuyNFTCorrectly`, uses `tokenIdArg`: `(address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenIdArg);`) — change to:

```solidity
        (address nftSeller,, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenIdArg);
```

- [ ] **Step 6: Run the full suite**

Run: `forge test`
Expected: all tests pass — including the two new ones from Step 1, and everything from Phase A (now recompiled against the 3-field getter).

- [ ] **Step 7: Commit**

```bash
git add src/NFTMarketplace.sol test/mocks/Mocks.sol test/NFTMarketplace.t.sol
git commit -m "feat: add optional ERC-20 payment token to listings"
```

---

### Task 7: Pay in ERC-20 when the listing specifies a token

**Files:**
- Modify: `src/NFTMarketplace.sol` (`buyNFT`, `NFTSold` event)
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: `NFTList.paymentToken` from Task 6, `_royaltyInfo` from Task 2/4.
- Produces: `NFTSold` event gains a `paymentToken_` field (no new function signatures).

- [ ] **Step 1: Write the failing test**

```solidity
    function testBuyNFTWithERC20PaymentSucceeds() public {
        MockERC20 token = new MockERC20();
        mockedNFT.mint(sellerAddr, tokenId);
        token.mint(buyerAddr, price);

        vm.startPrank(sellerAddr);
        mockedNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(mockedNFT), tokenId, price, address(token));
        vm.stopPrank();

        vm.startPrank(buyerAddr);
        token.approve(address(marketplace), price);
        marketplace.buyNFT(address(mockedNFT), tokenId);
        vm.stopPrank();

        assertEq(token.balanceOf(sellerAddr), price);
        assertEq(token.balanceOf(buyerAddr), 0);
        assertEq(mockedNFT.ownerOf(tokenId), buyerAddr);
    }

    function testBuyNFTRejectsETHForERC20Listing() public {
        MockERC20 token = new MockERC20();
        mockedNFT.mint(sellerAddr, tokenId);

        vm.startPrank(sellerAddr);
        mockedNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(mockedNFT), tokenId, price, address(token));
        vm.stopPrank();

        vm.deal(buyerAddr, price);
        vm.startPrank(buyerAddr);
        vm.expectRevert("ETH not accepted for this listing");
        marketplace.buyNFT{value: price}(address(mockedNFT), tokenId);
        vm.stopPrank();
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `forge test --match-test "testBuyNFTWithERC20PaymentSucceeds|testBuyNFTRejectsETHForERC20Listing" -vv`
Expected: both FAIL — `buyNFT` today always requires `msg.value == price` and never touches an ERC-20 token, so the ERC-20 buyer test reverts with `"Incorrect price"` and the ETH-rejection test doesn't revert at all (msg.value happens to equal price).

- [ ] **Step 3: Add the ERC-20 branch to `buyNFT` in `src/NFTMarketplace.sol`**

Add these imports after the `IERC165` import:

```solidity
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
```

Add this line inside the contract body, right after the `NFTList` struct:

```solidity
    using SafeERC20 for IERC20;
```

Replace the `NFTSold` event:

```solidity
    event NFTSold(
        address indexed nftBuyer_,
        address indexed seller_,
        address indexed nftAddress_,
        uint256 tokenId_,
        uint256 price_,
        address paymentToken_
    );
```

Replace the body of `buyNFT`:

```solidity
    function buyNFT(address nftAddress_, uint256 tokenId_) external payable nonReentrant {
        NFTList memory nftParameters = listing[nftAddress_][tokenId_];
        require(nftParameters.price > 0, "The NFT does not exist");

        if (nftParameters.paymentToken == address(0)) {
            require(msg.value == nftParameters.price, "Incorrect price");
        } else {
            require(msg.value == 0, "ETH not accepted for this listing");
        }

        delete listing[nftAddress_][tokenId_];

        (address royaltyReceiver, uint256 royaltyAmount) = _royaltyInfo(nftAddress_, tokenId_, nftParameters.price);
        uint256 sellerAmount = nftParameters.price - royaltyAmount;

        if (nftParameters.paymentToken == address(0)) {
            if (royaltyAmount > 0) {
                (bool royaltySuccess,) = royaltyReceiver.call{value: royaltyAmount}("");
                require(royaltySuccess, "Fail the royalty payment process");
                emit RoyaltyPaid(nftAddress_, tokenId_, royaltyReceiver, royaltyAmount);
            }
            (bool success,) = nftParameters.seller.call{value: sellerAmount}("");
            require(success, "Fail the payment process");
        } else {
            if (royaltyAmount > 0) {
                IERC20(nftParameters.paymentToken).safeTransferFrom(msg.sender, royaltyReceiver, royaltyAmount);
                emit RoyaltyPaid(nftAddress_, tokenId_, royaltyReceiver, royaltyAmount);
            }
            IERC20(nftParameters.paymentToken).safeTransferFrom(msg.sender, nftParameters.seller, sellerAmount);
        }

        IERC721(nftAddress_).safeTransferFrom(nftParameters.seller, msg.sender, tokenId_);

        emit NFTSold(
            msg.sender, nftParameters.seller, nftAddress_, tokenId_, nftParameters.price, nftParameters.paymentToken
        );
    }
```

- [ ] **Step 4: Run the full suite**

Run: `forge test`
Expected: all tests pass, including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add src/NFTMarketplace.sol test/NFTMarketplace.t.sol
git commit -m "feat: accept ERC-20 payment for listings that specify a payment token"
```

---

### Task 8: ERC-20 sale with a royalty, and missing-allowance revert

**Files:**
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: `MockNFT2981`/`MockERC20` mocks and `buyNFT`'s ERC-20 branch, all already in place from Tasks 2, 6, and 7. No production code changes expected — if this task's tests fail, it means the ERC-20 and royalty branches don't compose correctly and Task 7's implementation needs a fix, not a new feature.

- [ ] **Step 1: Write the tests**

```solidity
    function testBuyNFTWithERC20AndRoyalty() public {
        MockERC20 token = new MockERC20();
        MockNFT2981 royaltyNFT = new MockNFT2981();
        address royaltyReceiver = vm.addr(4);
        royaltyNFT.mint(sellerAddr, tokenId);
        royaltyNFT.setDefaultRoyalty(royaltyReceiver, 1000); // 10%
        token.mint(buyerAddr, price);

        vm.startPrank(sellerAddr);
        royaltyNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(royaltyNFT), tokenId, price, address(token));
        vm.stopPrank();

        vm.startPrank(buyerAddr);
        token.approve(address(marketplace), price);
        marketplace.buyNFT(address(royaltyNFT), tokenId);
        vm.stopPrank();

        uint256 expectedRoyalty = (price * 1000) / 10000;
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty);
        assertEq(token.balanceOf(sellerAddr), price - expectedRoyalty);
        assertEq(royaltyNFT.ownerOf(tokenId), buyerAddr);
    }

    function testBuyNFTRevertsWithoutERC20Allowance() public {
        MockERC20 token = new MockERC20();
        mockedNFT.mint(sellerAddr, tokenId);
        token.mint(buyerAddr, price);

        vm.startPrank(sellerAddr);
        mockedNFT.approve(address(marketplace), tokenId);
        marketplace.publishNFT(address(mockedNFT), tokenId, price, address(token));
        vm.stopPrank();

        // buyerAddr never approved the marketplace to spend `token`
        vm.startPrank(buyerAddr);
        vm.expectRevert();
        marketplace.buyNFT(address(mockedNFT), tokenId);
        vm.stopPrank();
    }
```

- [ ] **Step 2: Run them**

Run: `forge test --match-test "testBuyNFTWithERC20AndRoyalty|testBuyNFTRevertsWithoutERC20Allowance" -vv`
Expected: both PASS.

- [ ] **Step 3: Run the full suite and check coverage**

Run: `forge test && forge coverage --report summary`
Expected: all tests pass; `src/NFTMarketplace.sol` at 100% lines/branches.

- [ ] **Step 4: Commit**

```bash
git add test/NFTMarketplace.t.sol
git commit -m "test: cover ERC-20 sale combined with a royalty, and missing allowance"
```

---

### Task 9: Fuzz test the ERC-20 buy path

**Files:**
- Test: `test/NFTMarketplace.t.sol`

**Interfaces:**
- Consumes: same mocks and contract surface as Task 8 — mirrors the existing `testFuzz_BuyNFTCorrectly` (ETH path) for the ERC-20 path, to keep fuzz coverage symmetric between the two payment methods.

- [ ] **Step 1: Write the fuzz test**

```solidity
    function testFuzz_BuyNFTWithERC20Correctly(address seller, address buyer, uint256 tokenIdArg, uint256 priceArg)
        public
    {
        vm.assume(uint160(seller) > 255 && uint160(buyer) > 255);
        vm.assume(seller.code.length == 0 && buyer.code.length == 0);
        vm.assume(seller != buyer);
        priceArg = bound(priceArg, 1, 1_000_000 ether);

        MockERC20 token = new MockERC20();
        mockedNFT.mint(seller, tokenIdArg);
        token.mint(buyer, priceArg);

        vm.startPrank(seller);
        mockedNFT.approve(address(marketplace), tokenIdArg);
        marketplace.publishNFT(address(mockedNFT), tokenIdArg, priceArg, address(token));
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), priceArg);
        marketplace.buyNFT(address(mockedNFT), tokenIdArg);
        vm.stopPrank();

        assertEq(mockedNFT.ownerOf(tokenIdArg), buyer);
        assertEq(token.balanceOf(seller), priceArg);
        assertEq(token.balanceOf(buyer), 0);
    }
```

- [ ] **Step 2: Run it**

Run: `forge test --match-test testFuzz_BuyNFTWithERC20Correctly -vv`
Expected: PASS (1000 runs, per `foundry.toml`'s `[fuzz] runs = 1000`).

- [ ] **Step 3: Run the full suite one last time for Phase B**

Run: `forge test && forge coverage --report summary`
Expected: all tests pass (should now be 17 tests total: 11 original + 6 new, plus 2 fuzz tests); 100% coverage on `src/NFTMarketplace.sol`.

- [ ] **Step 4: Commit**

```bash
git add test/NFTMarketplace.t.sol
git commit -m "test: fuzz the ERC-20 buy path to mirror ETH fuzz coverage"
```

---

## Phase C: Process/Tooling Polish

### Task 10: Gas snapshot regression check in CI

**Files:**
- Create: `.gas-snapshot`
- Modify: `.github/workflows/test.yml`

**Interfaces:** None (tooling only).

- [ ] **Step 1: Generate the snapshot**

Run: `forge snapshot`
Expected: creates `.gas-snapshot` at the repo root with one gas-usage line per test.

- [ ] **Step 2: Add a CI step that fails on gas regressions**

In `.github/workflows/test.yml`, add this step after `Run Forge tests`:

```yaml
      - name: Check gas snapshot
        run: forge snapshot --check
```

- [ ] **Step 3: Verify locally**

Run: `forge snapshot --check`
Expected: `No changes in gas snapshot` (exit code 0).

- [ ] **Step 4: Commit**

```bash
git add .gas-snapshot .github/workflows/test.yml
git commit -m "ci: fail the build on gas usage regressions"
```

---

### Task 11: Deployment script

**Files:**
- Create: `script/DeployNFTMarketplace.s.sol`

**Interfaces:**
- Produces: `DeployNFTMarketplace.run() external returns (NFTMarketplace marketplace)` — a `forge script` entry point, not called from any Solidity code.

- [ ] **Step 1: Write the script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Script.sol";
import "../src/NFTMarketplace.sol";

contract DeployNFTMarketplace is Script {
    function run() external returns (NFTMarketplace marketplace) {
        vm.startBroadcast();
        marketplace = new NFTMarketplace();
        vm.stopBroadcast();
    }
}
```

- [ ] **Step 2: Confirm it builds**

Run: `forge build`
Expected: `Compiler run successful!` with the new file compiled alongside `src/NFTMarketplace.sol`.

- [ ] **Step 3: Dry-run the script locally (no broadcast, no real funds needed)**

Run: `forge script script/DeployNFTMarketplace.s.sol:DeployNFTMarketplace -vvvv`
Expected: simulation succeeds and logs a deployed `NFTMarketplace` address; nothing is broadcast since `--broadcast` wasn't passed.

- [ ] **Step 4: Commit**

```bash
git add script/DeployNFTMarketplace.s.sol
git commit -m "chore: add forge script to deploy NFTMarketplace"
```

**Manual follow-up (not part of this plan — needs your own funded testnet key, do this yourself when ready):**

```bash
forge script script/DeployNFTMarketplace.s.sol:DeployNFTMarketplace \
  --rpc-url <your_sepolia_rpc_url> \
  --private-key <your_testnet_private_key> \
  --broadcast --verify
```

---

### Task 12: Coverage floor gate in CI

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `.gitignore`

**Interfaces:** None (tooling only).

- [ ] **Step 1: Stop tracking the generated coverage artifact**

Add this line to `.gitignore` (in the "Compiler files" section, alongside `cache/` and `out/`):

```
lcov.info
```

- [ ] **Step 2: Add a CI step that fails below 90% line coverage**

In `.github/workflows/test.yml`, add this step after `Run Forge tests`:

```yaml
      - name: Check coverage floor
        run: |
          forge coverage --report lcov
          awk -F: '/^LF:/{f+=$2} /^LH:/{h+=$2} END{
            pct = (f > 0) ? 100 * h / f : 100
            printf "Line coverage: %.2f%%\n", pct
            if (pct + 0.001 < 90) { print "Coverage below 90% threshold"; exit 1 }
          }' lcov.info
```

- [ ] **Step 3: Verify locally**

Run:
```bash
forge coverage --report lcov
awk -F: '/^LF:/{f+=$2} /^LH:/{h+=$2} END{pct=(f>0)?100*h/f:100; printf "Line coverage: %.2f%%\n", pct; if (pct + 0.001 < 90) { print "Coverage below 90% threshold"; exit 1 }}' lcov.info
```
Expected: prints `Line coverage: 100.00%` (or wherever Phase A/B left it, should still be well above 90%) and exits 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test.yml .gitignore
git rm --cached lcov.info 2>/dev/null || true
git commit -m "ci: fail the build if line coverage drops below 90%"
```

---

## Post-Plan Verification

After all 12 tasks:

```bash
forge fmt --check
forge build --sizes
forge test -vvv
forge snapshot --check
forge coverage --report summary
```

All five commands must succeed before considering this plan done — this is exactly what `.github/workflows/test.yml` will run on push.
