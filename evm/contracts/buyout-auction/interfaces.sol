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
    function withdraw() external;
    function claim() external;
    function cancelAuction() external;

    function owner() external view returns (address);
    function highestBidder() external view returns (address);
    function highestBid() external view returns (uint256);
    function auctionStatus() external view returns (uint8);
}

interface IBuyOutAuctionFactory {
    function createAuction(
        address _owner,
        address _paymentToken,
        uint256 _startingPrice,
        uint256 _buyOutPrice,
        uint256 _tickSize,
        uint256 _startTime,
        uint256 _endTime,
        bool _buyOutEnabled
    ) external returns (address);

    function auctions(uint256) external view returns (address);
    function auctionCount() external view returns (uint256);
}