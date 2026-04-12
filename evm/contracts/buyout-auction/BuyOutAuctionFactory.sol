// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./BuyOutAuction.sol";

/**
 * @title BuyOutAuctionFactory
 * @notice Factory for deploying BuyOutAuction instances
 */
contract BuyOutAuctionFactory is AccessControl {
    using Address for address;

    /// @notice Role for factory admin
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Deployed auctions count
    uint256 public auctionCount;

    /// @notice Auction addresses by index
    mapping(uint256 => address) public auctions;

    /// @notice Payment token per auction
    mapping(address => address) public auctionPaymentToken;

    /// @notice Owner to auctions mapping
    mapping(address => address[]) public ownerAuctions;

    /// @notice Events
    event AuctionCreated(
        address indexed auction,
        address indexed owner,
        address paymentToken,
        uint256 startingPrice,
        uint256 buyOutPrice,
        uint256 tickSize,
        uint256 startTime,
        uint256 endTime,
        bool buyOutEnabled
    );

    /**
     * @notice Constructor
     */
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Create new auction
     * @param _owner Auction owner (seller)
     * @param _paymentToken USDC or USDT address
     * @param _startingPrice Minimum bid price
     * @param _buyOutPrice Buy out price
     * @param _tickSize Minimum bid increment
     * @param _startTime Auction start timestamp
     * @param _endTime Auction end timestamp
     * @param _buyOutEnabled Whether buy out is enabled
     * @return Address of deployed auction
     */
    function createAuction(
        address _owner,
        address _paymentToken,
        uint256 _startingPrice,
        uint256 _buyOutPrice,
        uint256 _tickSize,
        uint256 _startTime,
        uint256 _endTime,
        bool _buyOutEnabled
    ) external onlyRole(ADMIN_ROLE) returns (address) {
        require(_paymentToken.isContract(), "Invalid payment token");

        // Deploy new auction contract
        BuyOutAuction auction = new BuyOutAuction(_paymentToken);

        // Initialize
        auction.initialize(
            _owner,
            _startingPrice,
            _buyOutPrice,
            _tickSize,
            _startTime,
            _endTime,
            _buyOutEnabled
        );

        // Transfer ownership of auction to factory admin for access control
        // The owner (seller) has OWNER_ROLE in the auction

        // Store
        address auctionAddr = address(auction);
        uint256 index = auctionCount;
        auctions[index] = auctionAddr;
        auctionPaymentToken[auctionAddr] = _paymentToken;
        ownerAuctions[_owner].push(auctionAddr);
        auctionCount++;

        emit AuctionCreated(
            auctionAddr,
            _owner,
            _paymentToken,
            _startingPrice,
            _buyOutPrice,
            _tickSize,
            _startTime,
            _endTime,
            _buyOutEnabled
        );

        return auctionAddr;
    }

    /**
     * @notice Get auctions by owner
     * @param _owner Owner address
     * @return Array of auction addresses
     */
    function getAuctionsByOwner(address _owner) external view returns (address[] memory) {
        return ownerAuctions[_owner];
    }

    /**
     * @notice Get auction count
     */
    function getAuctionCount() external view returns (uint256) {
        return auctionCount;
    }
}