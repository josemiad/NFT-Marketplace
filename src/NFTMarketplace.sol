// License
// SPDX-License-Identifier: MIT

// Solidity version
pragma solidity ^0.8.34;

import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC2981.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import "../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

contract NFTMarketplace is ReentrancyGuard {
    struct NFTList {
        address seller;
        address paymentToken;
        uint256 price;
    }

    // NFTAddress -> tokenId --> NFTListElement
    mapping(address => mapping(uint256 => NFTList)) public listing;

    event NFTListed(
        address indexed seller_,
        address indexed nftAddress_,
        uint256 indexed tokenId_,
        uint256 price_,
        address paymentToken_
    );
    event NFTUnpublished(address indexed seller_, address indexed nftAddress_, uint256 indexed tokenId_);
    event NFTSold(
        address indexed nftBuyer_,
        address indexed seller_,
        address indexed nftAddress_,
        uint256 tokenId_,
        uint256 price_
    );
    event RoyaltyPaid(
        address indexed nftAddress_, uint256 indexed tokenId_, address indexed receiver_, uint256 amount_
    );

    constructor() {}

    // Publish NFT
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

    // Buy NFT
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

    // Unpublish NFT
    function unpublishNFT(address nftAddress_, uint256 tokenId_) external nonReentrant {
        NFTList memory nftParameters = listing[nftAddress_][tokenId_];
        require(msg.sender == nftParameters.seller, "You are not the owner of the NFT");

        delete listing[nftAddress_][tokenId_];

        emit NFTUnpublished(msg.sender, nftAddress_, tokenId_);
    }

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
            if (r == address(0) || amount == 0 || amount > salePrice_) return (address(0), 0);
            return (r, amount);
        } catch {
            return (address(0), 0);
        }
    }
}

