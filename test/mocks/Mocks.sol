// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "../../lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "../../lib/openzeppelin-contracts/contracts/token/common/ERC2981.sol";

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
