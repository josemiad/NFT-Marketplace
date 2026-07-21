// License
// SPDX-License-Identifier: MIT

// Solidity version
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import "../src/NFTMarketplace.sol";
import "./mocks/Mocks.sol";

contract NFTMarketplaceTest is Test {
    NFTMarketplace marketplace;
    MockNFT mockedNFT;
    RejectEther rejectEtherAddress;
    address deployerAddr = vm.addr(1);
    address sellerAddr = vm.addr(2);
    address buyerAddr = vm.addr(3);
    uint256 tokenId = 0;
    uint256 price = 10000;

    function setUp() public {
        // Init marketplace
        vm.startPrank(deployerAddr);
        marketplace = new NFTMarketplace();
        mockedNFT = new MockNFT();
        rejectEtherAddress = new RejectEther();
        vm.stopPrank();
    }

    function testMintNFT() public {
        mockedNFT.mint(sellerAddr, tokenId);
        address nftOwner = mockedNFT.ownerOf(tokenId);
        assert(nftOwner == sellerAddr);
    }

    // #### Tests Publish NFT ####
    function testPublishNFTPriceMoreThan0() public {
        vm.expectRevert("Price can not be 0");
        marketplace.publishNFT(address(mockedNFT), tokenId, 0);
    }

    function testPublishNFTRequireOwner() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.expectRevert("You are not the Owner of the NFT");
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
    }

    function testPublishNFTSuccess() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(sellerAddr);
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        vm.stopPrank();

        (address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice == price);
        assert(nftSeller == sellerAddr);
    }

    // #### Test Unpublish NFT
    function testUnpublishNFTNotOwner() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.expectRevert("You are not the owner of the NFT");
        marketplace.unpublishNFT(address(mockedNFT), tokenId);
    }

    function testUnpublishNFTCorrectly() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(sellerAddr);
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        vm.stopPrank();

        (address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice == price);
        assert(nftSeller == sellerAddr);

        // This test start here
        vm.startPrank(sellerAddr);
        marketplace.unpublishNFT(address(mockedNFT), tokenId);
        vm.stopPrank();

        (address nftSeller2, uint256 nftPrice2) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice2 == 0);
        assert(nftSeller2 == address(0));
    }

    // #### Test Buy NFT ####
    function testBuyNFTNotExist() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(buyerAddr);
        vm.expectRevert("The NFT does not exist");
        marketplace.buyNFT(address(mockedNFT), tokenId + 1);
        vm.stopPrank();
    }

    function testBuyNFTIncorrectPrice() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(sellerAddr);
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        vm.stopPrank();

        (address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice == price);
        assert(nftSeller == sellerAddr);

        // This test start here
        vm.startPrank(buyerAddr);
        vm.expectRevert("Incorrect price");
        (bool success,) = address(marketplace).call{value: 0}(
            abi.encodeWithSignature("buyNFT(address,uint256)", address(mockedNFT), tokenId)
        );
        require(success);

        vm.stopPrank();
    }

    function testBuyNFTPaymentFailed() public {
        mockedNFT.mint(address(rejectEtherAddress), tokenId);
        vm.startPrank(address(rejectEtherAddress));
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        vm.stopPrank();

        (address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice == price);
        assert(nftSeller == address(rejectEtherAddress));

        // This test start here
        vm.startPrank(buyerAddr);
        vm.deal(buyerAddr, 1 ether);
        vm.expectRevert("Fail the payment process");
        (bool success,) = address(marketplace).call{value: price}(
            abi.encodeWithSignature("buyNFT(address,uint256)", address(mockedNFT), tokenId)
        );
        require(success);

        vm.stopPrank();
    }

    function testBuyNFTCorrectly() public {
        mockedNFT.mint(sellerAddr, tokenId);
        vm.startPrank(sellerAddr);
        marketplace.publishNFT(address(mockedNFT), tokenId, price);
        IERC721(mockedNFT).approve(address(marketplace), tokenId);
        vm.stopPrank();

        (address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice == price);
        assert(nftSeller == sellerAddr);

        // This test start here
        vm.startPrank(buyerAddr);
        vm.deal(buyerAddr, 1 ether);
        vm.deal(address(marketplace), 1 ether);
        uint256 sellerBalanceBefore = sellerAddr.balance;
        (bool success,) = address(marketplace).call{value: price}(
            abi.encodeWithSignature("buyNFT(address,uint256)", address(mockedNFT), tokenId)
        );
        require(success, "Buy NFT failed");

        (nftSeller, nftPrice) = marketplace.listing(address(mockedNFT), tokenId);
        assert(nftPrice == 0);
        assert(nftSeller == address(0));
        address newOwner = IERC721(address(mockedNFT)).ownerOf(tokenId);
        assert(newOwner == buyerAddr);
        assert(sellerAddr.balance + sellerBalanceBefore == price);

        vm.stopPrank();
    }

    function testFuzz_BuyNFTCorrectly(address seller, address buyer, uint256 tokenIdArg, uint256 priceArg) public {
        // 1. Exclude null address and precompiles (0x01 through 0xFF)
        vm.assume(uint160(seller) > 255 && uint160(buyer) > 255);
        // 2. Exclude deployed contracts (like RejectEther)
        vm.assume(seller.code.length == 0 && buyer.code.length == 0);
        // 3. Exclude seller buying from themselves
        vm.assume(seller != buyer);

        // Clamp the price between 1 wei and 1,000 ETH (prevents overflow or unrealistically large values)
        priceArg = bound(priceArg, 1, 1000 ether);

        // 4. Setup state: Mint token and publish listing
        mockedNFT.mint(seller, tokenIdArg);

        vm.startPrank(seller);
        IERC721(address(mockedNFT)).approve(address(marketplace), tokenIdArg);
        marketplace.publishNFT(address(mockedNFT), tokenIdArg, priceArg);
        vm.stopPrank();

        // 5. Verify the listing was stored correctly
        (address nftSeller, uint256 nftPrice) = marketplace.listing(address(mockedNFT), tokenIdArg);
        assertEq(nftPrice, priceArg);
        assertEq(nftSeller, seller);

        // 6. Fund the buyer with sufficient Ether
        vm.deal(buyer, priceArg);
        uint256 sellerBalanceBefore = seller.balance;

        // 7. Execute the NFT purchase
        vm.prank(buyer);
        marketplace.buyNFT{value: priceArg}(address(mockedNFT), tokenIdArg);

        // 8. Post-execution assertions (Fuzz invariants)
        assertEq(mockedNFT.ownerOf(tokenIdArg), buyer); // Verify ownership was transferred to the buyer
        assertEq(seller.balance, sellerBalanceBefore + priceArg); // Verify the seller received the payment
    }

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
}
