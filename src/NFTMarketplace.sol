// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC2981.sol";
import "../lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import "../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

/// @title NFTMarketplace
/// @notice Non-custodial marketplace for ERC-721 tokens, priced in ETH or an ERC-20 token.
/// @dev Sellers list directly from their own wallet — the marketplace never takes custody of the NFT
///      or its payment until `buyNFT` executes. ERC-2981 royalties are honored on a best-effort basis:
///      a non-compliant, reverting, or malicious NFT contract can never block a sale (see `_royaltyInfo`).
contract NFTMarketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice A single active listing.
    /// @dev `paymentToken == address(0)` means the listing is priced in ETH.
    struct NFTList {
        address seller;
        address paymentToken;
        uint256 price;
    }

    /// @notice Active listings, keyed by NFT contract address then token ID.
    mapping(address => mapping(uint256 => NFTList)) public listing;

    /// @notice Emitted when a seller lists an NFT for sale.
    event NFTListed(
        address indexed seller_,
        address indexed nftAddress_,
        uint256 indexed tokenId_,
        uint256 price_,
        address paymentToken_
    );

    /// @notice Emitted when a seller cancels their own listing.
    event NFTUnpublished(address indexed seller_, address indexed nftAddress_, uint256 indexed tokenId_);

    /// @notice Emitted when a listing is purchased and the NFT changes hands.
    event NFTSold(
        address indexed nftBuyer_,
        address indexed seller_,
        address indexed nftAddress_,
        uint256 tokenId_,
        uint256 price_,
        address paymentToken_
    );

    /// @notice Emitted when a sale pays out an ERC-2981 royalty.
    event RoyaltyPaid(
        address indexed nftAddress_, uint256 indexed tokenId_, address indexed receiver_, uint256 amount_
    );

    constructor() {}

    /// @notice Lists an NFT for sale, priced in ETH.
    /// @dev Convenience overload of `publishNFT` that defaults `paymentToken_` to `address(0)`.
    /// @param nftAddress_ The ERC-721 contract address.
    /// @param tokenId_ The token ID being listed.
    /// @param price_ The sale price in wei.
    function publishNFT(address nftAddress_, uint256 tokenId_, uint256 price_) external {
        publishNFT(nftAddress_, tokenId_, price_, address(0));
    }

    /// @notice Lists an NFT for sale, priced in ETH or a given ERC-20 token.
    /// @dev Caller must be the current owner of `tokenId_`. Does not take custody of the NFT — the seller
    ///      must still hold it, and approve the marketplace, at the time `buyNFT` is called.
    /// @param nftAddress_ The ERC-721 contract address.
    /// @param tokenId_ The token ID being listed.
    /// @param price_ The sale price, in wei (ETH) or in the token's smallest unit (ERC-20).
    /// @param paymentToken_ The ERC-20 token address to price the listing in, or `address(0)` for ETH.
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

    /// @notice Cancels an existing listing.
    /// @dev Caller must be the seller who created the listing.
    /// @param nftAddress_ The ERC-721 contract address.
    /// @param tokenId_ The token ID whose listing is being cancelled.
    function unpublishNFT(address nftAddress_, uint256 tokenId_) external nonReentrant {
        NFTList memory nftParameters = listing[nftAddress_][tokenId_];
        require(msg.sender == nftParameters.seller, "You are not the owner of the NFT");

        delete listing[nftAddress_][tokenId_];

        emit NFTUnpublished(msg.sender, nftAddress_, tokenId_);
    }

    /// @notice Buys a listed NFT, paying in the listing's configured currency.
    /// @dev Checks-effects-interactions: the listing is deleted before any external call. Any ERC-2981
    ///      royalty is paid out of the sale price first, then the remainder goes to the seller, then the
    ///      NFT is transferred last. ETH listings require `msg.value == price`; ERC-20 listings require
    ///      the buyer to have approved the marketplace beforehand and reject any attached ETH.
    /// @param nftAddress_ The ERC-721 contract address.
    /// @param tokenId_ The token ID being purchased.
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

    /// @notice Looks up the ERC-2981 royalty for a sale, if the NFT contract supports it.
    /// @dev Defensive by design: an NFT contract that doesn't implement ERC-165/ERC-2981, or that reverts,
    ///      or that returns a malicious value (zero address, zero amount, or an amount exceeding the sale
    ///      price), is treated as having no royalty rather than blocking or corrupting the sale.
    /// @param nftAddress_ The ERC-721 contract address.
    /// @param tokenId_ The token ID being sold.
    /// @param salePrice_ The sale price the royalty is computed from.
    /// @return receiver The royalty recipient, or `address(0)` if none applies.
    /// @return royaltyAmount The royalty amount, or `0` if none applies.
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
