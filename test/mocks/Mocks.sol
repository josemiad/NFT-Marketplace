// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "../../lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "../../lib/openzeppelin-contracts/contracts/token/common/ERC2981.sol";
import "../../lib/openzeppelin-contracts/contracts/interfaces/IERC2981.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

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
