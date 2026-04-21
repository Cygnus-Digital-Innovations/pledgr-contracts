// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract BuyOutAuction is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 public constant CO_OWNER1_BPS = 4000;
    uint16 public constant CO_OWNER2_BPS = 4000;
    uint16 public constant COMMUNITY_BPS = 2000;
    uint256 public constant MAX_GAS_FEE = 1e6;

    IERC20 public paymentToken;
    address public owner;

    address public immutable coOwner1Wallet;
    address public immutable coOwner2Wallet;
    address public immutable communityWallet;
    uint16 public immutable creatorBps;
    uint16 public immutable platformBps;

    uint256 public startingPrice;
    uint256 public buyOutPrice;
    uint256 public tickSize;
    uint256 public startTime;
    uint256 public endTime;
    bool public buyOutEnabled;

    address public highestBidder;
    uint256 public highestBid;

    enum Status {
        CREATED,
        ACTIVE,
        COMPLETED,
        CANCELLED
    }
    Status public auctionStatus;

    struct Bid {
        address bidder;
        uint256 amount;
    }
    Bid[] public bidHistory;

    event AuctionInitialized(
        address indexed owner,
        address paymentToken,
        uint256 startingPrice,
        uint256 buyOutPrice,
        uint256 tickSize,
        uint256 startTime,
        uint256 endTime,
        bool buyOutEnabled
    );

    event BidPlaced(
        address indexed bidder,
        uint256 amount,
        uint256 creatorAmount,
        uint256 platformAmount,
        uint256 gasFee,
        address indexed previousBidder,
        uint256 refundAmount,
        uint256 timestamp
    );

    event BuyOutExecuted(
        address indexed buyer,
        uint256 amount,
        uint256 creatorAmount,
        uint256 platformAmount,
        uint256 gasFee,
        address indexed previousBidder,
        uint256 refundAmount,
        uint256 timestamp
    );

    event AuctionCancelled(address indexed owner, uint256 timestamp);
    event AuctionFinalized(address indexed winner, uint256 winningBid, uint256 timestamp);

    constructor(
        address _paymentToken,
        address _coOwner1Wallet,
        address _coOwner2Wallet,
        address _communityWallet,
        uint16 _creatorBps,
        uint16 _platformBps
    ) {
        require(_paymentToken.isContract(), "Invalid payment token");
        require(_creatorBps + _platformBps == 10000, "Invalid split");
        require(_coOwner1Wallet != address(0), "Invalid coOwner1");
        require(_coOwner2Wallet != address(0), "Invalid coOwner2");
        require(_communityWallet != address(0), "Invalid community");

        paymentToken = IERC20(_paymentToken);
        coOwner1Wallet = _coOwner1Wallet;
        coOwner2Wallet = _coOwner2Wallet;
        communityWallet = _communityWallet;
        creatorBps = _creatorBps;
        platformBps = _platformBps;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(
        address _owner,
        uint256 _startingPrice,
        uint256 _buyOutPrice,
        uint256 _tickSize,
        uint256 _startTime,
        uint256 _endTime,
        bool _buyOutEnabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(auctionStatus == Status.CREATED, "Already initialized");
        require(_owner != address(0), "Invalid owner");
        require(_startingPrice > 0, "Invalid starting price");
        require(_tickSize > 0, "Invalid tick size");
        require(_startTime > block.timestamp, "Invalid start time");
        require(_endTime > _startTime, "Invalid end time");
        require(_buyOutPrice > _startingPrice || !_buyOutEnabled, "Invalid buy out price");

        owner = _owner;
        startingPrice = _startingPrice;
        buyOutPrice = _buyOutPrice;
        tickSize = _tickSize;
        startTime = _startTime;
        endTime = _endTime;
        buyOutEnabled = _buyOutEnabled;
        auctionStatus = Status.ACTIVE;

        _grantRole(OWNER_ROLE, _owner);
        _grantRole(PAUSER_ROLE, msg.sender);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

        emit AuctionInitialized(
            _owner,
            address(paymentToken),
            _startingPrice,
            _buyOutPrice,
            _tickSize,
            _startTime,
            _endTime,
            _buyOutEnabled
        );
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _isActive() internal view returns (bool) {
        if (auctionStatus != Status.ACTIVE) return false;
        if (block.timestamp < startTime) return false;
        if (block.timestamp >= endTime) return false;
        return true;
    }

    function _calculateSplit(uint256 amount) internal view returns (uint256 creatorAmount, uint256 platformAmount) {
        platformAmount = (amount * platformBps) / 10000;
        creatorAmount = amount - platformAmount;
    }

    function _distributePlatformFee(uint256 platformAmount) internal {
        if (platformAmount == 0) return;
        uint256 co1 = (platformAmount * CO_OWNER1_BPS) / 10000;
        uint256 co2 = (platformAmount * CO_OWNER2_BPS) / 10000;
        uint256 comm = platformAmount - co1 - co2;
        if (co1 > 0) paymentToken.safeTransfer(coOwner1Wallet, co1);
        if (co2 > 0) paymentToken.safeTransfer(coOwner2Wallet, co2);
        if (comm > 0) paymentToken.safeTransfer(communityWallet, comm);
    }

    function _settle(address bidder, uint256 amount, uint256 gasFee) internal {
        uint256 totalRequired = amount + gasFee;
        uint256 refundAmount = 0;
        address previousBidder = highestBidder;

        if (previousBidder != address(0)) {
            refundAmount = highestBid;
        }

        paymentToken.safeTransferFrom(bidder, address(this), totalRequired);

        if (refundAmount > 0) {
            paymentToken.safeTransfer(previousBidder, refundAmount);
        }

        if (gasFee > 0) {
            paymentToken.safeTransfer(coOwner2Wallet, gasFee);
        }

        uint256 splitAmount;
        if (previousBidder == address(0)) {
            splitAmount = amount;
        } else {
            splitAmount = amount - refundAmount;
        }

        (uint256 creatorAmount, uint256 platformAmount) = _calculateSplit(splitAmount);
        if (creatorAmount > 0) paymentToken.safeTransfer(owner, creatorAmount);
        _distributePlatformFee(platformAmount);

        highestBidder = bidder;
        highestBid = amount;

        bidHistory.push(Bid({
            bidder: bidder,
            amount: amount
        }));
    }

    function createBid(uint256 _amount, uint256 _gasFee) external nonReentrant whenNotPaused {
        require(_isActive(), "Auction not active");
        require(msg.sender != owner, "Owner cannot bid");
        require(msg.sender != highestBidder, "Already highest bidder");
        require(_amount >= startingPrice, "Below starting price");
        require(_gasFee <= MAX_GAS_FEE, "Gas fee too high");

        if (highestBidder != address(0)) {
            require(_amount >= highestBid + tickSize, "Below tick size");
        }

        address previousBidder = highestBidder;
        uint256 previousBid = highestBid;

        uint256 splitAmount = previousBidder == address(0) ? _amount : _amount - previousBid;
        (uint256 ca, uint256 pa) = _calculateSplit(splitAmount);

        _settle(msg.sender, _amount, _gasFee);

        emit BidPlaced(
            msg.sender,
            _amount,
            ca,
            pa,
            _gasFee,
            previousBidder,
            previousBid,
            block.timestamp
        );
    }

    function executeBuyOut(uint256 _gasFee) external nonReentrant whenNotPaused {
        require(_isActive(), "Auction not active");
        require(buyOutEnabled, "Buy out not enabled");
        require(msg.sender != owner, "Owner cannot buy out");
        require(highestBid < buyOutPrice, "Bid already at buyout price");
        require(_gasFee <= MAX_GAS_FEE, "Gas fee too high");

        uint256 amount = buyOutPrice;
        address previousBidder = highestBidder;
        uint256 previousBid = highestBid;

        uint256 splitAmount = previousBidder == address(0) ? amount : amount - previousBid;
        (uint256 ca, uint256 pa) = _calculateSplit(splitAmount);

        _settle(msg.sender, amount, _gasFee);
        auctionStatus = Status.COMPLETED;

        emit BuyOutExecuted(
            msg.sender,
            amount,
            ca,
            pa,
            _gasFee,
            previousBidder,
            previousBid,
            block.timestamp
        );
    }

    function cancelAuction() external onlyRole(OWNER_ROLE) {
        require(auctionStatus == Status.ACTIVE, "Not active");
        require(block.timestamp < startTime, "Already started");

        auctionStatus = Status.CANCELLED;
        emit AuctionCancelled(msg.sender, block.timestamp);
    }

    function finalizeAuction() external {
        require(auctionStatus == Status.ACTIVE, "Not active");
        require(block.timestamp >= endTime, "Auction not ended");

        auctionStatus = Status.COMPLETED;
        emit AuctionFinalized(highestBidder, highestBid, block.timestamp);
    }

    function getAuctionStatus() external view returns (Status) {
        if (auctionStatus == Status.CANCELLED) return Status.CANCELLED;
        if (auctionStatus == Status.COMPLETED) return Status.COMPLETED;
        if (auctionStatus == Status.CREATED) return Status.CREATED;
        if (block.timestamp >= endTime) return Status.COMPLETED;
        return Status.ACTIVE;
    }

    function getBidCount() external view returns (uint256) {
        return bidHistory.length;
    }

    function getHighestBid() external view returns (address, uint256) {
        return (highestBidder, highestBid);
    }
}
