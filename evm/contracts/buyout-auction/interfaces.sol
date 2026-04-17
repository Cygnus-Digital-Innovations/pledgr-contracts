// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBuyOutAuction {
    function initialize(
        address _owner,
        uint256 _startingPrice,
        uint256 _buyOutPrice,
        uint256 _tickSize,
        uint256 _startTime,
        uint256 _endTime,
        bool _buyOutEnabled
    ) external;

    function createBid(uint256 _amount) external;
    function executeBuyOut() external;
    function cancelAuction() external;

    function owner() external view returns (address);
    function highestBidder() external view returns (address);
    function highestBid() external view returns (uint256);
    function auctionStatus() external view returns (uint8);
    function getHighestBid() external view returns (address, uint256);
    function getBidCount() external view returns (uint256);
    function getAuctionStatus() external view returns (uint8);
}

interface IBuyOutAuctionFactory {
    struct AuctionParams {
        uint8 paymentToken;
        uint256 startingPrice;
        uint256 buyOutPrice;
        uint256 tickSize;
        uint256 startTime;
        uint256 endTime;
        bool buyOutEnabled;
        uint8 splitStrategy;
    }

    function createAuction(AuctionParams calldata params) external returns (address);

    function USDC() external view returns (address);
    function USDT() external view returns (address);
    function auctions(uint256) external view returns (address);
    function auctionCount() external view returns (uint256);
    function getAuctionsByOwner(address _owner) external view returns (address[] memory);
    function getSplitStrategy(uint8 _strategy) external view returns (uint16 creatorBps, uint16 platformBps, bool isActive);
}
