// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title BuyOutAuction
 * @notice Single-unit buy-out auction contract
 * @dev Supports USDC/USDT on ARB and BNB chains
 */
contract BuyOutAuction is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Role for auction owner
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Token used for bidding
    IERC20 public paymentToken;

    /// @notice Auction owner (seller)
    address public owner;

    /// @notice Starting/minimum bid price
    uint256 public startingPrice;

    /// @notice Buy out price (instant purchase)
    uint256 public buyOutPrice;

    /// @notice Minimum bid increment (tick size)
    uint256 public tickSize;

    /// @notice Auction start time
    uint256 public startTime;

    /// @notice Auction end time
    uint256 public endTime;

    /// @notice Whether buy out is enabled
    bool public buyOutEnabled;

    /// @notice Highest bidder address
    address public highestBidder;

    /// @notice Highest bid amount
    uint256 public highestBid;

    /// @notice Bidder's claimed status
    mapping(address => bool) public hasClaimed;

    /// @notice Bidder's withdrawal status
    mapping(address => bool) public hasWithdrawn;

    /// @notice Bid history
    Bid[] public bidHistory;

    /// @notice Auction status
    enum Status {
        CREATED,
        ACTIVE,
        COMPLETED,
        CANCELLED
    }
    Status public auctionStatus;

    /// @notice Bid struct
    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }

    /// @notice Events
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

    event BidPlaced(address indexed bidder, uint256 amount, uint256 timestamp);
    event BuyOutExecuted(address indexed buyer, uint256 amount, uint256 timestamp);
    event BidWithdrawn(address indexed bidder, uint256 amount, uint256 timestamp);
    event ItemClaimed(address indexed winner, uint256 timestamp);
    event AuctionCancelled(address indexed owner, uint256 timestamp);

    /**
     * @notice Constructor
     * @param _paymentToken Address of USDC or USDT
     */
    constructor(address _paymentToken) {
        require(_paymentToken.isContract(), "Invalid payment token");
        paymentToken = IERC20(_paymentToken);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Initialize auction (called by factory)
     */
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

    function _isActive() internal view returns (bool) {
        if (auctionStatus == Status.CREATED || auctionStatus == Status.CANCELLED) return false;
        if (auctionStatus == Status.COMPLETED) return false;
        if (block.timestamp >= endTime) return false;
        if (buyOutEnabled && highestBid >= buyOutPrice) return false;
        if (block.timestamp < startTime) return false;
        return true;
    }

    function createBid(uint256 _amount) external nonReentrant {
        require(_isActive(), "Auction not active");
        require(msg.sender != owner, "Owner cannot bid");
        require(_amount >= startingPrice, "Amount below starting price");
        require(_amount >= highestBid + tickSize, "Amount below tick size");
        require(highestBid + tickSize > highestBid, "Overflow");

        // Refund previous highest bidder
        if (highestBidder != address(0) && !hasWithdrawn[highestBidder]) {
            paymentToken.safeTransfer(highestBidder, highestBid);
            hasWithdrawn[highestBidder] = true;
        }

        // Take payment
        paymentToken.safeTransferFrom(msg.sender, address(this), _amount);

        highestBidder = msg.sender;
        highestBid = _amount;

        bidHistory.push(Bid({
            bidder: msg.sender,
            amount: _amount,
            timestamp: block.timestamp
        }));

        emit BidPlaced(msg.sender, _amount, block.timestamp);
    }

    /**
     * @notice Execute buy out - instant purchase
     */
    function executeBuyOut() external nonReentrant {
        require(_isActive(), "Auction not active");
        require(buyOutEnabled, "Buy out not enabled");
        require(msg.sender != owner, "Owner cannot buy out");
        require(highestBid < buyOutPrice, "Already at buy out price");

        uint256 amount = buyOutPrice;

        // Refund highest bidder if exists
        if (highestBidder != address(0) && !hasWithdrawn[highestBidder]) {
            paymentToken.safeTransfer(highestBidder, highestBid);
            hasWithdrawn[highestBidder] = true;
        }

        // Take payment
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        highestBidder = msg.sender;
        highestBid = amount;
        auctionStatus = Status.COMPLETED;

        emit BuyOutExecuted(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Withdraw bid if outbid or auction cancelled
     */
    function withdraw() external nonReentrant {
        require(hasWithdrawn[msg.sender] == false, "Already withdrawn");
        
        bool canWithdraw = false;
        if (auctionStatus == Status.CANCELLED) {
            canWithdraw = true;
        } else if (auctionStatus == Status.COMPLETED || block.timestamp >= endTime) {
            if (msg.sender != highestBidder) canWithdraw = true;
        }
        
        require(canWithdraw, "Cannot withdraw");

        uint256 refundAmount = 0;
        
        // For outbidded users, find their last bid
        for (uint256 i = bidHistory.length; i > 0; i--) {
            if (bidHistory[i - 1].bidder == msg.sender) {
                refundAmount = bidHistory[i - 1].amount;
                break;
            }
        }

        require(refundAmount > 0, "Nothing to withdraw");

        hasWithdrawn[msg.sender] = true;
        paymentToken.safeTransfer(msg.sender, refundAmount);

        emit BidWithdrawn(msg.sender, refundAmount, block.timestamp);
    }

    /**
     * @notice Claim item (for winner)
     */
    function claim() external nonReentrant {
        require(auctionStatus == Status.COMPLETED || (block.timestamp >= endTime && highestBid > 0), "Auction not completed");
        require(msg.sender == highestBidder, "Not winner");
        require(!hasClaimed[msg.sender], "Already claimed");

        hasClaimed[msg.sender] = true;
        
        // Transfer winning bid to owner
        paymentToken.safeTransfer(owner, highestBid);

        emit ItemClaimed(msg.sender, block.timestamp);
    }

    /**
     * @notice Cancel auction (only before start or by owner)
     */
    function cancelAuction() external onlyRole(OWNER_ROLE) {
        require(_isActive(), "Cannot cancel");
        require(block.timestamp < startTime || highestBid == 0, "Cannot cancel with active bids");

        auctionStatus = Status.CANCELLED;
        emit AuctionCancelled(msg.sender, block.timestamp);
    }

    /**
     * @notice Get current auction status
     */
    function getAuctionStatus() external view returns (Status) {
        if (auctionStatus == Status.CREATED) return Status.CREATED;
        if (auctionStatus == Status.CANCELLED) return Status.CANCELLED;
        if (auctionStatus == Status.COMPLETED) return Status.COMPLETED;
        
        if (block.timestamp >= endTime || (buyOutEnabled && highestBid >= buyOutPrice)) {
            return Status.COMPLETED;
        }
        return Status.ACTIVE;
    }

    /**
     * @notice Get bid count
     */
    function getBidCount() external view returns (uint256) {
        return bidHistory.length;
    }
}